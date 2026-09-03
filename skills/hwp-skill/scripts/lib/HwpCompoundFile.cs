// 본 제품은 (주)한글과컴퓨터의 한글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using ComTypes = System.Runtime.InteropServices.ComTypes;

namespace Contentrium.HwpSkill
{
    [ComImport]
    [Guid("0000000D-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IEnumSTATSTG
    {
        [PreserveSig]
        int Next(int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] ComTypes.STATSTG[] stats,
            IntPtr fetched);

        [PreserveSig]
        int Skip(int count);

        [PreserveSig]
        int Reset();

        [PreserveSig]
        int Clone(out IEnumSTATSTG enumerator);
    }

    [ComImport]
    [Guid("0000000B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IStorage
    {
        [PreserveSig]
        int CreateStream([MarshalAs(UnmanagedType.LPWStr)] string name, int mode, int reserved1,
            int reserved2, out ComTypes.IStream stream);

        [PreserveSig]
        int OpenStream([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr reserved1, int mode,
            int reserved2, out ComTypes.IStream stream);

        [PreserveSig]
        int CreateStorage([MarshalAs(UnmanagedType.LPWStr)] string name, int mode, int reserved1,
            int reserved2, out IStorage storage);

        [PreserveSig]
        int OpenStorage([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr priorityStorage,
            int mode, IntPtr excludedNames, int reserved, out IStorage storage);

        [PreserveSig]
        int CopyTo(int interfaceCount, IntPtr interfaceIds, IntPtr excludedNames, IntPtr destinationStorage);

        [PreserveSig]
        int MoveElementTo([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr destinationStorage,
            [MarshalAs(UnmanagedType.LPWStr)] string newName, int flags);

        [PreserveSig]
        int Commit(int flags);

        [PreserveSig]
        int Revert();

        [PreserveSig]
        int EnumElements(int reserved1, IntPtr reserved2, int reserved3, out IEnumSTATSTG enumerator);

        [PreserveSig]
        int DestroyElement([MarshalAs(UnmanagedType.LPWStr)] string name);

        [PreserveSig]
        int RenameElement([MarshalAs(UnmanagedType.LPWStr)] string oldName,
            [MarshalAs(UnmanagedType.LPWStr)] string newName);

        [PreserveSig]
        int SetElementTimes([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr creationTime,
            IntPtr accessTime, IntPtr modificationTime);

        [PreserveSig]
        int SetClass(ref Guid classId);

        [PreserveSig]
        int SetStateBits(int stateBits, int mask);

        [PreserveSig]
        int Stat(out ComTypes.STATSTG stat, int flags);
    }

    public sealed class CompoundElement
    {
        public string Name { get; set; }
        public int Type { get; set; }
        public long Size { get; set; }
    }

    public sealed class CompoundFileSession : IDisposable
    {
        private IStorage root;
        private FileStream fileLock;

        internal CompoundFileSession(IStorage rootStorage, FileStream readLock)
        {
            if (rootStorage == null) throw new ArgumentNullException("rootStorage");
            if (readLock == null) throw new ArgumentNullException("readLock");
            root = rootStorage;
            fileLock = readLock;
        }

        public byte[] ReadStream(string storagePath, string streamName, int maximumBytes)
        {
            EnsureOpen();
            if (String.IsNullOrWhiteSpace(streamName)) throw new ArgumentNullException("streamName");
            if (maximumBytes < 1) throw new ArgumentOutOfRangeException("maximumBytes");

            var release = new List<object>();
            try
            {
                IStorage storage = CompoundFileReader.OpenStoragePath(root, storagePath, release);
                ComTypes.IStream stream;
                int hr = storage.OpenStream(streamName, IntPtr.Zero, CompoundFileReader.StgmReadShareExclusive,
                    0, out stream);
                Marshal.ThrowExceptionForHR(hr);
                release.Add(stream);

                ComTypes.STATSTG stat;
                stream.Stat(out stat, CompoundFileReader.StatFlagNoName);
                if (stat.cbSize < 0 || stat.cbSize > maximumBytes)
                {
                    throw new InvalidDataException("Compound stream exceeds the configured safety limit.");
                }

                using (var output = new MemoryStream((int)stat.cbSize))
                {
                    byte[] buffer = new byte[81920];
                    IntPtr bytesReadPointer = Marshal.AllocCoTaskMem(sizeof(int));
                    try
                    {
                        while (true)
                        {
                            Marshal.WriteInt32(bytesReadPointer, 0);
                            stream.Read(buffer, buffer.Length, bytesReadPointer);
                            int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                            if (bytesRead <= 0) break;
                            output.Write(buffer, 0, bytesRead);
                            if (output.Length > maximumBytes)
                            {
                                throw new InvalidDataException("Compound stream exceeds the configured safety limit.");
                            }
                        }
                    }
                    finally
                    {
                        Marshal.FreeCoTaskMem(bytesReadPointer);
                    }
                    return output.ToArray();
                }
            }
            finally
            {
                CompoundFileReader.ReleaseAll(release);
            }
        }

        public CompoundElement[] ListElements(string storagePath)
        {
            EnsureOpen();
            var release = new List<object>();
            try
            {
                IStorage storage = CompoundFileReader.OpenStoragePath(root, storagePath, release);
                IEnumSTATSTG enumerator;
                int hr = storage.EnumElements(0, IntPtr.Zero, 0, out enumerator);
                Marshal.ThrowExceptionForHR(hr);
                release.Add(enumerator);

                var elements = new List<CompoundElement>();
                var stats = new ComTypes.STATSTG[1];
                IntPtr fetchedPointer = Marshal.AllocCoTaskMem(sizeof(int));
                try
                {
                    while (true)
                    {
                        Marshal.WriteInt32(fetchedPointer, 0);
                        int nextHr = enumerator.Next(1, stats, fetchedPointer);
                        int fetched = Marshal.ReadInt32(fetchedPointer);
                        if (fetched == 0) break;
                        if (nextHr < 0) Marshal.ThrowExceptionForHR(nextHr);
                        elements.Add(new CompoundElement
                        {
                            Name = stats[0].pwcsName,
                            Type = stats[0].type,
                            Size = stats[0].cbSize
                        });
                    }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(fetchedPointer);
                }
                return elements.ToArray();
            }
            finally
            {
                CompoundFileReader.ReleaseAll(release);
            }
        }

        public void Dispose()
        {
            IStorage storage = root;
            FileStream readLock = fileLock;
            root = null;
            fileLock = null;
            if (storage != null)
            {
                CompoundFileReader.ReleaseAll(new object[] { storage });
            }
            if (readLock != null)
            {
                readLock.Dispose();
            }
        }

        private void EnsureOpen()
        {
            if (root == null) throw new ObjectDisposedException("CompoundFileSession");
        }
    }

    public static class CompoundFileReader
    {
        internal const int StgmReadShareDenyWrite = 0x20;
        internal const int StgmReadShareExclusive = 0x10;
        internal const int StatFlagNoName = 1;

        [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
        private static extern int StgOpenStorage(
            [MarshalAs(UnmanagedType.LPWStr)] string fileName,
            IntPtr priorityStorage,
            int mode,
            IntPtr excludedNames,
            int reserved,
            out IStorage storage);

        public static CompoundFileSession Open(string filePath)
        {
            if (String.IsNullOrWhiteSpace(filePath)) throw new ArgumentNullException("filePath");
            IStorage storage = null;
            FileStream readLock = null;
            try
            {
                storage = OpenRoot(filePath);
                readLock = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
                return new CompoundFileSession(storage, readLock);
            }
            catch
            {
                if (storage != null) ReleaseAll(new object[] { storage });
                if (readLock != null) readLock.Dispose();
                throw;
            }
        }

        public static byte[] ReadStream(string filePath, string storagePath, string streamName, int maximumBytes)
        {
            using (var session = Open(filePath))
            {
                return session.ReadStream(storagePath, streamName, maximumBytes);
            }
        }

        public static CompoundElement[] ListElements(string filePath, string storagePath)
        {
            using (var session = Open(filePath))
            {
                return session.ListElements(storagePath);
            }
        }

        private static IStorage OpenRoot(string filePath)
        {
            IStorage storage;
            int hr = StgOpenStorage(filePath, IntPtr.Zero, StgmReadShareDenyWrite,
                IntPtr.Zero, 0, out storage);
            Marshal.ThrowExceptionForHR(hr);
            return storage;
        }

        internal static IStorage OpenStoragePath(IStorage root, string storagePath, IList<object> release)
        {
            IStorage current = root;
            if (String.IsNullOrWhiteSpace(storagePath)) return current;

            string[] parts = storagePath.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string part in parts)
            {
                IStorage next;
                int hr = current.OpenStorage(part, IntPtr.Zero, StgmReadShareExclusive,
                    IntPtr.Zero, 0, out next);
                Marshal.ThrowExceptionForHR(hr);
                release.Add(next);
                current = next;
            }
            return current;
        }

        internal static void ReleaseAll(IList<object> objects)
        {
            for (int index = objects.Count - 1; index >= 0; index--)
            {
                object value = objects[index];
                if (value != null && Marshal.IsComObject(value))
                {
                    try { Marshal.FinalReleaseComObject(value); }
                    catch { }
                }
            }
        }
    }
}
