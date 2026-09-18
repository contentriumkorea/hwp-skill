// 본 제품은 (주)한글과컴퓨터의 한글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Contentrium.HwpSkill
{
    public sealed class CompoundElement
    {
        public string Name { get; set; }
        public int Type { get; set; }
        public long Size { get; set; }
    }

    // Read-only CFB v3/v4. No native libraries, COM, temporary files, or writes.
    // Direct callers also have limits: 512 MiB files, 256 MiB returned streams,
    // 65,536 directory slots (8 MiB on disk). Tables are physically bounded.
    public sealed class CompoundFileSession : IDisposable
    {
        internal const long MaximumFileBytes = 536870912;
        private const int MaximumStreamBytes = 268435456;
        private const int MaximumDirectoryEntries = 65536;
        private const uint Free = 0xFFFFFFFF, End = 0xFFFFFFFE;
        private const uint FatSector = 0xFFFFFFFD, DifatSector = 0xFFFFFFFC;
        private readonly object sync = new object();
        private FileStream file;
        private long fileLength;
        private int sectorSize, sectorCount;
        private uint[] fat, miniFat;
        private bool[] allocated;
        private int[] rootChain;
        private List<Entry> entries;

        private sealed class Entry
        {
            internal string Name;
            internal int Type;
            internal uint Left, Right, Child, Start;
            internal long Size;
            internal List<int> Children;
            internal Dictionary<string, int> Names;
        }

        internal CompoundFileSession(FileStream stream, long maximumBytes)
        {
            file = stream;
            fileLength = file.Length;
            if (fileLength > maximumBytes || fileLength > MaximumFileBytes)
                throw Invalid("File exceeds the configured safety limit.");
            Load();
        }

        private static InvalidDataException Invalid(string reason)
        {
            return new InvalidDataException("Invalid compound file: " + reason);
        }

        private static ushort U16(byte[] b, int p)
        {
            return (ushort)(b[p] | (b[p + 1] << 8));
        }

        private static uint U32(byte[] b, int p)
        {
            return (uint)(b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24));
        }

        private void ReadAt(long offset, byte[] bytes, int destination, int count)
        {
            if (offset < 0 || count < 0 || offset > fileLength - count)
                throw Invalid("Read exceeds physical file bounds.");
            file.Position = offset;
            while (count > 0)
            {
                int read = file.Read(bytes, destination, count);
                if (read == 0) throw Invalid("Unexpected end of file.");
                destination += read;
                count -= read;
            }
        }

        private int Sector(uint sid)
        {
            if (sid >= (uint)sectorCount) throw Invalid("Sector is outside the physical file.");
            return (int)sid;
        }

        private byte[] ReadSector(uint sid)
        {
            byte[] bytes = new byte[sectorSize];
            ReadAt(((long)Sector(sid) + 1) * sectorSize, bytes, 0, bytes.Length);
            return bytes;
        }

        private void Claim(uint sid)
        {
            int index = Sector(sid);
            if (allocated[index]) throw Invalid("Sector cycle or shared sector ownership.");
            allocated[index] = true;
        }

        private void AddFatSector(uint sid, List<uint> sectors, uint expected)
        {
            if (sid == Free) return;
            if (sectors.Count >= expected) throw Invalid("Excess FAT sectors in DIFAT.");
            Claim(sid);
            sectors.Add(sid);
        }

        private void Load()
        {
            byte[] header = new byte[512];
            ReadAt(0, header, 0, header.Length);
            byte[] signature = { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
            for (int i = 0; i < signature.Length; i++)
                if (header[i] != signature[i]) throw Invalid("Header signature mismatch.");
            int version = U16(header, 26), shift = U16(header, 30);
            if ((version != 3 && version != 4) ||
                (version == 3 && shift != 9) || (version == 4 && shift != 12) ||
                U16(header, 28) != 0xFFFE || U16(header, 32) != 6 || U32(header, 56) != 4096)
                throw Invalid("Unsupported header version, byte order, or sector geometry.");
            for (int i = 8; i < 24; i++)
                if (header[i] != 0) throw Invalid("Nonzero header CLSID.");
            for (int i = 34; i < 40; i++)
                if (header[i] != 0) throw Invalid("Nonzero reserved header bytes.");
            sectorSize = 1 << shift;
            if (fileLength < 3L * sectorSize || fileLength % sectorSize != 0)
                throw Invalid("Truncated or misaligned file.");
            sectorCount = (int)(fileLength / sectorSize - 1);
            allocated = new bool[sectorCount];
            if (version == 4)
            {
                byte[] padding = new byte[sectorSize - 512];
                ReadAt(512, padding, 0, padding.Length);
                foreach (byte value in padding)
                    if (value != 0) throw Invalid("Nonzero v4 header padding.");
            }
            uint directoryCount = U32(header, 40), fatCount = U32(header, 44);
            uint miniFatCount = U32(header, 64), difatCount = U32(header, 72);
            int words = sectorSize / 4;
            if ((version == 3 && directoryCount != 0) || (version == 4 && directoryCount == 0) ||
                directoryCount > sectorCount || fatCount == 0 || fatCount > sectorCount ||
                miniFatCount > sectorCount || difatCount > sectorCount ||
                (long)fatCount * words < sectorCount ||
                fatCount > 109L + (long)difatCount * (words - 1))
                throw Invalid("Allocation table counts exceed file bounds.");

            List<uint> fatSectors = new List<uint>(), difatSectors = new List<uint>();
            for (int i = 0; i < 109; i++) AddFatSector(U32(header, 76 + i * 4), fatSectors, fatCount);
            uint next = U32(header, 68);
            for (uint i = 0; i < difatCount; i++)
            {
                Claim(next);
                difatSectors.Add(next);
                byte[] bytes = ReadSector(next);
                for (int j = 0; j < words - 1; j++) AddFatSector(U32(bytes, j * 4), fatSectors, fatCount);
                next = U32(bytes, sectorSize - 4);
            }
            if (next != End || fatSectors.Count != fatCount)
                throw Invalid("DIFAT chain length or FAT count mismatch.");
            fat = new uint[sectorCount];
            long slot = 0;
            foreach (uint sid in fatSectors)
            {
                byte[] bytes = ReadSector(sid);
                for (int j = 0; j < words; j++, slot++)
                {
                    uint value = U32(bytes, j * 4);
                    if (slot < sectorCount) fat[(int)slot] = value;
                    else if (value != Free) throw Invalid("Allocated FAT slot beyond end of file.");
                }
            }
            foreach (uint sid in fatSectors)
                if (fat[(int)sid] != FatSector) throw Invalid("FAT sector marker mismatch.");
            foreach (uint sid in difatSectors)
                if (fat[(int)sid] != DifatSector) throw Invalid("DIFAT sector marker mismatch.");

            int[] directory = Chain(U32(header, 48), version == 4 ? (long)directoryCount : -1,
                MaximumDirectoryEntries / (sectorSize / 128));
            if (directory.Length == 0) throw Invalid("Directory is empty.");
            entries = new List<Entry>();
            UnicodeEncoding unicode = new UnicodeEncoding(false, false, true);
            foreach (int sid in directory)
            {
                byte[] bytes = ReadSector((uint)sid);
                for (int p = 0; p < bytes.Length; p += 128)
                {
                    int type = bytes[p + 66];
                    if (type == 0) { entries.Add(null); continue; }
                    if (type != 1 && type != 2 && type != 5) throw Invalid("Invalid directory object type.");
                    int nameBytes = U16(bytes, p + 64);
                    if (nameBytes < 4 || nameBytes > 64 || nameBytes % 2 != 0 ||
                        U16(bytes, p + nameBytes - 2) != 0 || bytes[p + 67] > 1)
                        throw Invalid("Invalid directory name or color.");
                    string name;
                    try { name = unicode.GetString(bytes, p, nameBytes - 2); }
                    catch (DecoderFallbackException) { throw Invalid("Invalid directory UTF-16 name."); }
                    if (name.IndexOfAny(new char[] { '\0', '/', '\\', ':', '!' }) >= 0)
                        throw Invalid("Invalid character in directory name.");
                    ulong size = U32(bytes, p + 120);
                    // MS-CFB: old v3 writers leave the upper DWORD uninitialized.
                    if (version == 4) size |= (ulong)U32(bytes, p + 124) << 32;
                    if (size > (ulong)fileLength) throw Invalid("Declared stream size exceeds physical file.");
                    Entry entry = new Entry();
                    entry.Name = name;
                    entry.Type = type;
                    entry.Left = U32(bytes, p + 68);
                    entry.Right = U32(bytes, p + 72);
                    entry.Child = U32(bytes, p + 76);
                    entry.Start = U32(bytes, p + 116);
                    entry.Size = (long)size;
                    if (type == 1 && (entry.Size != 0 || entry.Start != 0))
                        throw Invalid("Storage entry contains stream data.");
                    if (type == 2 && entry.Child != Free) throw Invalid("Stream has directory children.");
                    entries.Add(entry);
                }
            }
            BuildHierarchy();
            Entry root = entries[0];
            if (root.Size % 64 != 0) throw Invalid("Mini stream size is not aligned to mini sectors.");
            rootChain = Chain(root.Start, SectorLength(root.Size, sectorSize), sectorCount);
            int miniCount = (int)(root.Size / 64);
            if ((long)miniFatCount * words < miniCount)
                throw Invalid("Mini FAT cannot address the root mini stream.");
            int[] miniFatChain = Chain(U32(header, 60), miniFatCount, sectorCount);
            miniFat = new uint[miniCount];
            slot = 0;
            foreach (int sid in miniFatChain)
            {
                byte[] bytes = ReadSector((uint)sid);
                for (int j = 0; j < words; j++, slot++)
                {
                    uint value = U32(bytes, j * 4);
                    if (slot < miniCount) miniFat[(int)slot] = value;
                    else if (value != Free) throw Invalid("Allocated mini FAT slot beyond the root stream.");
                }
            }
            bool[] miniAllocated = new bool[miniCount];
            foreach (Entry entry in entries)
                if (entry != null && entry.Type == 2)
                    ValidateStreamChain(entry, entry.Size < 4096, miniAllocated);
            for (int i = 0; i < sectorCount; i++)
                if (!allocated[i] && fat[i] != Free) throw Invalid("Unowned allocated sector.");
            for (int i = 0; i < miniCount; i++)
                if (!miniAllocated[i] && miniFat[i] != Free) throw Invalid("Unowned allocated mini sector.");
            allocated = null;
        }

        private static long SectorLength(long size, int unit)
        {
            return size / unit + (size % unit == 0 ? 0 : 1);
        }

        // Iterative ownership validation; expected == -1 only for v3 directory.
        private int[] Chain(uint start, long expected, int limit)
        {
            if (expected > limit) throw Invalid("Chain exceeds the configured safety limit.");
            List<int> chain = new List<int>();
            uint sid = start;
            while (sid != End)
            {
                if (chain.Count >= limit || (expected >= 0 && chain.Count >= expected))
                    throw Invalid("Chain is longer than its declared size or safety limit.");
                Claim(sid);
                chain.Add((int)sid);
                sid = fat[(int)sid];
            }
            if (expected >= 0 && chain.Count != expected) throw Invalid("Chain is shorter than its declared size.");
            return chain.ToArray();
        }

        private void ValidateStreamChain(Entry entry, bool mini, bool[] miniAllocated)
        {
            long expected = SectorLength(entry.Size, mini ? 64 : sectorSize);
            uint sid = entry.Start;
            for (long i = 0; i < expected; i++)
            {
                if (mini)
                {
                    if (sid >= miniFat.Length) throw Invalid("Mini sector is outside the root mini stream.");
                    if (miniAllocated[(int)sid]) throw Invalid("Mini sector cycle or shared ownership.");
                    miniAllocated[(int)sid] = true;
                    sid = miniFat[(int)sid];
                }
                else { Claim(sid); sid = fat[(int)sid]; }
            }
            if (sid != End) throw Invalid("Stream chain length differs from its declared size.");
        }

        private Entry DirectoryEntry(uint id)
        {
            if (id >= entries.Count || entries[(int)id] == null)
                throw Invalid("Directory reference is outside the allocated directory.");
            return entries[(int)id];
        }

        private void BuildHierarchy()
        {
            Entry root = DirectoryEntry(0);
            if (root.Type != 5 || root.Left != Free || root.Right != Free)
                throw Invalid("Invalid root directory entry.");
            bool[] seen = new bool[entries.Count];
            seen[0] = true;
            Stack<int> storages = new Stack<int>();
            storages.Push(0);
            while (storages.Count > 0)
            {
                Entry parent = entries[storages.Pop()];
                parent.Children = new List<int>();
                parent.Names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                Stack<uint> siblings = new Stack<uint>();
                if (parent.Child != Free) siblings.Push(parent.Child);
                while (siblings.Count > 0)
                {
                    uint id = siblings.Pop();
                    Entry child = DirectoryEntry(id);
                    if (seen[(int)id] || child.Type == 5) throw Invalid("Directory cycle or shared child.");
                    seen[(int)id] = true;
                    if (parent.Names.ContainsKey(child.Name)) throw Invalid("Duplicate directory name.");
                    parent.Names.Add(child.Name, (int)id);
                    parent.Children.Add((int)id);
                    if (child.Left != Free) siblings.Push(child.Left);
                    if (child.Right != Free) siblings.Push(child.Right);
                    if (child.Type == 1) storages.Push((int)id);
                }
                // Reading does not depend on red/black balancing of the disk tree.
                parent.Children.Sort(delegate(int a, int b)
                {
                    int length = entries[a].Name.Length.CompareTo(entries[b].Name.Length);
                    return length != 0 ? length : StringComparer.OrdinalIgnoreCase.Compare(entries[a].Name, entries[b].Name);
                });
            }
            for (int i = 0; i < entries.Count; i++)
                if (entries[i] != null && !seen[i]) throw Invalid("Unreachable directory entry.");
        }

        private Entry Storage(string storagePath)
        {
            Entry current = entries[0];
            if (String.IsNullOrWhiteSpace(storagePath)) return current;
            string[] parts = storagePath.Split(new char[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string part in parts)
            {
                int index;
                if (!current.Names.TryGetValue(part, out index) || entries[index].Type != 1)
                    throw Invalid("Storage path does not exist.");
                current = entries[index];
            }
            return current;
        }

        public byte[] ReadStream(string storagePath, string streamName, int maximumBytes)
        {
            lock (sync)
            {
                EnsureOpen();
                if (String.IsNullOrWhiteSpace(streamName)) throw new ArgumentNullException("streamName");
                if (maximumBytes < 1) throw new ArgumentOutOfRangeException("maximumBytes");
                Entry storage = Storage(storagePath);
                int index;
                if (!storage.Names.TryGetValue(streamName, out index) || entries[index].Type != 2)
                    throw Invalid("Stream does not exist.");
                Entry entry = entries[index];
                if (entry.Size > maximumBytes || entry.Size > MaximumStreamBytes)
                    throw Invalid("Stream exceeds the configured safety limit.");
                // Sizes and chains were validated at Open, before payload allocation.
                byte[] output = new byte[(int)entry.Size];
                bool mini = entry.Size < 4096;
                int unit = mini ? 64 : sectorSize;
                uint sid = entry.Start;
                for (int cursor = 0; cursor < output.Length; cursor += unit)
                {
                    long offset;
                    if (mini)
                    {
                        long miniOffset = (long)sid * 64;
                        offset = ((long)rootChain[(int)(miniOffset / sectorSize)] + 1) * sectorSize + miniOffset % sectorSize;
                    }
                    else offset = ((long)sid + 1) * sectorSize;
                    ReadAt(offset, output, cursor, Math.Min(unit, output.Length - cursor));
                    sid = mini ? miniFat[(int)sid] : fat[(int)sid];
                }
                return output;
            }
        }

        public CompoundElement[] ListElements(string storagePath)
        {
            lock (sync)
            {
                EnsureOpen();
                Entry storage = Storage(storagePath);
                CompoundElement[] result = new CompoundElement[storage.Children.Count];
                for (int i = 0; i < result.Length; i++)
                {
                    Entry entry = entries[storage.Children[i]];
                    result[i] = new CompoundElement { Name = entry.Name, Type = entry.Type, Size = entry.Size };
                }
                return result;
            }
        }

        // Same-handle hash. Unix sharing is advisory; callers also compare a path
        // hash to detect rename/replacement. Hashing restores the read position.
        public string ComputeSha256()
        {
            lock (sync)
            {
                EnsureOpen();
                long position = file.Position;
                try
                {
                    file.Position = 0;
                    using (SHA256 hash = SHA256.Create())
                        return BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
                }
                finally { file.Position = position; }
            }
        }

        private void EnsureOpen()
        {
            if (file == null) throw new ObjectDisposedException("CompoundFileSession");
            if (file.Length != fileLength) throw Invalid("File length changed during the read session.");
        }

        public void Dispose()
        {
            lock (sync)
            {
                if (file == null) return;
                file.Dispose();
                file = null;
                fat = null;
                miniFat = null;
                rootChain = null;
                entries = null;
            }
        }
    }

    public static class CompoundFileReader
    {
        // DeflateStream normally accepts a truncated input as a partial result.
        // A valid final DEFLATE block stops without asking for more input; an
        // exhausted input before that point must fail, including on .NET 4.x.
        private sealed class CompleteDeflateInput : MemoryStream
        {
            internal CompleteDeflateInput(byte[] bytes) : base(bytes, false) { }
            public override int Read(byte[] buffer, int offset, int count)
            {
                if (count > 0 && Position >= Length)
                    throw new InvalidDataException("Truncated DEFLATE stream.");
                return base.Read(buffer, offset, count);
            }
        }

        public static byte[] ExpandDeflate(byte[] bytes, long maximumBytes)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            if (maximumBytes < 1 || maximumBytes > 1073741824)
                throw new ArgumentOutOfRangeException("maximumBytes");
            using (CompleteDeflateInput input = new CompleteDeflateInput(bytes))
            using (DeflateStream inflater = new DeflateStream(input, CompressionMode.Decompress))
            using (MemoryStream output = new MemoryStream())
            {
                byte[] buffer = new byte[81920];
                int read;
                while ((read = inflater.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (read > maximumBytes - output.Length)
                        throw new InvalidDataException("Expanded stream exceeds the configured safety limit.");
                    output.Write(buffer, 0, read);
                }
                return output.ToArray();
            }
        }

        public static CompoundFileSession Open(string filePath)
        {
            return Open(filePath, CompoundFileSession.MaximumFileBytes);
        }

        public static CompoundFileSession Open(string filePath, long maximumFileBytes)
        {
            if (String.IsNullOrWhiteSpace(filePath)) throw new ArgumentNullException("filePath");
            if (maximumFileBytes < 1) throw new ArgumentOutOfRangeException("maximumFileBytes");
            FileStream stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            try { return new CompoundFileSession(stream, maximumFileBytes); }
            catch { stream.Dispose(); throw; }
        }

        public static byte[] ReadStream(string filePath, string storagePath, string streamName, int maximumBytes)
        {
            using (CompoundFileSession session = Open(filePath))
                return session.ReadStream(storagePath, streamName, maximumBytes);
        }

        public static CompoundElement[] ListElements(string filePath, string storagePath)
        {
            using (CompoundFileSession session = Open(filePath))
                return session.ListElements(storagePath);
        }
    }
}
