# Developer audit only. Never import this module in the document execution path.
Set-StrictMode -Version Latest

function ConvertFrom-HancomCommandDefinitions {
    param([Parameter(Mandatory)][Collections.IDictionary]$Definitions)
    $ErrorActionPreference='Stop'
    $commands=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($name in @($Definitions.Keys|Sort-Object)) {
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=16MB
        $input=[IO.StringReader]::new([string]$Definitions[$name]);$reader=[Xml.XmlReader]::Create($input,$settings)
        try{$xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose();$input.Dispose()}
        $ordinal=0
        foreach($node in $xml.SelectNodes('//*')) {
            $ordinal++
            $definition=$node.LocalName -ceq 'Command' -and $node.HasAttribute('name')
            $reference=$node.HasAttribute('command')
            foreach($kind in @('definition','reference')) {
                if(($kind -eq 'definition' -and -not $definition) -or ($kind -eq 'reference' -and -not $reference)){continue}
                $id=$node.GetAttribute($(if($kind -eq 'definition'){'name'}else{'command'}));if([string]::IsNullOrWhiteSpace($id)){throw "Empty command ID in $name"}
                if(-not $commands.ContainsKey($id)){$commands.Add($id,@{id=$id;defined=$false;definitions=[Collections.Generic.List[object]]::new();references=[Collections.Generic.List[object]]::new();reviewState='inventory-only'})}
                $group=$node.SelectSingleNode('ancestor::*[local-name()="CommandGroup"][1]')
                $comment=$node.PreviousSibling
                while($null -ne $comment -and $comment.NodeType -in @('Whitespace','SignificantWhitespace')){$comment=$comment.PreviousSibling}
                $record=[ordered]@{resource=$name;elementOrdinal=$ordinal;group=$(if($group){$group.GetAttribute('name')}else{''});caption=$node.GetAttribute('caption');help=$node.GetAttribute('help');label=$(if($comment -and $comment.NodeType -eq 'Comment'){$comment.Value.Trim()}else{''})}
                if($kind -eq 'definition'){$commands[$id].defined=$true;$commands[$id].definitions.Add($record)}else{$commands[$id].references.Add($record)}
            }
        }
    }
    [pscustomobject]@{semanticAuditComplete=$false;resources=@($Definitions.Keys|Sort-Object);commands=@($commands.Values|ForEach-Object {[pscustomobject]$_})}
}

function Get-HancomEmbeddedDefinitions {
    param([Parameter(Mandatory)][string]$Path)
    $ErrorActionPreference='Stop'
    if($PSVersionTable.PSVersion.Major -lt 7){throw 'The developer inventory collector requires PowerShell 7.'}
    Add-Type -AssemblyName System.Reflection.Metadata
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $pe=[Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader=[Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $block=$pe.GetSectionData($pe.PEHeaders.CorHeader.ResourcesDirectory.RelativeVirtualAddress)
        $definitions=@{};$resources=[Collections.Generic.List[object]]::new()
        foreach($handle in $reader.ManifestResources) {
            $resource=$reader.GetManifestResource($handle);$name=$reader.GetString($resource.Name)
            if(-not $resource.Implementation.IsNil){throw "External resource cannot be inventoried: $name"}
            $length=[BitConverter]::ToInt32([byte[]]$block.GetContent([int]$resource.Offset,4),0)
            if($length -lt 0 -or $length -gt 16MB){throw 'Invalid embedded resource length.'}
            $bytes=[byte[]]$block.GetContent([int]$resource.Offset+4,$length)
            $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $resources.Add(@{name=$name;length=$length;sha256=$hash;offset=[int]$resource.Offset})
            if($name.EndsWith('.xml',[StringComparison]::Ordinal)) {
                $memory=[IO.MemoryStream]::new($bytes,$false);$text=[IO.StreamReader]::new($memory,[Text.Encoding]::UTF8,$true)
                try{$definitions[$name]=$text.ReadToEnd()}finally{$text.Dispose();$memory.Dispose()}
            }
        }
        [pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant();resources=@($resources.ToArray());inventory=(ConvertFrom-HancomCommandDefinitions $definitions)}
    } finally {$pe.Dispose();$stream.Dispose()}
}

function Get-HancomTypeLibraryInventory {
    param([Parameter(Mandatory)][string]$Path)
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Type-library inspection requires Windows; no Hancom application is executed.'}
    if(-not ('HancomStaticTypeInventory' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class HancomStaticTypeInventory {
    [DllImport("oleaut32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void LoadTypeLibEx(string path, int regkind, out ITypeLib library);
    public sealed class Member { public int index, memberId, parameterCount; public string name, invocation; public string[] names; }
    public sealed class TypeRecord { public int index; public string name, kind; public Member[] members; }
    public static TypeRecord[] Read(string path) {
        ITypeLib library=null;
        try {
            LoadTypeLibEx(path, 2, out library); // REGKIND_NONE: metadata only, no registration or server activation.
            var result=new List<TypeRecord>();
            for(int i=0;i<library.GetTypeInfoCount();i++) {
                ITypeInfo info=null; IntPtr attrPtr=IntPtr.Zero;
                try {
                    library.GetTypeInfo(i,out info); info.GetTypeAttr(out attrPtr);
                    var attr=Marshal.PtrToStructure<TYPEATTR>(attrPtr);
                    string name,doc,file; int context; info.GetDocumentation(-1,out name,out doc,out context,out file);
                    var members=new List<Member>();
                    for(int f=0;f<attr.cFuncs;f++) {
                        IntPtr ptr=IntPtr.Zero;
                        try {
                            info.GetFuncDesc(f,out ptr);var desc=Marshal.PtrToStructure<FUNCDESC>(ptr);
                            string fn;info.GetDocumentation(desc.memid,out fn,out doc,out context,out file);
                            int count;var names=new string[Math.Max(1,desc.cParams+1)];info.GetNames(desc.memid,names,names.Length,out count);Array.Resize(ref names,count);
                            members.Add(new Member {index=f,memberId=desc.memid,parameterCount=desc.cParams,name=fn,invocation=desc.invkind.ToString(),names=names});
                        } finally {if(ptr!=IntPtr.Zero)info.ReleaseFuncDesc(ptr);}
                    }
                    result.Add(new TypeRecord {index=i,name=name,kind=attr.typekind.ToString(),members=members.ToArray()});
                } finally {if(info!=null){if(attrPtr!=IntPtr.Zero)info.ReleaseTypeAttr(attrPtr);Marshal.ReleaseComObject(info);}}
            }
            return result.ToArray();
        } finally {if(library!=null)Marshal.ReleaseComObject(library);}
    }
}
'@
    }
    $full=[IO.Path]::GetFullPath($Path)
    [pscustomobject]@{path=$full;sha256=(Get-FileHash -LiteralPath $full).Hash.ToLowerInvariant();types=@([HancomStaticTypeInventory]::Read($full));executionVerified=$false}
}

Export-ModuleMember -Function ConvertFrom-HancomCommandDefinitions,Get-HancomEmbeddedDefinitions,Get-HancomTypeLibraryInventory
