# Generic CFB v3 test writer. No HWP template, native storage API, COM or P/Invoke.
# RootStreams keys may be relative CFB paths (e.g. Scripts/DefaultJScript), so
# opaque source streams outside BodyText/BinData can be retained byte for byte.
function Write-ConversionCompoundFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$RootStreams,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$BodyStreams,
        [AllowNull()][hashtable]$BinStreams
    )
    if(-not ('Contentrium.HwpSkill.Tests.ConversionCompoundWriter' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;

namespace Contentrium.HwpSkill.Tests {
    public sealed class ConversionCompoundWriter {
        const uint Free = 0xffffffff, End = 0xfffffffe, FatSector = 0xfffffffd, DifSector = 0xfffffffc;
        const int Sector = 512;
        sealed class Entry {
            internal string Name;
            internal byte Type;
            internal byte[] Data;
            internal int Id, Left = -1, Right = -1, TreeParent = -1, Child = -1;
            internal bool Red = true;
            internal uint Start = End;
            internal ulong Size;
            internal readonly List<int> Children = new List<int>();
            internal readonly Dictionary<string,int> Names = new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        }
        readonly List<Entry> entries = new List<Entry>();
        readonly List<byte[]> sectors = new List<byte[]>();
        readonly List<uint> fat = new List<uint>();
        long payloadBytes;
        static readonly UnicodeEncoding Unicode = new UnicodeEncoding(false, false, true);

        ConversionCompoundWriter() {
            entries.Add(new Entry { Name = "Root Entry", Type = 5, Id = 0, Red = false });
        }
        static void U16(byte[] b, int o, ushort n) { for(int i=0;i<2;i++) b[o+i]=(byte)(n>>(8*i)); }
        static void U32(byte[] b, int o, uint n) { for(int i=0;i<4;i++) b[o+i]=(byte)(n>>(8*i)); }
        static void U64(byte[] b, int o, ulong n) { for(int i=0;i<8;i++) b[o+i]=(byte)(n>>(8*i)); }
        static int Compare(string a, string b) {
            int c = a.Length.CompareTo(b.Length);
            return c != 0 ? c : StringComparer.OrdinalIgnoreCase.Compare(a,b);
        }
        static string[] Parts(string path) {
            if(String.IsNullOrEmpty(path)) throw new ArgumentException("An empty CFB stream path is invalid.");
            string[] parts = path.Replace('\\','/').Split('/');
            foreach(string name in parts) {
                if(name.Length == 0 || name.Length > 31 || name == "." || name == ".." || name.IndexOfAny(new char[] {'\0', ':', '!'}) >= 0)
                    throw new ArgumentException("CFB names must be 1..31 UTF-16 units without reserved characters.");
                Unicode.GetByteCount(name); // Reject unpaired surrogates instead of changing a name.
            }
            return parts;
        }
        int AddEntry(int parent, string name, byte type, byte[] data) {
            if(entries.Count >= 4096) throw new ArgumentException("Test CFB exceeds 4096 directory entries.");
            Entry e = new Entry { Name=name, Type=type, Data=data, Id=entries.Count };
            if(type == 1) e.Start=0;
            if(data != null) e.Size=(ulong)data.Length;
            entries[parent].Names.Add(name,e.Id);
            entries[parent].Children.Add(e.Id);
            entries.Add(e);
            return e.Id;
        }
        int Storage(string[] parts, int length) {
            int parent=0;
            for(int i=0;i<length;i++) {
                int id;
                if(entries[parent].Names.TryGetValue(parts[i],out id)) {
                    if(entries[id].Type != 1) throw new ArgumentException("CFB stream/storage path collision.");
                    parent=id;
                } else parent=AddEntry(parent,parts[i],1,null);
            }
            return parent;
        }
        void AddMap(IDictionary map, string prefix) {
            if(map == null) return;
            List<string> keys=new List<string>();
            foreach(object key in map.Keys) {
                if(!(key is string)) throw new ArgumentException("CFB stream names must be strings.");
                keys.Add((string)key);
            }
            keys.Sort(StringComparer.Ordinal);
            foreach(string key in keys) {
                byte[] data=map[key] as byte[];
                if(data == null) throw new ArgumentException("CFB stream values must be byte arrays (including empty arrays).");
                payloadBytes += data.LongLength;
                if(payloadBytes > 256L*1024*1024) throw new ArgumentException("Test CFB payloads exceed 256 MiB.");
                string[] parts=Parts(prefix+key);
                int parent=Storage(parts,parts.Length-1);
                if(entries[parent].Names.ContainsKey(parts[parts.Length-1])) throw new ArgumentException("Duplicate CFB stream path.");
                AddEntry(parent,parts[parts.Length-1],2,data);
            }
        }
        bool IsRed(int id) { return id >= 0 && entries[id].Red; }
        void RotateLeft(ref int root, int x) {
            int y=entries[x].Right;
            entries[x].Right=entries[y].Left;
            if(entries[y].Left >= 0) entries[entries[y].Left].TreeParent=x;
            entries[y].TreeParent=entries[x].TreeParent;
            if(entries[x].TreeParent < 0) root=y;
            else if(x == entries[entries[x].TreeParent].Left) entries[entries[x].TreeParent].Left=y;
            else entries[entries[x].TreeParent].Right=y;
            entries[y].Left=x; entries[x].TreeParent=y;
        }
        void RotateRight(ref int root, int x) {
            int y=entries[x].Left;
            entries[x].Left=entries[y].Right;
            if(entries[y].Right >= 0) entries[entries[y].Right].TreeParent=x;
            entries[y].TreeParent=entries[x].TreeParent;
            if(entries[x].TreeParent < 0) root=y;
            else if(x == entries[entries[x].TreeParent].Right) entries[entries[x].TreeParent].Right=y;
            else entries[entries[x].TreeParent].Left=y;
            entries[y].Right=x; entries[x].TreeParent=y;
        }
        void BuildTree(Entry storage) {
            int root=-1;
            storage.Children.Sort(delegate(int a,int b) { return Compare(entries[a].Name,entries[b].Name); });
            foreach(int id in storage.Children) {
                int p=-1, cursor=root;
                while(cursor >= 0) { p=cursor; cursor=Compare(entries[id].Name,entries[cursor].Name)<0 ? entries[cursor].Left : entries[cursor].Right; }
                entries[id].TreeParent=p;
                if(p < 0) root=id;
                else if(Compare(entries[id].Name,entries[p].Name)<0) entries[p].Left=id;
                else entries[p].Right=id;
                int z=id;
                while(IsRed(entries[z].TreeParent)) {
                    p=entries[z].TreeParent; int g=entries[p].TreeParent;
                    if(p == entries[g].Left) {
                        int uncle=entries[g].Right;
                        if(IsRed(uncle)) { entries[p].Red=false; entries[uncle].Red=false; entries[g].Red=true; z=g; }
                        else {
                            if(z == entries[p].Right) { z=p; RotateLeft(ref root,z); p=entries[z].TreeParent; g=entries[p].TreeParent; }
                            entries[p].Red=false; entries[g].Red=true; RotateRight(ref root,g);
                        }
                    } else {
                        int uncle=entries[g].Left;
                        if(IsRed(uncle)) { entries[p].Red=false; entries[uncle].Red=false; entries[g].Red=true; z=g; }
                        else {
                            if(z == entries[p].Left) { z=p; RotateRight(ref root,z); p=entries[z].TreeParent; g=entries[p].TreeParent; }
                            entries[p].Red=false; entries[g].Red=true; RotateLeft(ref root,g);
                        }
                    }
                }
                entries[root].Red=false;
            }
            storage.Child=root;
        }
        uint Allocate(byte[] data) {
            if(data.Length == 0) return End;
            int first=sectors.Count, count=(data.Length+Sector-1)/Sector;
            for(int i=0;i<count;i++) {
                byte[] sector=new byte[Sector];
                Buffer.BlockCopy(data,i*Sector,sector,0,Math.Min(Sector,data.Length-i*Sector));
                sectors.Add(sector); fat.Add(i+1==count ? End : (uint)(first+i+1));
            }
            return (uint)first;
        }
        byte[] Build() {
            foreach(Entry e in entries) if(e.Type != 2) BuildTree(e);
            List<uint> miniFat=new List<uint>();
            byte[] miniBytes;
            using(MemoryStream mini=new MemoryStream()) {
                foreach(Entry e in entries) {
                    if(e.Type != 2 || e.Data.Length == 0) continue;
                    if(e.Data.Length >= 4096) { e.Start=Allocate(e.Data); continue; }
                    int first=miniFat.Count, count=(e.Data.Length+63)/64;
                    e.Start=(uint)first;
                    for(int i=0;i<count;i++) miniFat.Add(i+1==count ? End : (uint)(first+i+1));
                    mini.Write(e.Data,0,e.Data.Length);
                    mini.Write(new byte[count*64-e.Data.Length],0,count*64-e.Data.Length);
                }
                miniBytes=mini.ToArray();
            }
            entries[0].Start=Allocate(miniBytes); entries[0].Size=(ulong)miniBytes.Length;
            int miniFatCount=(miniFat.Count+127)/128;
            byte[] miniFatBytes=new byte[miniFatCount*Sector];
            for(int i=0;i<miniFatBytes.Length/4;i++) U32(miniFatBytes,i*4,i<miniFat.Count ? miniFat[i] : Free);
            uint miniFatStart=Allocate(miniFatBytes);
            byte[] directory=new byte[((entries.Count+3)/4)*Sector];
            foreach(Entry e in entries) {
                int o=e.Id*128; byte[] name=Unicode.GetBytes(e.Name+"\0");
                Buffer.BlockCopy(name,0,directory,o,name.Length); U16(directory,o+64,(ushort)name.Length);
                directory[o+66]=e.Type; directory[o+67]=(byte)(e.Red ? 0 : 1);
                U32(directory,o+68,unchecked((uint)e.Left)); U32(directory,o+72,unchecked((uint)e.Right)); U32(directory,o+76,unchecked((uint)e.Child));
                U32(directory,o+116,e.Start); U64(directory,o+120,e.Size);
            }
            uint directoryStart=Allocate(directory);
            int dataCount=sectors.Count, fatCount=0, difatCount=0;
            while(true) {
                int nextFat=(dataCount+fatCount+difatCount+127)/128;
                int nextDifat=Math.Max(0,(nextFat-109+126)/127);
                if(nextFat==fatCount && nextDifat==difatCount) break;
                fatCount=nextFat; difatCount=nextDifat;
            }
            int fatStart=sectors.Count, difatStart=fatStart+fatCount;
            for(int i=0;i<fatCount;i++) { sectors.Add(new byte[Sector]); fat.Add(FatSector); }
            for(int i=0;i<difatCount;i++) { sectors.Add(new byte[Sector]); fat.Add(DifSector); }
            for(int i=0;i<fatCount*128;i++) U32(sectors[fatStart+i/128],4*(i%128),i<fat.Count ? fat[i] : Free);
            for(int d=0;d<difatCount;d++) {
                byte[] block=sectors[difatStart+d];
                for(int i=0;i<127;i++) { int f=109+d*127+i; U32(block,i*4,f<fatCount ? (uint)(fatStart+f) : Free); }
                U32(block,508,d+1<difatCount ? (uint)(difatStart+d+1) : End);
            }
            byte[] header=new byte[Sector];
            Buffer.BlockCopy(new byte[] {0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1},0,header,0,8);
            U16(header,24,0x3e); U16(header,26,3); U16(header,28,0xfffe); U16(header,30,9); U16(header,32,6);
            U32(header,44,(uint)fatCount); U32(header,48,directoryStart); U32(header,56,4096);
            U32(header,60,miniFatStart); U32(header,64,(uint)miniFatCount); U32(header,68,difatCount>0 ? (uint)difatStart : End); U32(header,72,(uint)difatCount);
            for(int i=0;i<109;i++) U32(header,76+i*4,i<fatCount ? (uint)(fatStart+i) : Free);
            using(MemoryStream output=new MemoryStream()) {
                output.Write(header,0,header.Length);
                foreach(byte[] block in sectors) output.Write(block,0,block.Length);
                return output.ToArray();
            }
        }
        public static void Write(string path, IDictionary root, IDictionary body, IDictionary bin) {
            if(root == null || body == null) throw new ArgumentNullException("Stream maps are required.");
            ConversionCompoundWriter writer=new ConversionCompoundWriter();
            writer.Storage(new string[] {"BodyText"},1);
            if(bin != null) writer.Storage(new string[] {"BinData"},1);
            writer.AddMap(root,""); writer.AddMap(body,"BodyText/"); writer.AddMap(bin,"BinData/");
            byte[] bytes=writer.Build();
            string full=System.IO.Path.GetFullPath(path), parent=System.IO.Path.GetDirectoryName(full);
            if(!Directory.Exists(parent)) throw new DirectoryNotFoundException("CFB output directory must exist.");
            if(File.Exists(full) || Directory.Exists(full)) throw new IOException("Refusing to overwrite an existing output.");
            string temporary=System.IO.Path.Combine(parent,".conversion-"+Guid.NewGuid().ToString("N")+".partial.cfb");
            bool owned=false;
            try {
                using(FileStream file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    owned=true; file.Write(bytes,0,bytes.Length); file.Flush(true);
                }
                File.Move(temporary,full); owned=false;
            } finally { if(owned) File.Delete(temporary); }
        }
    }
}
'@ -ErrorAction Stop
    }
    $resolved=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [Contentrium.HwpSkill.Tests.ConversionCompoundWriter]::Write($resolved,$RootStreams,$BodyStreams,$BinStreams)
}
