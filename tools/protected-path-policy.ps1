#requires -Version 7.5
Set-StrictMode -Version Latest

if (-not ("SteadyAgent.BoundPath" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace SteadyAgent
{
    public static class BoundPath
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint DELETE = 0x00010000;
        private const uint FILE_READ_ATTRIBUTES = 0x00000080;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint CREATE_NEW = 1;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        private const int FileRenameInfo = 3;
        private const int FileDispositionInfo = 4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectoryW(
            string pathName,
            IntPtr securityAttributes);

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            int informationClass,
            IntPtr information,
            uint bufferSize);

        private static IOException Win32Failure(string message)
        {
            int error = Marshal.GetLastWin32Error();
            return new IOException(message + " Win32=" + error, new Win32Exception(error));
        }

        private static BY_HANDLE_FILE_INFORMATION GetInformation(SafeFileHandle handle, string path)
        {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw Win32Failure("Cannot inspect the bound path: " + path + ".");
            }
            return information;
        }

        private static SafeFileHandle OpenDirectory(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                Marshal.GetLastWin32Error();
                throw new IOException(
                    "Cannot bind the path directory: " + path + ". Win32=" + error,
                    new Win32Exception(error));
            }
            BY_HANDLE_FILE_INFORMATION information = GetInformation(handle, path);
            if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                handle.Dispose();
                throw new IOException("Bound path directory is not a normal directory: " + path + ".");
            }
            return handle;
        }

        private static SafeFileHandle OpenDirectoryForDelete(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                FILE_READ_ATTRIBUTES | DELETE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new IOException(
                    "Cannot bind the owned directory for deletion: " + path + ". Win32=" + error,
                    new Win32Exception(error));
            }
            BY_HANDLE_FILE_INFORMATION information = GetInformation(handle, path);
            if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                handle.Dispose();
                throw new IOException("Owned directory is not a normal directory: " + path + ".");
            }
            return handle;
        }

        private static string DirectoryIdentity(SafeFileHandle handle, string path)
        {
            BY_HANDLE_FILE_INFORMATION information = GetInformation(handle, path);
            return information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
        }

        private static List<SafeFileHandle> PinParentChain(string filePath)
        {
            string fullPath = Path.GetFullPath(filePath);
            string parent = Path.GetDirectoryName(fullPath);
            if (String.IsNullOrEmpty(parent))
            {
                throw new IOException("Bound file path has no parent directory: " + fullPath + ".");
            }
            List<string> directories = new List<string>();
            string cursor = parent;
            while (!String.IsNullOrEmpty(cursor))
            {
                directories.Add(cursor);
                string next = Path.GetDirectoryName(cursor.TrimEnd(Path.DirectorySeparatorChar));
                if (String.IsNullOrEmpty(next) || String.Equals(next, cursor, StringComparison.OrdinalIgnoreCase))
                {
                    break;
                }
                cursor = next;
            }
            directories.Reverse();
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                foreach (string directory in directories)
                {
                    handles.Add(OpenDirectory(directory));
                }
                return handles;
            }
            catch
            {
                DisposeHandles(handles);
                throw;
            }
        }

        private static void DisposeHandles(List<SafeFileHandle> handles)
        {
            for (int index = handles.Count - 1; index >= 0; index--)
            {
                handles[index].Dispose();
            }
        }

        private static FileStream OpenExistingFile(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                GENERIC_READ | DELETE,
                FILE_SHARE_READ,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new IOException(
                    "Cannot bind the destination file: " + path + ". Win32=" + error,
                    new Win32Exception(error));
            }
            BY_HANDLE_FILE_INFORMATION information = GetInformation(handle, path);
            if ((information.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
            {
                handle.Dispose();
                throw new IOException("Bound destination is not a normal file: " + path + ".");
            }
            return new FileStream(handle, FileAccess.Read, 4096, false);
        }

        private static FileStream CreateTemporaryFile(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                GENERIC_READ | GENERIC_WRITE | DELETE,
                FILE_SHARE_READ,
                IntPtr.Zero,
                CREATE_NEW,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new IOException(
                    "Cannot create the bound temporary file: " + path + ". Win32=" + error,
                    new Win32Exception(error));
            }
            return new FileStream(handle, FileAccess.ReadWrite, 4096, false);
        }

        private static string HashStream(FileStream stream)
        {
            long position = stream.Position;
            stream.Position = 0;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(stream);
                stream.Position = position;
                return BitConverter.ToString(hash).Replace("-", "");
            }
        }

        private static string ArtifactToken(string fullPath)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(fullPath.ToUpperInvariant());
                string value = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                return value.Substring(0, 20).ToLowerInvariant();
            }
        }

        private static string FileIdentity(FileStream stream)
        {
            BY_HANDLE_FILE_INFORMATION information = GetInformation(stream.SafeFileHandle, "bound file");
            return information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
        }

        private static string EncodeField(string value)
        {
            return Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(value ?? String.Empty));
        }

        private static string DecodeField(string value)
        {
            return System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(value));
        }

        private static FileStream CreateIntent(
            string intentPath,
            string operation,
            string destination,
            string expectedHash,
            string desiredHash,
            string originalIdentity)
        {
            FileStream intent = CreateTemporaryFile(intentPath);
            try
            {
                string text = "STEADYAGENT_BOUND_MUTATION_V1\n" + operation + "\n" +
                    EncodeField(destination) + "\n" + (expectedHash ?? "MISSING") + "\n" +
                    (desiredHash ?? "DELETE") + "\n" + (originalIdentity ?? "MISSING") + "\n";
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(text);
                intent.Write(bytes, 0, bytes.Length);
                intent.Flush(true);
                return intent;
            }
            catch
            {
                intent.Dispose();
                throw;
            }
        }

        private static string[] ReadIntent(FileStream intent)
        {
            long position = intent.Position;
            intent.Position = 0;
            string text;
            using (StreamReader reader = new StreamReader(
                intent, System.Text.Encoding.UTF8, false, 4096, true))
            {
                text = reader.ReadToEnd();
            }
            intent.Position = position;
            string[] lines = text.Split(new string[] { "\n" }, StringSplitOptions.None);
            if (lines.Length != 7 || lines[0] != "STEADYAGENT_BOUND_MUTATION_V1" ||
                (lines[1] != "write" && lines[1] != "delete") || lines[6] != String.Empty)
            {
                throw new IOException("Bound mutation intent is invalid.");
            }
            lines[2] = DecodeField(lines[2]);
            return lines;
        }

        private static FileStream OpenArtifact(string path)
        {
            if (!File.Exists(path)) { return null; }
            return OpenExistingFile(path);
        }

        private static bool IdentityAndHashMatch(
            FileStream stream,
            string identity,
            string hash)
        {
            return stream != null &&
                String.Equals(FileIdentity(stream), identity, StringComparison.Ordinal) &&
                String.Equals(HashStream(stream), hash, StringComparison.OrdinalIgnoreCase);
        }

        private static void RecoverPendingMutation(
            string fullPath,
            SafeFileHandle parent,
            string oldPath,
            string newPath,
            string intentPath,
            out string completedWriteHash,
            out bool completedDelete)
        {
            completedWriteHash = null;
            completedDelete = false;
            bool oldExists = File.Exists(oldPath) || Directory.Exists(oldPath);
            bool newExists = File.Exists(newPath) || Directory.Exists(newPath);
            bool intentExists = File.Exists(intentPath) || Directory.Exists(intentPath);
            if (!oldExists && !newExists && !intentExists) { return; }
            if (Directory.Exists(oldPath) || Directory.Exists(newPath) || Directory.Exists(intentPath))
            {
                throw new IOException("A bound mutation artifact is not a normal file: " + fullPath + ".");
            }

            FileStream intent = null;
            FileStream target = null;
            FileStream oldFile = null;
            FileStream newFile = null;
            try
            {
                if (!intentExists)
                {
                    throw new IOException("A pending bound mutation has no durable intent: " + fullPath + ".");
                }
                intent = OpenArtifact(intentPath);
                string[] record;
                try { record = ReadIntent(intent); }
                catch
                {
                    if (!oldExists && !newExists && File.Exists(fullPath))
                    {
                        DeleteByHandle(intent.SafeFileHandle);
                        return;
                    }
                    throw;
                }
                string operation = record[1];
                string destination = record[2];
                string expectedHash = record[3] == "MISSING" ? null : record[3];
                string desiredHash = record[4] == "DELETE" ? null : record[4];
                string originalIdentity = record[5] == "MISSING" ? null : record[5];
                if (!String.Equals(destination, fullPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("Bound mutation intent targets another destination.");
                }
                target = OpenArtifact(fullPath);
                oldFile = OpenArtifact(oldPath);
                newFile = OpenArtifact(newPath);
                bool targetIsOriginal = originalIdentity == null
                    ? target == null
                    : IdentityAndHashMatch(target, originalIdentity, expectedHash);
                bool oldIsOriginal = originalIdentity != null &&
                    IdentityAndHashMatch(oldFile, originalIdentity, expectedHash);
                bool targetIsDesired = target != null && desiredHash != null &&
                    String.Equals(HashStream(target), desiredHash, StringComparison.OrdinalIgnoreCase);
                bool newIsDesired = newFile != null && desiredHash != null &&
                    String.Equals(HashStream(newFile), desiredHash, StringComparison.OrdinalIgnoreCase);

                if (operation == "write")
                {
                    if (targetIsOriginal && oldFile == null && newFile == null)
                    {
                        DeleteByHandle(intent.SafeFileHandle);
                        return;
                    }
                    if (targetIsOriginal && oldFile == null && newIsDesired)
                    {
                        DeleteByHandle(newFile.SafeFileHandle);
                        DeleteByHandle(intent.SafeFileHandle);
                        return;
                    }
                    if (target == null && (originalIdentity == null || oldIsOriginal) && newIsDesired)
                    {
                        RenameByHandle(newFile.SafeFileHandle, parent, fullPath);
                        if (oldFile != null) { DeleteByHandle(oldFile.SafeFileHandle); }
                        DeleteByHandle(intent.SafeFileHandle);
                        completedWriteHash = desiredHash;
                        return;
                    }
                    if (targetIsDesired && newFile == null &&
                        (oldFile == null || oldIsOriginal))
                    {
                        if (oldFile != null) { DeleteByHandle(oldFile.SafeFileHandle); }
                        DeleteByHandle(intent.SafeFileHandle);
                        completedWriteHash = desiredHash;
                        return;
                    }
                }
                else
                {
                    if (targetIsOriginal && oldFile == null && newFile == null)
                    {
                        DeleteByHandle(intent.SafeFileHandle);
                        return;
                    }
                    if (target == null && newFile == null &&
                        (oldFile == null || oldIsOriginal))
                    {
                        if (oldFile != null) { DeleteByHandle(oldFile.SafeFileHandle); }
                        DeleteByHandle(intent.SafeFileHandle);
                        completedDelete = true;
                        return;
                    }
                }
                throw new IOException("Pending bound mutation state is ambiguous: " + fullPath + ".");
            }
            finally
            {
                if (newFile != null) { newFile.Dispose(); }
                if (oldFile != null) { oldFile.Dispose(); }
                if (target != null) { target.Dispose(); }
                if (intent != null) { intent.Dispose(); }
            }
        }

        private static void RenameByHandle(
            SafeFileHandle file,
            SafeFileHandle parent,
            string destinationPath)
        {
            if (String.IsNullOrWhiteSpace(destinationPath) ||
                !Path.IsPathRooted(destinationPath))
            {
                throw new IOException("Bound rename requires one absolute destination path.");
            }
            byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(Path.GetFullPath(destinationPath));
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
            int nameOffset = IntPtr.Size == 8 ? 20 : 12;
            int size = nameOffset + nameBytes.Length + 2;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                for (int index = 0; index < size; index++) { Marshal.WriteByte(buffer, index, 0); }
                Marshal.WriteInt32(buffer, 0, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
                Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
                if (!SetFileInformationByHandle(file, FileRenameInfo, buffer, (uint)size))
                {
                    throw Win32Failure("Bound non-replacing rename failed for: " + destinationPath + ".");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static void DeleteByHandle(SafeFileHandle file)
        {
            IntPtr buffer = Marshal.AllocHGlobal(4);
            try
            {
                Marshal.WriteInt32(buffer, 1);
                if (!SetFileInformationByHandle(file, FileDispositionInfo, buffer, 4))
                {
                    throw Win32Failure("Bound file deletion failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static void VerifyExpectedState(
            FileStream existing,
            bool requireMissing,
            string expectedCurrentHash,
            string destination)
        {
            if (requireMissing)
            {
                if (existing != null)
                {
                    throw new IOException("Bound destination unexpectedly exists: " + destination + ".");
                }
                return;
            }
            if (existing == null)
            {
                throw new IOException("Bound destination unexpectedly disappeared: " + destination + ".");
            }
            string actual = HashStream(existing);
            if (String.IsNullOrWhiteSpace(expectedCurrentHash) ||
                !String.Equals(actual, expectedCurrentHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Bound destination changed before mutation: " + destination + ".");
            }
        }

        public static void WriteAtomic(
            string destination,
            byte[] bytes,
            bool requireMissing,
            string expectedCurrentHash,
            Action afterParentPin,
            Action afterOldRename,
            Action afterPublish)
        {
            string fullPath = Path.GetFullPath(destination);
            string parentPath = Path.GetDirectoryName(fullPath);
            string destinationLeaf = Path.GetFileName(fullPath);
            string token = ArtifactToken(fullPath);
            string oldLeaf = ".steadyagent-v2-atomic-" + token + ".old";
            string newLeaf = ".steadyagent-v2-atomic-" + token + ".new";
            string intentLeaf = ".steadyagent-v2-atomic-" + token + ".intent";
            string oldPath = Path.Combine(parentPath, oldLeaf);
            string newPath = Path.Combine(parentPath, newLeaf);
            string intentPath = Path.Combine(parentPath, intentLeaf);
            List<SafeFileHandle> directories = PinParentChain(fullPath);
            FileStream existing = null;
            FileStream temporary = null;
            FileStream intent = null;
            bool oldRenamed = false;
            bool published = false;
            try
            {
                SafeFileHandle parent = directories[directories.Count - 1];
                if (afterParentPin != null) { afterParentPin(); }
                string recoveredWriteHash;
                bool recoveredDelete;
                RecoverPendingMutation(
                    fullPath, parent, oldPath, newPath, intentPath,
                    out recoveredWriteHash, out recoveredDelete);
                string desiredHash;
                using (SHA256 sha = SHA256.Create())
                {
                    desiredHash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                }
                if (String.Equals(recoveredWriteHash, desiredHash, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
                if (File.Exists(fullPath))
                {
                    existing = OpenExistingFile(fullPath);
                }
                else if (Directory.Exists(fullPath))
                {
                    throw new IOException("Bound destination is a directory: " + fullPath + ".");
                }
                VerifyExpectedState(existing, requireMissing, expectedCurrentHash, fullPath);
                intent = CreateIntent(
                    intentPath,
                    "write",
                    fullPath,
                    expectedCurrentHash,
                    desiredHash,
                    existing == null ? null : FileIdentity(existing));
                temporary = CreateTemporaryFile(newPath);
                temporary.Write(bytes, 0, bytes.Length);
                temporary.Flush(true);
                if (!String.Equals(HashStream(temporary), desiredHash, StringComparison.Ordinal))
                {
                    throw new IOException("Bound temporary file verification failed: " + fullPath + ".");
                }
                if (existing != null)
                {
                    RenameByHandle(existing.SafeFileHandle, parent, oldPath);
                    oldRenamed = true;
                    if (afterOldRename != null) { afterOldRename(); }
                }
                RenameByHandle(temporary.SafeFileHandle, parent, fullPath);
                published = true;
                if (afterPublish != null) { afterPublish(); }
                if (existing != null)
                {
                    DeleteByHandle(existing.SafeFileHandle);
                }
                DeleteByHandle(intent.SafeFileHandle);
            }
            catch
            {
                if (oldRenamed && !published && existing != null)
                {
                    try
                    {
                        if (!File.Exists(fullPath) && !Directory.Exists(fullPath))
                        {
                            RenameByHandle(
                                existing.SafeFileHandle,
                                directories[directories.Count - 1],
                                fullPath);
                        }
                    }
                    catch { }
                }
                if (!published && temporary != null)
                {
                    try { DeleteByHandle(temporary.SafeFileHandle); }
                    catch { }
                }
                if (published)
                {
                    try
                    {
                        using (FileStream verified = OpenExistingFile(fullPath))
                        {
                            string desiredHash;
                            using (SHA256 sha = SHA256.Create())
                            {
                                desiredHash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                            }
                            if (String.Equals(HashStream(verified), desiredHash, StringComparison.OrdinalIgnoreCase))
                            {
                                if (existing != null) { try { DeleteByHandle(existing.SafeFileHandle); } catch { } }
                                if (intent != null) { try { DeleteByHandle(intent.SafeFileHandle); } catch { } }
                                return;
                            }
                        }
                    }
                    catch { }
                }
                throw;
            }
            finally
            {
                if (temporary != null) { temporary.Dispose(); }
                if (existing != null) { existing.Dispose(); }
                if (intent != null) { intent.Dispose(); }
                DisposeHandles(directories);
            }
        }

        public static bool RepairPending(string destination)
        {
            string fullPath = Path.GetFullPath(destination);
            string parentPath = Path.GetDirectoryName(fullPath);
            if (!Directory.Exists(parentPath)) { return false; }
            string token = ArtifactToken(fullPath);
            string oldPath = Path.Combine(parentPath, ".steadyagent-v2-atomic-" + token + ".old");
            string newPath = Path.Combine(parentPath, ".steadyagent-v2-atomic-" + token + ".new");
            string intentPath = Path.Combine(parentPath, ".steadyagent-v2-atomic-" + token + ".intent");
            List<SafeFileHandle> directories = PinParentChain(fullPath);
            try
            {
                string completedWriteHash;
                bool completedDelete;
                RecoverPendingMutation(
                    fullPath,
                    directories[directories.Count - 1],
                    oldPath,
                    newPath,
                    intentPath,
                    out completedWriteHash,
                    out completedDelete);
                return completedWriteHash != null || completedDelete;
            }
            finally
            {
                DisposeHandles(directories);
            }
        }

        public static bool HasPending(string destination)
        {
            string fullPath = Path.GetFullPath(destination);
            string parentPath = Path.GetDirectoryName(fullPath);
            if (!Directory.Exists(parentPath)) { return false; }
            string token = ArtifactToken(fullPath);
            string prefix = Path.Combine(parentPath, ".steadyagent-v2-atomic-" + token);
            foreach (string suffix in new string[] { ".old", ".new", ".intent" })
            {
                string artifact = prefix + suffix;
                if (File.Exists(artifact) || Directory.Exists(artifact)) { return true; }
            }
            return false;
        }

        public static bool DeleteAtomic(
            string destination,
            bool allowMissing,
            string expectedCurrentHash,
            Action afterParentPin,
            Action afterDeleteRename)
        {
            string fullPath = Path.GetFullPath(destination);
            string parentPath = Path.GetDirectoryName(fullPath);
            string token = ArtifactToken(fullPath);
            string oldLeaf = ".steadyagent-v2-atomic-" + token + ".old";
            string newLeaf = ".steadyagent-v2-atomic-" + token + ".new";
            string intentLeaf = ".steadyagent-v2-atomic-" + token + ".intent";
            string oldPath = Path.Combine(parentPath, oldLeaf);
            string newPath = Path.Combine(parentPath, newLeaf);
            string intentPath = Path.Combine(parentPath, intentLeaf);
            List<SafeFileHandle> directories = PinParentChain(fullPath);
            FileStream existing = null;
            FileStream intent = null;
            try
            {
                SafeFileHandle parent = directories[directories.Count - 1];
                if (afterParentPin != null) { afterParentPin(); }
                string recoveredWriteHash;
                bool recoveredDelete;
                RecoverPendingMutation(
                    fullPath, parent, oldPath, newPath, intentPath,
                    out recoveredWriteHash, out recoveredDelete);
                if (recoveredDelete) { return true; }
                if (!File.Exists(fullPath))
                {
                    if (Directory.Exists(fullPath))
                    {
                        throw new IOException("Bound deletion target is a directory: " + fullPath + ".");
                    }
                    if (allowMissing) { return false; }
                    throw new IOException("Bound deletion target disappeared: " + fullPath + ".");
                }
                existing = OpenExistingFile(fullPath);
                VerifyExpectedState(existing, false, expectedCurrentHash, fullPath);
                intent = CreateIntent(
                    intentPath,
                    "delete",
                    fullPath,
                    expectedCurrentHash,
                    null,
                    FileIdentity(existing));
                RenameByHandle(existing.SafeFileHandle, parent, oldPath);
                if (afterDeleteRename != null) { afterDeleteRename(); }
                DeleteByHandle(existing.SafeFileHandle);
                DeleteByHandle(intent.SafeFileHandle);
                return true;
            }
            finally
            {
                if (existing != null) { existing.Dispose(); }
                if (intent != null) { intent.Dispose(); }
                DisposeHandles(directories);
            }
        }

        public static uint GetLinkCount(string path)
        {
            using (FileStream stream = OpenExistingFile(Path.GetFullPath(path)))
            {
                BY_HANDLE_FILE_INFORMATION information = GetInformation(
                    stream.SafeFileHandle,
                    path);
                return information.NumberOfLinks;
            }
        }

        public static string CreateOwnedDirectory(string path)
        {
            string fullPath = Path.GetFullPath(path);
            if (!CreateDirectoryW(fullPath, IntPtr.Zero))
            {
                throw Win32Failure("Cannot exclusively create the owned directory: " + fullPath + ".");
            }
            using (SafeFileHandle handle = OpenDirectory(fullPath))
            {
                return DirectoryIdentity(handle, fullPath);
            }
        }

        public static void PublishOwnedDirectory(
            string stagingPath,
            string destinationPath,
            string expectedVolumeSerial,
            string expectedFileId)
        {
            string stagingFull = Path.GetFullPath(stagingPath);
            string destinationFull = Path.GetFullPath(destinationPath);
            if (File.Exists(destinationFull) || Directory.Exists(destinationFull))
            {
                throw new IOException("Owned directory destination already exists: " + destinationFull + ".");
            }
            List<SafeFileHandle> stagingParents = PinParentChain(stagingFull);
            List<SafeFileHandle> destinationParents = PinParentChain(destinationFull);
            try
            {
                using (SafeFileHandle directory = OpenDirectoryForDelete(stagingFull))
                {
                    string expectedIdentity = expectedVolumeSerial + ":" + expectedFileId;
                    string actualIdentity = DirectoryIdentity(directory, stagingFull);
                    if (!String.Equals(actualIdentity, expectedIdentity, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new IOException("Staged owned directory identity changed: " + stagingFull + ".");
                    }
                    using (IEnumerator<string> entries = Directory.EnumerateFileSystemEntries(stagingFull).GetEnumerator())
                    {
                        if (entries.MoveNext())
                        {
                            throw new IOException("Staged owned directory is not empty: " + stagingFull + ".");
                        }
                    }
                    SafeFileHandle destinationParent = destinationParents[destinationParents.Count - 1];
                    string destinationParentIdentity = DirectoryIdentity(
                        destinationParent,
                        Path.GetDirectoryName(destinationFull));
                    if (!destinationParentIdentity.StartsWith(expectedVolumeSerial + ":", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new IOException("Owned directory publication must remain on one volume.");
                    }
                    if (File.Exists(destinationFull) || Directory.Exists(destinationFull))
                    {
                        throw new IOException("Owned directory destination changed before publication: " + destinationFull + ".");
                    }
                    RenameByHandle(directory, destinationParent, destinationFull);
                    string publishedIdentity = DirectoryIdentity(directory, destinationFull);
                    if (!String.Equals(publishedIdentity, expectedIdentity, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new IOException("Published owned directory identity changed: " + destinationFull + ".");
                    }
                }
            }
            finally
            {
                DisposeHandles(destinationParents);
                DisposeHandles(stagingParents);
            }
        }

        public static string GetDirectoryIdentity(string path)
        {
            string fullPath = Path.GetFullPath(path);
            using (SafeFileHandle handle = OpenDirectory(fullPath))
            {
                return DirectoryIdentity(handle, fullPath);
            }
        }

        public static bool DeleteOwnedEmptyDirectory(
            string path,
            string expectedVolumeSerial,
            string expectedFileId)
        {
            string fullPath = Path.GetFullPath(path);
            using (SafeFileHandle handle = OpenDirectoryForDelete(fullPath))
            {
                string expectedIdentity = expectedVolumeSerial + ":" + expectedFileId;
                string actualIdentity = DirectoryIdentity(handle, fullPath);
                if (!String.Equals(actualIdentity, expectedIdentity, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("Owned directory identity changed: " + fullPath + ".");
                }
                using (IEnumerator<string> entries = Directory.EnumerateFileSystemEntries(fullPath).GetEnumerator())
                {
                    if (entries.MoveNext())
                    {
                        throw new IOException("Owned directory is not empty: " + fullPath + ".");
                    }
                }
                IntPtr disposition = Marshal.AllocHGlobal(1);
                try
                {
                    Marshal.WriteByte(disposition, 1);
                    if (!SetFileInformationByHandle(
                        handle,
                        FileDispositionInfo,
                        disposition,
                        1))
                    {
                        throw Win32Failure("Cannot delete the bound owned directory: " + fullPath + ".");
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(disposition);
                }
            }
            return true;
        }
    }
}
'@
}

function Invoke-SteadyAgentBoundAtomicWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [string]$ExpectedCurrentSHA256,
        [switch]$RequireMissing,
        [Action]$AfterParentPin,
        [Action]$AfterOldRename,
        [Action]$AfterPublish
    )

    [SteadyAgent.BoundPath]::WriteAtomic(
        [IO.Path]::GetFullPath($Destination),
        $Bytes,
        [bool]$RequireMissing,
        $ExpectedCurrentSHA256,
        $AfterParentPin,
        $AfterOldRename,
        $AfterPublish
    )
}

function Remove-SteadyAgentBoundFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedCurrentSHA256,
        [switch]$AllowMissing,
        [Action]$AfterParentPin,
        [Action]$AfterDeleteRename
    )

    return [SteadyAgent.BoundPath]::DeleteAtomic(
        [IO.Path]::GetFullPath($Path),
        [bool]$AllowMissing,
        $ExpectedCurrentSHA256,
        $AfterParentPin,
        $AfterDeleteRename
    )
}

function Repair-SteadyAgentBoundMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return [SteadyAgent.BoundPath]::RepairPending([IO.Path]::GetFullPath($Path))
}

function Test-SteadyAgentBoundMutationPending {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return [bool][SteadyAgent.BoundPath]::HasPending([IO.Path]::GetFullPath($Path))
}

function Get-SteadyAgentFileLinkCount {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return [uint32][SteadyAgent.BoundPath]::GetLinkCount([IO.Path]::GetFullPath($Path))
}

function New-SteadyAgentOwnedDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $identity = [SteadyAgent.BoundPath]::CreateOwnedDirectory($fullPath).Split(':')
    if ($identity.Count -ne 2) { throw "Owned directory identity is invalid: $fullPath" }
    return [pscustomobject][ordered]@{
        path = $fullPath
        volume_serial = $identity[0]
        file_id = $identity[1]
    }
}

function Publish-SteadyAgentOwnedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][object]$DirectoryState
    )
    foreach ($name in @('path', 'volume_serial', 'file_id')) {
        if ($DirectoryState.PSObject.Properties.Name -notcontains $name -or
            [string]::IsNullOrWhiteSpace([string]$DirectoryState.$name)) {
            throw "Owned directory state is missing $name."
        }
    }
    [SteadyAgent.BoundPath]::PublishOwnedDirectory(
        [IO.Path]::GetFullPath($StagingPath),
        [IO.Path]::GetFullPath([string]$DirectoryState.path),
        [string]$DirectoryState.volume_serial,
        [string]$DirectoryState.file_id
    )
    return $true
}

function Get-SteadyAgentDirectoryIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $identity = [SteadyAgent.BoundPath]::GetDirectoryIdentity($fullPath).Split(':')
    if ($identity.Count -ne 2) { throw "Directory identity is invalid: $fullPath" }
    return [pscustomobject][ordered]@{
        path = $fullPath
        volume_serial = $identity[0]
        file_id = $identity[1]
    }
}

function Remove-SteadyAgentOwnedEmptyDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$DirectoryState)
    foreach ($name in @('path', 'volume_serial', 'file_id')) {
        if ($DirectoryState.PSObject.Properties.Name -notcontains $name -or
            [string]::IsNullOrWhiteSpace([string]$DirectoryState.$name)) {
            throw "Owned directory state is missing $name."
        }
    }
    return [SteadyAgent.BoundPath]::DeleteOwnedEmptyDirectory(
        [IO.Path]::GetFullPath([string]$DirectoryState.path),
        [string]$DirectoryState.volume_serial,
        [string]$DirectoryState.file_id
    )
}

function Assert-SteadyAgentOwnedDirectoryIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$DirectoryState)
    $current = Get-SteadyAgentDirectoryIdentity -Path ([string]$DirectoryState.path)
    if ([string]$current.volume_serial -cne [string]$DirectoryState.volume_serial -or
        [string]$current.file_id -cne [string]$DirectoryState.file_id) {
        throw ("Owned directory identity changed: " + [string]$DirectoryState.path)
    }
    return $true
}

function Get-WindowsPathAmbiguityReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path -replace "\\", "/"
    $segments = @($normalized -split "/")
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = [string]$segments[$index]
        if (-not $segment) { continue }

        # A leading drive designator is the only colon-bearing path segment
        # accepted by the Windows release. Other colons can select an NTFS
        # alternate data stream, while trailing dots/spaces alias the same
        # Win32 file under a different spelling.
        $isDriveDesignator = ($index -eq 0 -and $segment -match "^[A-Za-z]:$")
        if (-not $isDriveDesignator -and $segment.IndexOf(":") -ge 0) {
            return "ambiguous Windows alternate-stream path"
        }
        if ($segment.EndsWith(".", [StringComparison]::Ordinal) -or
            $segment.EndsWith(" ", [StringComparison]::Ordinal)) {
            return "ambiguous Windows trailing-dot-or-space path"
        }
    }

    return $null
}

function Get-ProtectedPathReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$AllowDocumentationExamples
    )

    $ambiguityReason = Get-WindowsPathAmbiguityReason -Path $Path
    if ($ambiguityReason) { return $ambiguityReason }

    $normalized = $Path -replace "\\", "/"
    $leaf = Split-Path -Leaf $normalized

    if (($leaf -match '(?i)^\.env(\..+)?$') -and ($leaf -notmatch '(?i)^\.env\.example$')) {
        return "env file"
    }

    if ($normalized -match '(?i)(^|/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)(?![.]pub(?:$|/))(\.|$)') {
        return "SSH private key"
    }

    if ($leaf -match '(?i)\.(pem|p12|pfx|key|keystore|jks|asc|ppk|pgpass)$') {
        return "key/certificate file"
    }

    if ($leaf -match '(?i)(^|[._-])(secret|secrets|credential|credentials)([._-]|$)') {
        if ($AllowDocumentationExamples -and
            $leaf -match '(?i)[.](md|txt|example|sample|template|rst|adoc)$') {
            return $null
        }
        return "credential-looking name"
    }

    return $null
}
