[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string[]]$Files,

    [switch]$All,

    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    . (Join-Path $PSScriptRoot 'protected-path-policy.ps1')
}
catch {
    [Console]::Error.WriteLine("Cannot load protected path policy; checkpoint is blocked.")
    exit 2
}

if (-not ("SteadyAgent.BoundFile" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SteadyAgent
{
    public static class BoundFile
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint FileReadAttributes = 0x00000080;
        private const uint FileWriteAttributes = 0x00000100;
        private const uint OpenExisting = 3;
        private const uint CreateNew = 1;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileFlagWriteThrough = 0x80000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReadOnly = 0x00000001;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileRenameInfo = 3;
        private const int FileRenameInfoEx = 22;
        private const uint FileRenameFlagReplaceIfExists = 0x00000001;
        private const int ErrorNotSupported = 50;
        private const int ErrorInvalidParameter = 87;
        private const int FileDispositionInfo = 4;
        private const int FileBasicInfo = 0;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
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

        [StructLayout(LayoutKind.Sequential)]
        private struct FileBasicInformation
        {
            public long CreationTime;
            public long LastAccessTime;
            public long LastWriteTime;
            public long ChangeTime;
            public uint FileAttributes;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle handle,
            int fileInformationClass,
            IntPtr fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle,
            out ByHandleFileInformation information);

        private static FileStream Open(
            string path,
            uint access,
            uint disposition,
            FileAccess streamAccess,
            uint flags)
        {
            SafeFileHandle handle = CreateFile(
                Path.GetFullPath(path),
                access | DeleteAccess,
                FileShareRead,
                IntPtr.Zero,
                disposition,
                flags,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            if ((information.FileAttributes &
                (FileAttributeDirectory | FileAttributeReparsePoint)) != 0)
            {
                handle.Dispose();
                throw new IOException("Bound checkpoint path is not a normal file.");
            }
            return new FileStream(handle, streamAccess, 4096, false);
        }

        private static SafeFileHandle OpenDirectory(string path)
        {
            SafeFileHandle handle = CreateFile(
                Path.GetFullPath(path),
                FileReadAttributes,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            if ((information.FileAttributes & FileAttributeDirectory) == 0 ||
                (information.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                handle.Dispose();
                throw new IOException("Checkpoint Git path is not a normal directory: " + path);
            }
            return handle;
        }

        private sealed class DirectoryLease : IDisposable
        {
            private List<SafeFileHandle> handles;

            public DirectoryLease(List<SafeFileHandle> value)
            {
                handles = value;
            }

            public void Dispose()
            {
                if (handles == null) return;
                for (int index = handles.Count - 1; index >= 0; index--)
                {
                    handles[index].Dispose();
                }
                handles = null;
            }
        }

        private sealed class FileSystemNode : IDisposable
        {
            internal SafeFileHandle Handle;
            internal bool IsDirectory;
            internal uint Attributes;
            internal List<FileSystemNode> Children;

            internal FileSystemNode(
                SafeFileHandle handle,
                bool isDirectory,
                uint attributes)
            {
                Handle = handle;
                IsDirectory = isDirectory;
                Attributes = attributes;
                Children = new List<FileSystemNode>();
            }

            public void Dispose()
            {
                if (Children != null)
                {
                    for (int index = Children.Count - 1; index >= 0; index--)
                    {
                        Children[index].Dispose();
                    }
                    Children = null;
                }
                if (Handle != null)
                {
                    Handle.Dispose();
                    Handle = null;
                }
            }
        }

        public sealed class PinnedDirectory : IDisposable
        {
            private List<SafeFileHandle> handles;
            private SafeFileHandle directoryHandle;
            private string directoryPath;

            internal PinnedDirectory(
                List<SafeFileHandle> value,
                SafeFileHandle finalHandle,
                string finalPath)
            {
                handles = value;
                directoryHandle = finalHandle;
                directoryPath = Path.GetFullPath(finalPath);
            }

            public void RenameHere(FileStream stream, string leafName, bool replace)
            {
                if (String.IsNullOrEmpty(leafName) ||
                    leafName == "." || leafName == ".." ||
                    Path.GetFileName(leafName) != leafName)
                {
                    throw new IOException("Bound checkpoint destination is not a leaf name.");
                }
                Rename(
                    stream,
                    Path.Combine(directoryPath, leafName),
                    replace);
            }

            public void Dispose()
            {
                directoryHandle = null;
                directoryPath = null;
                if (handles == null) return;
                for (int index = handles.Count - 1; index >= 0; index--)
                {
                    handles[index].Dispose();
                }
                handles = null;
            }
        }

        public static IDisposable PinDirectoryTree(string directoryPath)
        {
            string cursor = Path.GetFullPath(directoryPath);
            List<string> paths = new List<string>();
            while (!String.IsNullOrEmpty(cursor))
            {
                paths.Add(cursor);
                DirectoryInfo parent = Directory.GetParent(cursor);
                if (parent == null) break;
                cursor = parent.FullName;
            }
            paths.Reverse();
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                foreach (string path in paths)
                {
                    handles.Add(OpenDirectory(path));
                }
                return new DirectoryLease(handles);
            }
            catch
            {
                for (int index = handles.Count - 1; index >= 0; index--)
                {
                    handles[index].Dispose();
                }
                throw;
            }
        }

        public static PinnedDirectory OpenOrCreatePinnedChildDirectory(
            string parentDirectoryPath,
            string childName)
        {
            if (String.IsNullOrEmpty(childName) ||
                childName == "." || childName == ".." ||
                Path.GetFileName(childName) != childName)
            {
                throw new IOException("Checkpoint fanout is not a safe directory leaf.");
            }
            string parentPath = Path.GetFullPath(parentDirectoryPath);
            List<string> paths = new List<string>();
            string cursor = parentPath;
            while (!String.IsNullOrEmpty(cursor))
            {
                paths.Add(cursor);
                DirectoryInfo parent = Directory.GetParent(cursor);
                if (parent == null) break;
                cursor = parent.FullName;
            }
            paths.Reverse();
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                foreach (string path in paths)
                {
                    handles.Add(OpenDirectory(path));
                }
                string childPath = Path.Combine(parentPath, childName);
                Directory.CreateDirectory(childPath);
                SafeFileHandle childHandle = OpenDirectory(childPath);
                handles.Add(childHandle);
                return new PinnedDirectory(handles, childHandle, childPath);
            }
            catch
            {
                for (int index = handles.Count - 1; index >= 0; index--)
                {
                    handles[index].Dispose();
                }
                throw;
            }
        }

        private static FileSystemNode OpenFileSystemNode(string path, bool requireDirectory)
        {
            SafeFileHandle handle = CreateFile(
                Path.GetFullPath(path),
                FileReadAttributes | FileWriteAttributes | DeleteAccess,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }

            FileSystemNode node = null;
            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                {
                    throw new IOException(
                        "Checkpoint quarantine tree contains a reparse point: " + path);
                }
                bool isDirectory =
                    (information.FileAttributes & FileAttributeDirectory) != 0;
                if (requireDirectory && !isDirectory)
                {
                    throw new IOException(
                        "Checkpoint quarantine transaction is not a normal directory: " + path);
                }

                node = new FileSystemNode(
                    handle,
                    isDirectory,
                    information.FileAttributes);
                handle = null;
                if (isDirectory)
                {
                    foreach (string childPath in Directory.EnumerateFileSystemEntries(path))
                    {
                        node.Children.Add(OpenFileSystemNode(childPath, false));
                    }
                }
                return node;
            }
            catch
            {
                if (node != null) node.Dispose();
                if (handle != null) handle.Dispose();
                throw;
            }
        }

        private static void DeleteFileSystemNode(FileSystemNode node)
        {
            for (int index = 0; index < node.Children.Count; index++)
            {
                FileSystemNode child = node.Children[index];
                DeleteFileSystemNode(child);
                child.Dispose();
            }
            node.Children.Clear();

            if ((node.Attributes & FileAttributeReadOnly) != 0)
            {
                FileBasicInformation basic = new FileBasicInformation();
                basic.FileAttributes = node.Attributes & ~FileAttributeReadOnly;
                IntPtr basicBuffer = Marshal.AllocHGlobal(
                    Marshal.SizeOf(typeof(FileBasicInformation)));
                try
                {
                    Marshal.StructureToPtr(basic, basicBuffer, false);
                    if (!SetFileInformationByHandle(
                        node.Handle,
                        FileBasicInfo,
                        basicBuffer,
                        (uint)Marshal.SizeOf(typeof(FileBasicInformation))))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(basicBuffer);
                }
            }

            IntPtr buffer = Marshal.AllocHGlobal(1);
            try
            {
                Marshal.WriteByte(buffer, 0, 1);
                if (!SetFileInformationByHandle(
                    node.Handle,
                    FileDispositionInfo,
                    buffer,
                    1))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void DeletePinnedChildDirectoryTree(
            string parentDirectoryPath,
            string childName)
        {
            if (String.IsNullOrEmpty(childName) ||
                childName == "." || childName == ".." ||
                Path.GetFileName(childName) != childName)
            {
                throw new IOException(
                    "Checkpoint quarantine transaction is not a safe directory leaf.");
            }

            string parentPath = Path.GetFullPath(parentDirectoryPath);
            using (IDisposable parentLease = PinDirectoryTree(parentPath))
            using (FileSystemNode root = OpenFileSystemNode(
                Path.Combine(parentPath, childName),
                true))
            {
                DeleteFileSystemNode(root);
            }
        }

        public static string GetIdentity(FileStream stream)
        {
            if (stream == null)
            {
                throw new ArgumentNullException("stream");
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return String.Format(
                "{0:X8}:{1:X8}{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }

        public static uint GetLinkCount(FileStream stream)
        {
            if (stream == null)
            {
                throw new ArgumentNullException("stream");
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return information.NumberOfLinks;
        }

        public static FileStream OpenReadDelete(string path)
        {
            return Open(
                path,
                GenericRead,
                OpenExisting,
                FileAccess.Read,
                FileAttributeNormal | FileFlagOpenReparsePoint);
        }

        public static FileStream OpenReadShareDelete(string path)
        {
            SafeFileHandle handle = CreateFile(
                Path.GetFullPath(path),
                GenericRead,
                FileShareRead | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            if ((information.FileAttributes &
                (FileAttributeDirectory | FileAttributeReparsePoint)) != 0)
            {
                handle.Dispose();
                throw new IOException("Published checkpoint object is not a normal file.");
            }
            return new FileStream(handle, FileAccess.Read, 4096, false);
        }

        public static FileStream CreateReadWriteDelete(string path)
        {
            return Open(
                path,
                GenericRead | GenericWrite,
                CreateNew,
                FileAccess.ReadWrite,
                FileAttributeNormal | FileFlagWriteThrough | FileFlagOpenReparsePoint);
        }

        public static void Rename(FileStream stream, string destinationPath, bool replace)
        {
            RenameCore(stream, Path.GetFullPath(destinationPath), replace);
        }

        private static void RenameCore(
            FileStream stream,
            string destinationName,
            bool replace)
        {
            if (stream == null)
            {
                throw new ArgumentNullException("stream");
            }
            byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(destinationName);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + sizeof(uint);
            int size = checked(nameOffset + nameBytes.Length + sizeof(char));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
                int informationClass;
                if (replace)
                {
                    Marshal.WriteInt32(
                        buffer,
                        0,
                        unchecked((int)FileRenameFlagReplaceIfExists));
                    informationClass = FileRenameInfoEx;
                }
                else
                {
                    Marshal.WriteByte(buffer, 0, 0);
                    informationClass = FileRenameInfo;
                }
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
                Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
                if (SetFileInformationByHandle(
                    stream.SafeFileHandle,
                    informationClass,
                    buffer,
                    (uint)size))
                {
                    return;
                }
                int error = Marshal.GetLastWin32Error();
                if (replace && (error == ErrorNotSupported || error == ErrorInvalidParameter))
                {
                    Marshal.WriteInt32(buffer, 0, 0);
                    Marshal.WriteByte(buffer, 0, 1);
                    if (SetFileInformationByHandle(
                        stream.SafeFileHandle,
                        FileRenameInfo,
                        buffer,
                        (uint)size))
                    {
                        return;
                    }
                    error = Marshal.GetLastWin32Error();
                }
                Win32Exception reason = new Win32Exception(error);
                throw new Win32Exception(
                    error,
                    "Handle-bound rename failed for destination '" +
                    destinationName + "' (Win32 " + error + ": " + reason.Message + ").");
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void Delete(FileStream stream)
        {
            IntPtr buffer = Marshal.AllocHGlobal(1);
            try
            {
                Marshal.WriteByte(buffer, 0, 1);
                if (!SetFileInformationByHandle(
                    stream.SafeFileHandle,
                    FileDispositionInfo,
                    buffer,
                    1))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
'@
}

function Stop-WithMessage {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
    exit 2
}

function Invoke-GitQuiet {
    param([string[]]$GitArgs)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git @GitArgs 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    [PSCustomObject]@{
        Output = $output
        Code = $code
    }
}

function Get-TextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    } finally { $sha.Dispose() }
}

function Get-FileHashHex {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-StreamHashHex {
    param([IO.Stream]$Stream)
    $originalPosition = $Stream.Position
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
        $Stream.Position = $originalPosition
    }
}

function Copy-BoundStreamToNewFile {
    param(
        [IO.Stream]$Stream,
        [string]$DestinationPath
    )
    $originalPosition = $Stream.Position
    $destination = $null
    try {
        $Stream.Position = 0
        $destination = [IO.File]::Open(
            $DestinationPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $Stream.CopyTo($destination)
        $destination.Flush($true)
    }
    finally {
        if ($null -ne $destination) { $destination.Dispose() }
        $Stream.Position = $originalPosition
    }
}

function Get-StreamUtf8Text {
    param([IO.Stream]$Stream)
    $originalPosition = $Stream.Position
    try {
        $Stream.Position = 0
        $length = [int]$Stream.Length
        $bytes = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $read = $Stream.Read($bytes, $offset, $length - $offset)
            if ($read -le 0) { throw 'Cannot read the bound checkpoint identity file.' }
            $offset += $read
        }
        return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    finally {
        $Stream.Position = $originalPosition
    }
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param([string]$Path, [switch]$AllowMissingLeaf)
    $cursor = [IO.Path]::GetFullPath($Path)
    if ($AllowMissingLeaf -and -not (Test-Path -LiteralPath $cursor)) {
        $cursor = Split-Path -Parent $cursor
    }
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-WithMessage ("Test injection path contains a reparse point: " + $cursor)
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-CheckpointTestInjectionIsolation {
    param(
        [string]$RepositoryRoot,
        [string]$GitCommonDirectory,
        [string]$GitDirectory,
        [string]$ObjectDirectory,
        [string]$IndexPath,
        [string]$HeadPath
    )
    $injectionNames = @(
        'STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE',
        'STEADYAGENT_TEST_INDEX_MUTATION_PATH',
        'STEADYAGENT_TEST_INDEX_ABA_PATH',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_WRITE',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_BACKUP',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION',
        'STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS',
        'STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY',
        'STEADYAGENT_TEST_SWAP_GIT_DIRECTORY_AFTER_PIN',
        'STEADYAGENT_TEST_GIT_DIRECTORY_PARKED_PATH',
        'STEADYAGENT_TEST_GIT_DIRECTORY_ESCAPE_PATH',
        'STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION',
        'STEADYAGENT_TEST_OBJECT_FANOUT_ESCAPE_PATH',
        'STEADYAGENT_TEST_REWRITE_INDEX_LOCK_AFTER_CLAIM',
        'STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_DURING_CLEANUP',
        'STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_AFTER_RECOVERY_REPLACE'
    )
    $enabled = @($injectionNames | Where-Object {
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, 'Process'))
    })
    if ($enabled.Count -eq 0) { return }
    if ($env:STEADYAGENT_TEST_MODE -cne '1' -or
        [string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_ROOT)) {
        Stop-WithMessage 'Checkpoint test injections require STEADYAGENT_TEST_MODE=1 and STEADYAGENT_TEST_ROOT.'
    }
    $testRoot = [IO.Path]::GetFullPath($env:STEADYAGENT_TEST_ROOT)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not (Test-Path -LiteralPath $testRoot -PathType Container) -or
        -not (Test-PathWithinRoot -Path $testRoot -Root $tempRoot) -or
        (Split-Path -Leaf $testRoot) -cnotmatch '^steadyagent-git-checkpoint-[0-9a-f]{32}$') {
        Stop-WithMessage 'STEADYAGENT_TEST_ROOT must be an existing steadyagent-git-checkpoint-<32 lowercase hex> directory under the system temp directory.'
    }
    Assert-NoReparsePath -Path $testRoot
    foreach ($scopedPath in @(
        $RepositoryRoot,
        $GitCommonDirectory,
        $GitDirectory,
        $ObjectDirectory,
        $IndexPath,
        $HeadPath
    )) {
        if (-not (Test-PathWithinRoot -Path $scopedPath -Root $testRoot)) {
            Stop-WithMessage ("Checkpoint test path escaped STEADYAGENT_TEST_ROOT: " + $scopedPath)
        }
        Assert-NoReparsePath -Path $scopedPath
    }
    if ($env:STEADYAGENT_TEST_INDEX_MUTATION_PATH) {
        $mutationPath = [string]$env:STEADYAGENT_TEST_INDEX_MUTATION_PATH
        if ([IO.Path]::IsPathRooted($mutationPath) -or $mutationPath -match '(^|[\\/])[.][.]([\\/]|$)') {
            Stop-WithMessage 'Test-only index mutation path must be a contained repository-relative path.'
        }
        $mutationFull = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $mutationPath))
        if (-not (Test-PathWithinRoot -Path $mutationFull -Root $RepositoryRoot) -or
            -not (Test-PathWithinRoot -Path $mutationFull -Root $testRoot)) {
            Stop-WithMessage 'Test-only index mutation path escaped the repository fixture.'
        }
        Assert-NoReparsePath -Path $mutationFull -AllowMissingLeaf
    }
    if ($env:STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS -and
        [string]$env:STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        Stop-WithMessage 'Test-only ref mutation object id is invalid.'
    }
    if ($env:STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY) {
        $testHeadRef = [string]$env:STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY
        if (-not $testHeadRef.StartsWith('refs/heads/', [StringComparison]::Ordinal) -or
            (Invoke-GitQuiet @('check-ref-format', $testHeadRef)).Code -ne 0) {
            Stop-WithMessage 'Test-only symbolic HEAD target is invalid.'
        }
    }
    $swapValues = @(
        [string]$env:STEADYAGENT_TEST_SWAP_GIT_DIRECTORY_AFTER_PIN,
        [string]$env:STEADYAGENT_TEST_GIT_DIRECTORY_PARKED_PATH,
        [string]$env:STEADYAGENT_TEST_GIT_DIRECTORY_ESCAPE_PATH
    )
    $swapValueCount = @($swapValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($swapValueCount -ne 0 -and $swapValueCount -ne 3) {
        Stop-WithMessage 'Test-only Git directory swap requires the flag, parked path, and escape path.'
    }
    if ($swapValueCount -eq 3) {
        $parkedPath = [IO.Path]::GetFullPath($swapValues[1])
        $escapePath = [IO.Path]::GetFullPath($swapValues[2])
        foreach ($swapPath in @($parkedPath, $escapePath)) {
            if (-not (Test-PathWithinRoot -Path $swapPath -Root $testRoot)) {
                Stop-WithMessage 'Test-only Git directory swap path escaped STEADYAGENT_TEST_ROOT.'
            }
            Assert-NoReparsePath -Path $swapPath -AllowMissingLeaf
        }
        if (Test-Path -LiteralPath $parkedPath) {
            Stop-WithMessage 'Test-only Git directory parked path must be missing.'
        }
        if (-not (Test-Path -LiteralPath $escapePath -PathType Container)) {
            Stop-WithMessage 'Test-only Git directory escape path must be an existing directory.'
        }
    }
    $fanoutValue = [string]$env:STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION
    $fanoutEscapeValue = [string]$env:STEADYAGENT_TEST_OBJECT_FANOUT_ESCAPE_PATH
    if ([bool]$fanoutValue -ne [bool]$fanoutEscapeValue) {
        Stop-WithMessage 'Test-only object fanout junction requires both fanout and escape path.'
    }
    if ($fanoutValue) {
        if ($fanoutValue -cnotmatch '^[0-9a-f]{2}$') {
            Stop-WithMessage 'Test-only object fanout must be two lowercase hexadecimal characters.'
        }
        $fanoutEscapePath = [IO.Path]::GetFullPath($fanoutEscapeValue)
        if (-not (Test-PathWithinRoot -Path $fanoutEscapePath -Root $testRoot) -or
            -not (Test-Path -LiteralPath $fanoutEscapePath -PathType Container)) {
            Stop-WithMessage 'Test-only object fanout escape path must be an existing directory under STEADYAGENT_TEST_ROOT.'
        }
        Assert-NoReparsePath -Path $fanoutEscapePath
    }
}

function Set-IndexPathsFromCommit {
    param([string]$Commit, [string[]]$Paths)
    foreach ($path in $Paths) {
        $entry = @(& git ls-tree $Commit -- $path)
        if ($LASTEXITCODE -ne 0) { return $false }
        if ($entry.Count -eq 0) {
            & git update-index --force-remove -- $path
        } elseif ($entry.Count -eq 1 -and $entry[0] -match '^([0-9]{6})\s+[a-z]+\s+([0-9a-f]+)\t') {
            & git update-index --add --cacheinfo $Matches[1] $Matches[2] $path
        } else {
            return $false
        }
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    return $true
}

function Get-CheckpointCandidatePaths {
    param(
        [switch]$All,
        [string[]]$Files
    )

    $trackedArgs = @("-c", "core.quotepath=false", "diff", "--name-only", "--no-renames")
    $untrackedArgs = @("-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard")
    if (-not $All) {
        $trackedArgs += "--"
        $trackedArgs += @($Files)
        $untrackedArgs += "--"
        $untrackedArgs += @($Files)
    }

    $trackedChanges = Invoke-GitQuiet -GitArgs $trackedArgs
    $untrackedChanges = Invoke-GitQuiet -GitArgs $untrackedArgs
    if ($trackedChanges.Code -ne 0 -or $untrackedChanges.Code -ne 0) {
        Stop-WithMessage "Cannot enumerate checkpoint candidate paths."
    }

    return @(
        @($trackedChanges.Output) + @($untrackedChanges.Output) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-BlockedCheckpointPaths {
    param(
        [string]$Root,
        [string[]]$Paths
    )

    $blocked = @()
    foreach ($path in $Paths) {
        $protectedReason = Get-ProtectedPathReason -Path $path
        if ($protectedReason) {
            $blocked += "$path ($protectedReason)"
            continue
        }

        $fullPath = Join-Path $Root $path
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $item = Get-Item -LiteralPath $fullPath
            if ($item.Length -gt 25MB) {
                $blocked += ("{0} ({1:N1} MB)" -f $path, ($item.Length / 1MB))
            }
        }
    }
    return @($blocked)
}

function Stop-OnBlockedCheckpointPaths {
    param(
        [string]$Root,
        [string[]]$Paths
    )

    $blocked = @(Get-BlockedCheckpointPaths -Root $Root -Paths $Paths)
    if ($blocked.Count -gt 0) {
        Write-Host "[BLOCKED] Refusing to commit risky files:"
        $blocked | ForEach-Object { Write-Host "  $_" }
        exit 2
    }
}

function Stop-OnBlockedCheckpointIndexEntries {
    param(
        [string[]]$Paths
    )

    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        $protectedReason = Get-ProtectedPathReason -Path $path
        if ($protectedReason) {
            $blocked.Add("$path ($protectedReason)")
            continue
        }

        $entries = @(& git ls-files --stage -- $path)
        if ($LASTEXITCODE -ne 0) {
            Stop-WithMessage ("Cannot inspect the isolated index entry for: " + $path)
        }
        foreach ($entry in $entries) {
            if ($entry -notmatch '^([0-9]{6}) ([0-9a-fA-F]{40}|[0-9a-fA-F]{64}) ([0-3])\t') {
                Stop-WithMessage ("Cannot parse the isolated index entry for: " + $path)
            }
            $mode = $Matches[1]
            $objectId = $Matches[2]
            $stage = [int]$Matches[3]
            if ($stage -ne 0) {
                Stop-WithMessage ("Unmerged isolated index entry is not supported: " + $path)
            }
            if ($mode -eq "160000") {
                continue
            }

            $objectType = (& git cat-file -t $objectId).Trim()
            if ($LASTEXITCODE -ne 0 -or $objectType -ne "blob") {
                Stop-WithMessage ("Cannot validate the isolated blob for: " + $path)
            }
            $sizeText = (& git cat-file -s $objectId).Trim()
            $objectSize = 0L
            if ($LASTEXITCODE -ne 0 -or
                -not [long]::TryParse(
                    $sizeText,
                    [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$objectSize
                )) {
                Stop-WithMessage ("Cannot validate the isolated blob size for: " + $path)
            }
            if ($objectSize -gt 25MB) {
                $blocked.Add(("{0} ({1:N1} MB staged blob)" -f $path, ($objectSize / 1MB)))
            }
        }
    }

    if ($blocked.Count -gt 0) {
        Write-Host "[BLOCKED] Refusing to commit risky isolated index entries:"
        $blocked | ForEach-Object { Write-Host "  $_" }
        exit 2
    }
}

function Get-CheckpointObjectIds {
    param(
        [string]$NewCommit,
        [string]$OldHead
    )

    $objectIds = @(
        & git rev-list --objects --no-object-names $NewCommit ("^" + $OldHead) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    if ($LASTEXITCODE -ne 0 -or $objectIds.Count -eq 0) {
        Stop-WithMessage "Cannot enumerate checkpoint objects for publication."
    }
    foreach ($objectId in $objectIds) {
        if ($objectId -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
            Stop-WithMessage "Checkpoint object enumeration returned an invalid object id."
        }
    }
    if ($objectIds -notcontains $NewCommit) {
        Stop-WithMessage "Checkpoint object enumeration omitted the new commit."
    }
    return $objectIds
}

function Publish-CheckpointObjects {
    param(
        [string[]]$ObjectIds,
        [string]$QuarantineObjectDirectory,
        [string]$RealObjectDirectory
    )

    $packDirectory = Join-Path $QuarantineObjectDirectory "pack"
    $packFiles = @(
        Get-ChildItem -LiteralPath $packDirectory -File -ErrorAction SilentlyContinue
    )
    if ($packFiles.Count -gt 0) {
        Stop-WithMessage "Checkpoint quarantine contains packed objects; publication is blocked."
    }

    foreach ($objectId in $ObjectIds) {
        $fanout = $objectId.Substring(0, 2)
        $leaf = $objectId.Substring(2)
        $sourceDirectory = Join-Path $QuarantineObjectDirectory $fanout
        $sourcePath = Join-Path $sourceDirectory $leaf
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            continue
        }

        $targetDirectory = Join-Path $RealObjectDirectory $fanout
        $targetPath = Join-Path $targetDirectory $leaf
        $sourceDirectoryLease = $null
        $targetDirectoryLease = $null
        $sourceStream = $null
        $targetStream = $null
        try {
            $sourceDirectoryLease = [SteadyAgent.BoundFile]::PinDirectoryTree($sourceDirectory)
            $targetDirectoryLease = [SteadyAgent.BoundFile]::OpenOrCreatePinnedChildDirectory(
                $RealObjectDirectory,
                $fanout
            )
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                $targetStream = [SteadyAgent.BoundFile]::OpenReadDelete($targetPath)
                continue
            }
            $sourceStream = [SteadyAgent.BoundFile]::OpenReadDelete($sourcePath)
            $sourceIdentity = [SteadyAgent.BoundFile]::GetIdentity($sourceStream)
            try {
                $targetDirectoryLease.RenameHere($sourceStream, $leaf, $false)
            }
            catch {
                if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                    throw
                }
            }
            $targetStream = [SteadyAgent.BoundFile]::OpenReadShareDelete($targetPath)
            if ([SteadyAgent.BoundFile]::GetIdentity($targetStream) -cne $sourceIdentity) {
                throw "Published object identity does not match the bound quarantine object."
            }
        }
        catch {
            Stop-WithMessage (
                "Cannot publish checkpoint object through a bound normal fanout: " +
                $objectId + ". " + $_.Exception.Message
            )
        }
        finally {
            if ($targetStream) { $targetStream.Dispose() }
            if ($sourceStream) { $sourceStream.Dispose() }
            if ($targetDirectoryLease) { $targetDirectoryLease.Dispose() }
            if ($sourceDirectoryLease) { $sourceDirectoryLease.Dispose() }
        }
    }
}

function Stop-UnlessCheckpointObjectsArePublished {
    param(
        [string[]]$ObjectIds,
        [string]$NewCommit
    )

    foreach ($objectId in $ObjectIds) {
        & git cat-file -e ($objectId + "^{object}")
        if ($LASTEXITCODE -ne 0) {
            Stop-WithMessage ("Published checkpoint object is unavailable: " + $objectId)
        }
    }
    & git cat-file -e ($NewCommit + "^{commit}")
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage "Published checkpoint commit is unavailable."
    }
}

function Get-CheckpointHeadIdentity {
    $symbolicResult = Invoke-GitQuiet @("symbolic-ref", "-q", "HEAD")
    if ($symbolicResult.Code -eq 0) {
        $headRef = ([string]$symbolicResult.Output).Trim()
        if (-not $headRef -or -not $headRef.StartsWith("refs/heads/", [StringComparison]::Ordinal)) {
            throw "Cannot capture a safe symbolic HEAD identity."
        }
        $formatResult = Invoke-GitQuiet @("check-ref-format", $headRef)
        if ($formatResult.Code -ne 0) {
            throw "Cannot capture a valid symbolic HEAD identity."
        }
    }
    elseif ($symbolicResult.Code -eq 1) {
        $headRef = ""
    }
    else {
        throw "Cannot determine whether HEAD is symbolic or detached."
    }

    $headResult = Invoke-GitQuiet @("rev-parse", "--verify", "HEAD")
    $headOid = ([string]$headResult.Output).Trim()
    if ($headResult.Code -ne 0 -or $headOid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw "Cannot resolve the current HEAD."
    }
    [PSCustomObject]@{
        HeadRef = $headRef
        HeadOid = $headOid
    }
}

function Get-CheckpointTargetOid {
    param([string]$HeadRef)
    $target = if ($HeadRef) { $HeadRef } else { "HEAD" }
    $result = Invoke-GitQuiet @("rev-parse", "--verify", $target)
    $oid = ([string]$result.Output).Trim()
    if ($result.Code -ne 0 -or $oid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw ("Cannot resolve the checkpoint target ref: " + $target)
    }
    return $oid
}

function Invoke-CheckpointRefCas {
    param(
        [string]$HeadRef,
        [string]$NewCommit,
        [string]$OldHead
    )

    if ($HeadRef) {
        return Invoke-GitQuiet @(
            'update-ref',
            '-m',
            'agent checkpoint',
            $HeadRef,
            $NewCommit,
            $OldHead
        )
    }
    return Invoke-GitQuiet @(
        'update-ref',
        '--no-deref',
        '-m',
        'agent checkpoint',
        'HEAD',
        $NewCommit,
        $OldHead
    )
}

function Get-CheckpointCommitTreeOid {
    param([string]$CommitOid)

    if ($CommitOid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw "Cannot resolve a checkpoint tree from an invalid commit object id."
    }
    $result = Invoke-GitQuiet @("rev-parse", "--verify", ($CommitOid + "^{tree}"))
    $treeOid = ([string]$result.Output).Trim()
    if ($result.Code -ne 0 -or $treeOid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw ("Cannot resolve the checkpoint commit tree: " + $CommitOid)
    }
    return $treeOid
}

function Write-AtomicCheckpointJournal {
    param(
        [string]$Path,
        [object]$Journal
    )

    $temporaryPath = $Path + ".tmp-" + [guid]::NewGuid().ToString("N")
    try {
        $json = $Journal | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            throw "A checkpoint journal already exists."
        }
        [IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-SafeCheckpointQuarantine {
    param(
        [string]$Path,
        [string]$GitCommonDirectory
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $quarantineRoot = Join-Path `
        ([IO.Path]::GetFullPath($GitCommonDirectory)) `
        "steadyagent-quarantine"
    $resolved = [IO.Path]::GetFullPath($Path)
    $leaf = Split-Path -Leaf $resolved
    $resolvedParent = Split-Path -Parent $resolved
    $item = Get-Item -LiteralPath $resolved -Force
    if (-not $resolvedParent.Equals(
            [IO.Path]::GetFullPath($quarantineRoot),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $leaf.StartsWith("transaction-", [StringComparison]::Ordinal) -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Checkpoint quarantine cleanup was blocked because its path was not safe."
    }
    [SteadyAgent.BoundFile]::DeletePinnedChildDirectoryTree($quarantineRoot, $leaf)
}

function Read-CheckpointJournal {
    param(
        [string]$JournalPath,
        [string]$ExpectedIndexPath,
        [string]$ExpectedBackupPath,
        [string]$GitCommonDirectory
    )

    try {
        $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
        if ([int]$journal.schema -ne 1) { throw "Unsupported checkpoint journal schema." }
        if ([string]$journal.real_index_path -ne $ExpectedIndexPath) { throw "Checkpoint journal index path mismatch." }
        if ([string]$journal.index_backup_path -ne $ExpectedBackupPath) { throw "Checkpoint journal backup path mismatch." }
        foreach ($oid in @([string]$journal.old_head, [string]$journal.new_commit)) {
            if ($oid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
                throw "Checkpoint journal contains an invalid object id."
            }
        }
        foreach ($hash in @([string]$journal.old_index_hash, [string]$journal.publish_index_hash)) {
            if ($hash -notmatch '^[0-9a-fA-F]{64}$') {
                throw "Checkpoint journal contains an invalid index hash."
            }
        }
        if ([string]$journal.index_lock_identity -notmatch '^[0-9A-F]{8}:[0-9A-F]{16}$') {
            throw "Checkpoint journal contains an invalid index.lock identity."
        }
        $headRef = [string]$journal.head_ref
        if ($headRef) {
            if (-not $headRef.StartsWith("refs/heads/", [StringComparison]::Ordinal)) {
                throw "Checkpoint journal contains an unsafe target ref."
            }
            $formatResult = Invoke-GitQuiet @("check-ref-format", $headRef)
            if ($formatResult.Code -ne 0) {
                throw "Checkpoint journal contains an invalid target ref."
            }
        }
        $quarantinePath = [IO.Path]::GetFullPath([string]$journal.quarantine_directory)
        $quarantineBoundary = [IO.Path]::GetFullPath($GitCommonDirectory).TrimEnd("\", "/") +
            [IO.Path]::DirectorySeparatorChar + "steadyagent-quarantine" + [IO.Path]::DirectorySeparatorChar
        if (-not $quarantinePath.StartsWith($quarantineBoundary, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $quarantinePath).StartsWith("transaction-", [StringComparison]::Ordinal)) {
            throw "Checkpoint journal contains an unsafe quarantine path."
        }
        return $journal
    }
    catch {
        throw ("Cannot trust the existing checkpoint journal: " + $_.Exception.Message)
    }
}

function Restore-CheckpointIndexFromBackup {
    param(
        [object]$Journal,
        [string]$IndexLockPath
    )

    $realIndexPath = [string]$Journal.real_index_path
    $backupPath = [string]$Journal.index_backup_path
    $oldHash = [string]$Journal.old_index_hash
    $publishHash = [string]$Journal.publish_index_hash
    $currentHash = Get-FileHashHex -Path $realIndexPath
    if ($currentHash -eq $oldHash) {
        return
    }
    if ($currentHash -ne $publishHash) {
        throw "The real index has third-party changes; automatic checkpoint recovery is blocked."
    }
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
        (Get-FileHashHex -Path $backupPath) -ne $oldHash) {
        throw "The checkpoint index backup is missing or does not match the journal."
    }

    $lockStream = $null
    $candidatePath = $IndexLockPath + ".steadyagent-recovery-" +
        [guid]::NewGuid().ToString("N") + ".candidate"
    try {
        $lockStream = [SteadyAgent.BoundFile]::CreateReadWriteDelete($candidatePath)
        $backupBytes = [IO.File]::ReadAllBytes($backupPath)
        $lockStream.Write($backupBytes, 0, $backupBytes.Length)
        $lockStream.Flush($true)
        if ((Get-StreamHashHex -Stream $lockStream) -cne $oldHash) {
            throw "The prepared checkpoint recovery index does not match the journal."
        }
        [SteadyAgent.BoundFile]::Rename($lockStream, $IndexLockPath, $false)
        if ((Get-FileHashHex -Path $realIndexPath) -ne $publishHash) {
            throw "The real index changed while checkpoint recovery acquired index.lock."
        }
        [SteadyAgent.BoundFile]::Rename($lockStream, $realIndexPath, $true)
        $lockStream.Dispose()
        $lockStream = $null
        if ($env:STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_AFTER_RECOVERY_REPLACE) {
            [IO.File]::WriteAllBytes($IndexLockPath, [byte[]]@())
            Write-Host "TEST external index.lock created after recovery replace"
        }
    }
    finally {
        if ($null -ne $lockStream) {
            try { [SteadyAgent.BoundFile]::Delete($lockStream) } catch { }
            $lockStream.Dispose()
        }
    }
}

function Remove-CheckpointJournalArtifacts {
    param(
        [object]$Journal,
        [string]$JournalPath,
        [string]$GitCommonDirectory,
        [string]$IndexLockPath
    )
    if (Test-Path -LiteralPath $IndexLockPath -PathType Leaf) {
        $lockStream = $null
        $claimedPath = $IndexLockPath + ".steadyagent-cleanup-" +
            [guid]::NewGuid().ToString("N") + ".delete"
        try {
            $lockStream = [SteadyAgent.BoundFile]::OpenReadDelete($IndexLockPath)
            $lockLength = $lockStream.Length
            $lockHash = Get-StreamHashHex -Stream $lockStream
            $lockIdentity = [SteadyAgent.BoundFile]::GetIdentity($lockStream)
            if ($lockLength -eq 0 -or
                $lockHash -cne [string]$Journal.publish_index_hash) {
                throw "The existing index.lock is not owned by the checkpoint journal."
            }
            if ($lockIdentity -cne [string]$Journal.index_lock_identity) {
                throw "The existing index.lock has a different file identity from the checkpoint journal."
            }
            [SteadyAgent.BoundFile]::Rename($lockStream, $claimedPath, $false)
            if ($env:STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_DURING_CLEANUP) {
                [IO.File]::WriteAllBytes($IndexLockPath, [byte[]]@())
                Write-Host "TEST external index.lock created after cleanup claim"
            }
            [SteadyAgent.BoundFile]::Delete($lockStream)
            if (Test-Path -LiteralPath $IndexLockPath -PathType Leaf) {
                throw "A new external index.lock appeared during journal cleanup."
            }
        }
        catch {
            throw ("Cannot safely remove the journal-owned stale index.lock: " + $_.Exception.Message)
        }
        finally {
            if ($null -ne $lockStream) { $lockStream.Dispose() }
        }
    }
    Remove-SafeCheckpointQuarantine `
        -Path ([string]$Journal.quarantine_directory) `
        -GitCommonDirectory $GitCommonDirectory
    $backupPath = [string]$Journal.index_backup_path
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force
    }
    if (Test-Path -LiteralPath $JournalPath) {
        Remove-Item -LiteralPath $JournalPath -Force
    }
}

function Recover-CheckpointTransaction {
    param(
        [string]$JournalPath,
        [string]$ExpectedIndexPath,
        [string]$ExpectedBackupPath,
        [string]$IndexLockPath,
        [string]$GitCommonDirectory,
        [switch]$CasProvenNotApplied
    )

    if (-not (Test-Path -LiteralPath $JournalPath)) {
        if (Test-Path -LiteralPath $ExpectedBackupPath) {
            throw "An orphaned checkpoint index backup exists without a journal; recovery is blocked."
        }
        return $false
    }

    $journal = Read-CheckpointJournal `
        -JournalPath $JournalPath `
        -ExpectedIndexPath $ExpectedIndexPath `
        -ExpectedBackupPath $ExpectedBackupPath `
        -GitCommonDirectory $GitCommonDirectory
    $currentIndexHash = Get-FileHashHex -Path $ExpectedIndexPath
    $oldIndexHash = [string]$journal.old_index_hash
    $publishIndexHash = [string]$journal.publish_index_hash
    $indexState = if ($currentIndexHash -eq $oldIndexHash) {
        "old"
    }
    elseif ($currentIndexHash -eq $publishIndexHash) {
        "publish"
    }
    else {
        throw "The real index does not match either journaled state; recovery is blocked."
    }

    $currentIdentity = Get-CheckpointHeadIdentity
    $targetOid = Get-CheckpointTargetOid -HeadRef ([string]$journal.head_ref)
    $oldTreeOid = Get-CheckpointCommitTreeOid -CommitOid ([string]$journal.old_head)
    $currentTreeOid = Get-CheckpointCommitTreeOid -CommitOid ([string]$currentIdentity.HeadOid)

    if ($targetOid -eq [string]$journal.new_commit -and -not $CasProvenNotApplied) {
        if ([string]$currentIdentity.HeadRef -cne [string]$journal.head_ref -or
            [string]$currentIdentity.HeadOid -ne [string]$journal.new_commit -or
            $indexState -ne "publish") {
            throw "Checkpoint attachment state is ambiguous; recovery is blocked."
        }
        Remove-CheckpointJournalArtifacts `
            -Journal $journal `
            -JournalPath $JournalPath `
            -GitCommonDirectory $GitCommonDirectory `
            -IndexLockPath $IndexLockPath
        return $true
    }

    if ($indexState -eq "old") {
        if ($currentTreeOid -ne $oldTreeOid) {
            throw "The old checkpoint index does not match the active HEAD tree; recovery is blocked."
        }
        Remove-CheckpointJournalArtifacts `
            -Journal $journal `
            -JournalPath $JournalPath `
            -GitCommonDirectory $GitCommonDirectory `
            -IndexLockPath $IndexLockPath
        return $true
    }

    $newTreeOid = Get-CheckpointCommitTreeOid -CommitOid ([string]$journal.new_commit)
    if ($currentTreeOid -eq $newTreeOid) {
        Remove-CheckpointJournalArtifacts `
            -Journal $journal `
            -JournalPath $JournalPath `
            -GitCommonDirectory $GitCommonDirectory `
            -IndexLockPath $IndexLockPath
        return $true
    }

    if ($currentTreeOid -ne $oldTreeOid) {
        throw "The active HEAD tree matches neither journaled checkpoint tree; automatic recovery is blocked."
    }

    Restore-CheckpointIndexFromBackup -Journal $journal -IndexLockPath $IndexLockPath
    Remove-CheckpointJournalArtifacts `
        -Journal $journal `
        -JournalPath $JournalPath `
        -GitCommonDirectory $GitCommonDirectory `
        -IndexLockPath $IndexLockPath
    return $true
}

$problemTag = ([string][char]0x3010) + ([string][char]0x95EE) + ([string][char]0x9898) + ([string][char]0x63CF) + ([string][char]0x8FF0) + ([string][char]0x3011)
$reproTag = ([string][char]0x3010) + ([string][char]0x590D) + ([string][char]0x73B0) + ([string][char]0x8DEF) + ([string][char]0x5F84) + ([string][char]0x3011)
$fixTag = ([string][char]0x3010) + ([string][char]0x4FEE) + ([string][char]0x590D) + ([string][char]0x601D) + ([string][char]0x8DEF) + ([string][char]0x3011)
$requiredTags = @($problemTag, $reproTag, $fixTag)

$hasRequiredTag = $false
foreach ($tag in $requiredTags) {
    if ($Message.Contains($tag)) {
        $hasRequiredTag = $true
        break
    }
}

if (-not $hasRequiredTag) {
    $Message = $problemTag + " " + $Message
}

if ($RemainingFiles -and $RemainingFiles.Count -gt 0) {
    if (-not $Files) {
        $Files = @()
    }
    $Files += $RemainingFiles
}

if ($All -and $Files -and $Files.Count -gt 0) {
    Stop-WithMessage "Use either -All or -Files, not both."
}

$rootResult = Invoke-GitQuiet @("rev-parse", "--show-toplevel")
$root = $rootResult.Output
if ($rootResult.Code -ne 0 -or -not $root) {
    Stop-WithMessage "Current directory is not inside a Git repository."
}
$root = [IO.Path]::GetFullPath(([string]$root).Trim())
if ($env:GIT_INDEX_FILE) {
    Stop-WithMessage "Refusing to run with a caller-supplied GIT_INDEX_FILE."
}
if ($env:GIT_OBJECT_DIRECTORY) {
    Stop-WithMessage "Refusing to run with a caller-supplied GIT_OBJECT_DIRECTORY."
}
if ($env:GIT_ALTERNATE_OBJECT_DIRECTORIES) {
    Stop-WithMessage "Refusing to run with caller-supplied GIT_ALTERNATE_OBJECT_DIRECTORIES."
}

$gitCommonResult = Invoke-GitQuiet @("rev-parse", "--path-format=absolute", "--git-common-dir")
$gitCommonDirectory = [string]$gitCommonResult.Output
if ($gitCommonResult.Code -ne 0 -or -not $gitCommonDirectory) {
    Stop-WithMessage "Cannot resolve the repository common Git directory."
}
$gitCommonDirectory = [IO.Path]::GetFullPath($gitCommonDirectory.Trim())

$objectDirectoryResult = Invoke-GitQuiet @("rev-parse", "--path-format=absolute", "--git-path", "objects")
$realObjectDirectory = [string]$objectDirectoryResult.Output
if ($objectDirectoryResult.Code -ne 0 -or -not $realObjectDirectory) {
    Stop-WithMessage "Cannot resolve the repository object directory."
}
$realObjectDirectory = [IO.Path]::GetFullPath($realObjectDirectory.Trim())
if (-not (Test-Path -LiteralPath $realObjectDirectory -PathType Container)) {
    Stop-WithMessage "The repository object directory does not exist."
}
if ($realObjectDirectory.IndexOf([IO.Path]::PathSeparator) -ge 0) {
    Stop-WithMessage "The repository object directory cannot be represented safely as a Git alternate."
}

$gitDirectoryResult = Invoke-GitQuiet @("rev-parse", "--path-format=absolute", "--git-dir")
$gitDirectory = [string]$gitDirectoryResult.Output
if ($gitDirectoryResult.Code -ne 0 -or -not $gitDirectory) {
    Stop-WithMessage "Cannot resolve the worktree Git directory."
}
$gitDirectory = [IO.Path]::GetFullPath($gitDirectory.Trim())
if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
    Stop-WithMessage "The worktree Git directory does not exist."
}

$realIndexResult = Invoke-GitQuiet @("rev-parse", "--path-format=absolute", "--git-path", "index")
$resolvedRealIndexPath = [string]$realIndexResult.Output
if ($realIndexResult.Code -ne 0 -or -not $resolvedRealIndexPath) {
    Stop-WithMessage "Cannot resolve the repository index path."
}
$resolvedRealIndexPath = [IO.Path]::GetFullPath($resolvedRealIndexPath.Trim())
$headPathResult = Invoke-GitQuiet @('rev-parse', '--path-format=absolute', '--git-path', 'HEAD')
$resolvedHeadPath = [string]$headPathResult.Output
if ($headPathResult.Code -ne 0 -or -not $resolvedHeadPath) {
    Stop-WithMessage 'Cannot resolve the worktree HEAD path.'
}
$resolvedHeadPath = [IO.Path]::GetFullPath($resolvedHeadPath.Trim())
Assert-CheckpointTestInjectionIsolation `
    -RepositoryRoot $root `
    -GitCommonDirectory $gitCommonDirectory `
    -GitDirectory $gitDirectory `
    -ObjectDirectory $realObjectDirectory `
    -IndexPath $resolvedRealIndexPath `
    -HeadPath $resolvedHeadPath
$journalPath = Join-Path $gitDirectory "steadyagent-checkpoint-journal.json"
$journalBackupPath = Join-Path $gitDirectory "steadyagent-checkpoint-index.backup"
$resolvedIndexLockPath = $resolvedRealIndexPath + ".lock"

$injectIndexPublicationFailure = $false
if ($env:STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE) {
    $injectIndexPublicationFailure = $true
}

$checkpointMutex = $null
$checkpointLockTaken = $false
$tempIndex = $null
$publishIndex = $null
$messageFile = $null
$realIndexPath = $null
$realIndexHash = $null
$realIndexIdentity = $null
$realIndexStream = $null
$indexLockPath = $null
$indexBackupPath = $null
$indexLockStream = $null
$headIdentityStream = $null
$indexLockOwned = $false
$journalCreated = $false
$casProvenNotApplied = $false
$quarantineRoot = $null
$quarantineDirectory = $null
$quarantineObjectDirectory = $null
$checkpointObjectIds = @()
$gitDirectoryLeases = @()
$candidateFileBindings = @()
Push-Location $root
try {
    $criticalDirectories = @(
        $gitCommonDirectory,
        $gitDirectory,
        $realObjectDirectory,
        (Split-Path -Parent $resolvedRealIndexPath),
        (Split-Path -Parent $resolvedHeadPath)
    ) | Sort-Object -Unique
    foreach ($criticalDirectory in $criticalDirectories) {
        $gitDirectoryLeases += [SteadyAgent.BoundFile]::PinDirectoryTree($criticalDirectory)
    }
    if ($env:STEADYAGENT_TEST_SWAP_GIT_DIRECTORY_AFTER_PIN) {
        $swapBlocked = $false
        try {
            [IO.Directory]::Move(
                $gitDirectory,
                [string]$env:STEADYAGENT_TEST_GIT_DIRECTORY_PARKED_PATH
            )
            New-Item `
                -ItemType Junction `
                -Path $gitDirectory `
                -Target ([string]$env:STEADYAGENT_TEST_GIT_DIRECTORY_ESCAPE_PATH) | Out-Null
        }
        catch {
            $swapBlocked = $true
        }
        if (-not $swapBlocked) {
            Stop-WithMessage 'The bound Git directory allowed a competing junction substitution.'
        }
        Write-Host 'TEST Git directory swap blocked after path pin'
    }
    $lockHash = Get-TextHash -Text ($gitCommonDirectory.ToLowerInvariant())
    $checkpointMutex = New-Object Threading.Mutex($false, ("Local\CodexCheckpoint_" + $lockHash))
    try { $checkpointLockTaken = $checkpointMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $checkpointLockTaken = $true }
    if (-not $checkpointLockTaken) {
        Stop-WithMessage "Another checkpoint transaction already holds the repository lock."
    }

    $pendingRecoveryArtifacts = @(
        @(
            $journalPath,
            $journalBackupPath,
            $resolvedIndexLockPath
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($DryRun -and $pendingRecoveryArtifacts.Count -gt 0) {
        Stop-WithMessage (
            "A pending checkpoint transaction requires a non-dry-run recovery; " +
            "dry-run made zero writes."
        )
    }
    try {
        $recoveredTransaction = Recover-CheckpointTransaction `
            -JournalPath $journalPath `
            -ExpectedIndexPath $resolvedRealIndexPath `
            -ExpectedBackupPath $journalBackupPath `
            -IndexLockPath $resolvedIndexLockPath `
            -GitCommonDirectory $gitCommonDirectory
    }
    catch {
        Stop-WithMessage ("Checkpoint recovery failed closed: " + $_.Exception.Message)
    }
    if ($recoveredTransaction) {
        Write-Host "[RECOVERED] Restored or finalized an interrupted checkpoint transaction."
    }

    $status = (& git status --porcelain)
    if (-not $status) {
        Write-Host "[OK] No changes to commit."
        exit 0
    }

    $preExistingStaged = @(& git -c core.quotepath=false diff --cached --name-only --ita-visible-in-index)
    $unmerged = @(& git diff --name-only --diff-filter=U)
    if ($preExistingStaged.Count -gt 0 -or $unmerged.Count -gt 0) {
        Write-Host "[BLOCKED] Existing staged changes belong to the caller and will not be committed or unstaged:"
        $preExistingStaged | ForEach-Object { Write-Host "  $_" }
        $unmerged | ForEach-Object { Write-Host ("  unresolved: " + $_) }
        Stop-WithMessage "Resolve or clear the existing index explicitly before creating a checkpoint."
    }

    if ($Files -and $Files.Count -gt 0) {
        $validatedFiles = New-Object System.Collections.Generic.List[string]
        $rootBoundary = [IO.Path]::GetFullPath($root).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
        foreach ($path in $Files) {
            if (-not $path -or $path -eq "." -or [IO.Path]::IsPathRooted($path) -or $path.IndexOfAny(@([char]'*', [char]'?', [char]'[')) -ge 0) {
                Stop-WithMessage ("Refusing non-literal or non-relative scope in -Files: " + $path)
            }
            $fullPath = [IO.Path]::GetFullPath((Join-Path $root $path))
            if (-not $fullPath.StartsWith($rootBoundary, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-WithMessage ("Refusing repository-external path in -Files: " + $path)
            }
            if (Test-Path -LiteralPath $path -PathType Container) {
                Stop-WithMessage ("Refusing directory scope in -Files: " + $path)
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $trackedResult = Invoke-GitQuiet @("ls-files", "--error-unmatch", "--", $path)
                if ($trackedResult.Code -ne 0) {
                    Stop-WithMessage ("Explicit file does not exist and is not a tracked deletion: " + $path)
                }
            }
            $relativePath = $fullPath.Substring($rootBoundary.Length) -replace "\\", "/"
            if (-not $validatedFiles.Contains($relativePath)) { $validatedFiles.Add($relativePath) }
        }
        $Files = @($validatedFiles)
    }
    elseif (-not $All) {
        Write-Host "[INFO] Changed files:"
        & git status --short
        Stop-WithMessage "Refusing to commit without explicit -Files or user-approved -All."
    }

    if ($All) {
        Write-Host "[INFO] Staging all changes because -All was provided."
    }
    else {
        Write-Host "[INFO] Staging explicit files:"
        $Files | ForEach-Object { Write-Host "  $_" }
    }

    $candidatePaths = @(Get-CheckpointCandidatePaths -All:$All -Files $Files)
    if (-not $candidatePaths) {
        Write-Host "[OK] No staged changes."
        exit 0
    }

    Stop-OnBlockedCheckpointPaths -Root $root -Paths $candidatePaths

    foreach ($candidatePath in $candidatePaths) {
        $workingPath = Join-Path $root ($candidatePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $workingPath -PathType Leaf)) { continue }

        $candidateStream = $null
        try {
            $candidateStream = [SteadyAgent.BoundFile]::OpenReadDelete($workingPath)
            if ([SteadyAgent.BoundFile]::GetLinkCount($candidateStream) -ne 1) {
                throw "The checkpoint candidate has multiple hard links: $candidatePath"
            }
            $candidateFileBindings += [PSCustomObject]@{
                Path = [string]$candidatePath
                Stream = $candidateStream
            }
            $candidateStream = $null
        }
        catch {
            if ($null -ne $candidateStream) { $candidateStream.Dispose() }
            Stop-WithMessage ("Cannot safely bind checkpoint candidate '{0}': {1}" -f $candidatePath, $_.Exception.Message)
        }
    }

    if (-not $DryRun) {
        try {
            $capturedHeadIdentity = Get-CheckpointHeadIdentity
        }
        catch {
            Stop-WithMessage $_.Exception.Message
        }
        $oldHead = [string]$capturedHeadIdentity.HeadOid
        $headRef = [string]$capturedHeadIdentity.HeadRef
        $realIndexPath = $resolvedRealIndexPath
        if (-not (Test-Path -LiteralPath $realIndexPath -PathType Leaf)) {
            Stop-WithMessage "Cannot bind checkpoint publication because the real index does not exist."
        }
        if ($env:STEADYAGENT_TEST_INDEX_MUTATION_PATH) {
            $env:GIT_INDEX_FILE = $realIndexPath
            & git add -- $env:STEADYAGENT_TEST_INDEX_MUTATION_PATH
            if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Test-only index mutation failed." }
        }
        try {
            $realIndexStream = [SteadyAgent.BoundFile]::OpenReadDelete($realIndexPath)
            $realIndexIdentity = [SteadyAgent.BoundFile]::GetIdentity($realIndexStream)
            $realIndexHash = Get-StreamHashHex -Stream $realIndexStream
        }
        catch {
            Stop-WithMessage ("Cannot bind the real checkpoint index snapshot: " + $_.Exception.Message)
        }

        $quarantineRoot = Join-Path $gitCommonDirectory "steadyagent-quarantine"
        if (Test-Path -LiteralPath $quarantineRoot) {
            $quarantineRootItem = Get-Item -LiteralPath $quarantineRoot -Force
            if (-not $quarantineRootItem.PSIsContainer -or
                (($quarantineRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                Stop-WithMessage "The checkpoint quarantine root is not a safe directory."
            }
        }
        else {
            New-Item -ItemType Directory -Path $quarantineRoot | Out-Null
        }

        $quarantineDirectory = Join-Path $quarantineRoot ("transaction-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $quarantineDirectory | Out-Null
        $quarantineDirectoryItem = Get-Item -LiteralPath $quarantineDirectory -Force
        if (($quarantineDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-WithMessage "The checkpoint quarantine transaction is not a safe directory."
        }
        $quarantineObjectDirectory = Join-Path $quarantineDirectory "objects"
        New-Item -ItemType Directory -Path $quarantineObjectDirectory | Out-Null

        $tempIndex = Join-Path $quarantineDirectory "checkpoint.index"
        $env:GIT_INDEX_FILE = $tempIndex
        $env:GIT_OBJECT_DIRECTORY = $quarantineObjectDirectory
        $env:GIT_ALTERNATE_OBJECT_DIRECTORIES = $realObjectDirectory
        & git read-tree $oldHead
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Cannot initialize the isolated checkpoint index." }

        & git add -A -- @candidatePaths
        if ($LASTEXITCODE -ne 0) {
            Stop-WithMessage "git add failed in the isolated checkpoint index."
        }

        foreach ($binding in $candidateFileBindings) {
            if ([SteadyAgent.BoundFile]::GetLinkCount($binding.Stream) -ne 1) {
                Stop-WithMessage ("Checkpoint candidate gained another hard link while staging: " + $binding.Path)
            }

            $expectedBlob = [string](& git hash-object ("--path=" + $binding.Path) -- $binding.Path)
            if ($LASTEXITCODE -ne 0 -or -not $expectedBlob) {
                Stop-WithMessage ("Cannot hash the bound checkpoint candidate: " + $binding.Path)
            }
            $expectedBlob = $expectedBlob.Trim()

            $stagedEntry = [string](& git -c core.quotepath=false ls-files --stage -- $binding.Path)
            if ($LASTEXITCODE -ne 0 -or $stagedEntry -notmatch '^\d+\s+([0-9a-f]+)\s+0\t') {
                Stop-WithMessage ("Cannot bind the staged checkpoint blob: " + $binding.Path)
            }
            if ($Matches[1] -cne $expectedBlob) {
                Stop-WithMessage ("The staged checkpoint blob does not match its bound working-tree candidate: " + $binding.Path)
            }
        }

        foreach ($binding in $candidateFileBindings) { $binding.Stream.Dispose() }
        $candidateFileBindings = @()
    }

    if ($DryRun) {
        $staged = @($candidatePaths)
    }
    else {
        $staged = @(& git -c core.quotepath=false diff --cached --name-only --no-renames)
    }
    if (-not $staged) {
        Write-Host "[OK] No staged changes."
        exit 0
    }

    if (-not $DryRun) {
        $unexpectedStaged = @($staged | Where-Object { $candidatePaths -notcontains $_ })
        if ($unexpectedStaged.Count -gt 0) {
            [Console]::Error.WriteLine("git add changed the checkpoint path scope; refusing to create a commit.")
            exit 2
        }
    }

    if ($DryRun) {
        Stop-OnBlockedCheckpointPaths -Root $root -Paths $staged
    }
    else {
        Stop-OnBlockedCheckpointIndexEntries -Paths $staged
    }

    Write-Host "[INFO] Staged files:"
    $staged | ForEach-Object { Write-Host "  $_" }

    $stagedArr = @($staged)
    $highRisk = @($stagedArr | Where-Object { $_ -match "(?i)(auth|login|payment|migrat|secret|crypto|password|\.env|permission|deploy|release)" })
    if ($highRisk.Count -gt 0) {
        Write-Host ""
        Write-Host "[REVIEW?] High-risk path detected -- confirm review-gates.md was satisfied before committing."
        Write-Host ""
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] Commit skipped."
        exit 0
    }

    $expectedPaths = @($stagedArr | Sort-Object -Unique)
    & git hook run --ignore-missing pre-commit
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $postHookPaths = @(& git -c core.quotepath=false diff --cached --name-only --no-renames | Sort-Object -Unique)
    $scopeDrift = @(Compare-Object -ReferenceObject $expectedPaths -DifferenceObject $postHookPaths)
    if ($scopeDrift.Count -gt 0) {
        [Console]::Error.WriteLine("Pre-commit changed the checkpoint path scope; refusing to create a commit.")
        exit 2
    }
    Stop-OnBlockedCheckpointIndexEntries -Paths $postHookPaths

    $tree = (& git write-tree).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $tree) { Stop-WithMessage "Cannot write the isolated checkpoint tree." }
    $messageFile = Join-Path ([IO.Path]::GetTempPath()) ("agent-checkpoint-message-" + [guid]::NewGuid().ToString("N") + ".txt")
    [IO.File]::WriteAllText($messageFile, $Message, (New-Object Text.UTF8Encoding($false)))
    $newCommit = (& git commit-tree $tree -p $oldHead -F $messageFile).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $newCommit) { Stop-WithMessage "Cannot create the checkpoint commit object." }

    $publishIndex = Join-Path $quarantineDirectory "publish.index"
    if ($env:STEADYAGENT_TEST_INDEX_ABA_PATH) {
        $env:GIT_INDEX_FILE = $realIndexPath
        & git update-index --force-remove -- $env:STEADYAGENT_TEST_INDEX_ABA_PATH
        if ($LASTEXITCODE -ne 0) {
            Write-Host "TEST real-index ABA stage blocked"
        }
        else {
            Write-Host "TEST real-index ABA stage-copy-unstage seam reached"
            & git reset -- $env:STEADYAGENT_TEST_INDEX_ABA_PATH
            if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Test-only real-index ABA unstage failed." }
        }
    }
    Copy-BoundStreamToNewFile -Stream $realIndexStream -DestinationPath $publishIndex
    $env:GIT_INDEX_FILE = $publishIndex
    if (-not (Set-IndexPathsFromCommit -Commit $newCommit -Paths $expectedPaths)) {
        Stop-WithMessage "Cannot construct the complete checkpoint index for publication."
    }

    $checkpointObjectIds = @(Get-CheckpointObjectIds -NewCommit $newCommit -OldHead $oldHead)
    $publishIndexHash = Get-FileHashHex -Path $publishIndex
    if (-not $publishIndexHash) {
        Stop-WithMessage "Cannot hash the complete checkpoint index."
    }
    Remove-Item Env:GIT_OBJECT_DIRECTORY -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_ALTERNATE_OBJECT_DIRECTORIES -ErrorAction SilentlyContinue
    $env:GIT_INDEX_FILE = $realIndexPath

    $indexLockPath = $resolvedIndexLockPath
    $indexBackupPath = $journalBackupPath
    try {
        $indexLockStream = [SteadyAgent.BoundFile]::OpenReadDelete($publishIndex)
        if ((Get-StreamHashHex -Stream $indexLockStream) -cne $publishIndexHash) {
            throw "The prepared checkpoint index changed before lock publication."
        }
        if (-not [string]::Equals(
            [IO.Path]::GetPathRoot($publishIndex),
            [IO.Path]::GetPathRoot($indexLockPath),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "The prepared checkpoint index is not on the index filesystem."
        }
        $indexLockIdentity = [SteadyAgent.BoundFile]::GetIdentity($indexLockStream)
    }
    catch {
        Stop-WithMessage ("Cannot bind the prepared checkpoint index identity: " + $_.Exception.Message)
    }

    $journal = [PSCustomObject][ordered]@{
        schema = 1
        real_index_path = $realIndexPath
        index_backup_path = $indexBackupPath
        old_index_hash = $realIndexHash
        publish_index_hash = $publishIndexHash
        index_lock_identity = $indexLockIdentity
        head_ref = $headRef
        old_head = $oldHead
        new_commit = $newCommit
        quarantine_directory = $quarantineDirectory
    }
    try {
        Write-AtomicCheckpointJournal -Path $journalPath -Journal $journal
        $journalCreated = $true
    }
    catch {
        Stop-WithMessage ("Cannot create the atomic checkpoint journal: " + $_.Exception.Message)
    }

    try {
        [SteadyAgent.BoundFile]::Rename($indexLockStream, $indexLockPath, $false)
        $indexLockOwned = $true
        if ($env:STEADYAGENT_TEST_REWRITE_INDEX_LOCK_AFTER_CLAIM) {
            $rewriteBlocked = $false
            try {
                $rewriteStream = [IO.File]::Open(
                    $indexLockPath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite
                )
                try {
                    $rewriteStream.SetLength(0)
                    $rewriteStream.WriteByte(0)
                    $rewriteStream.Flush($true)
                }
                finally { $rewriteStream.Dispose() }
            }
            catch [IO.IOException] {
                $rewriteBlocked = $true
            }
            if (-not $rewriteBlocked) {
                throw "Test-only competing index.lock rewrite was not blocked."
            }
            Write-Host "TEST index.lock competing rewrite blocked"
        }
    }
    catch {
        Stop-WithMessage ("The Git index is busy or atomic lock publication failed; checkpoint publication was not attempted. " + $_.Exception.Message)
    }
    if ($env:STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE) {
        [Environment]::Exit(83)
    }

    $currentIndexHash = Get-StreamHashHex -Stream $realIndexStream
    $currentIndexIdentity = [SteadyAgent.BoundFile]::GetIdentity($realIndexStream)
    try {
        $currentIdentity = Get-CheckpointHeadIdentity
        $currentTargetOid = Get-CheckpointTargetOid -HeadRef $headRef
    }
    catch {
        Stop-WithMessage $_.Exception.Message
    }
    $foreignStaged = @(& git -c core.quotepath=false diff --cached --name-only --ita-visible-in-index)
    $foreignUnmerged = @(& git diff --name-only --diff-filter=U)
    if ($currentIndexHash -ne $realIndexHash -or
        $currentIndexIdentity -cne $realIndexIdentity -or
        [string]$currentIdentity.HeadRef -ne $headRef -or
        [string]$currentIdentity.HeadOid -ne $oldHead -or
        $currentTargetOid -ne $oldHead -or
        $foreignStaged.Count -gt 0 -or $foreignUnmerged.Count -gt 0) {
        [Console]::Error.WriteLine("Repository HEAD identity, target ref, or real index changed during the checkpoint transaction; commit was not attached.")
        exit 2
    }

    if ($env:STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_WRITE) {
        [Environment]::Exit(84)
    }

    try {
        Copy-BoundStreamToNewFile -Stream $realIndexStream -DestinationPath $indexBackupPath
    }
    catch {
        Stop-WithMessage "Cannot create the journaled old-index backup."
    }
    if ((Get-FileHashHex -Path $indexBackupPath) -ne $realIndexHash) {
        Stop-WithMessage "The journaled old-index backup does not match the captured index."
    }
    $realIndexStream.Dispose()
    $realIndexStream = $null
    if ($env:STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_BACKUP) {
        [Environment]::Exit(85)
    }

    if ($env:STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION) {
        $injectedFanoutPath = Join-Path `
            $realObjectDirectory `
            ([string]$env:STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION)
        if (Test-Path -LiteralPath $injectedFanoutPath) {
            Stop-WithMessage 'Test-only object fanout path must be absent before junction injection.'
        }
        New-Item `
            -ItemType Junction `
            -Path $injectedFanoutPath `
            -Target ([string]$env:STEADYAGENT_TEST_OBJECT_FANOUT_ESCAPE_PATH) | Out-Null
        Write-Host 'TEST object fanout junction injected before publication'
    }
    Publish-CheckpointObjects `
        -ObjectIds $checkpointObjectIds `
        -QuarantineObjectDirectory $quarantineObjectDirectory `
        -RealObjectDirectory $realObjectDirectory
    Stop-UnlessCheckpointObjectsArePublished -ObjectIds $checkpointObjectIds -NewCommit $newCommit

    if ($injectIndexPublicationFailure) {
        [Console]::Error.WriteLine("Checkpoint index publication failed before the real index was replaced.")
        exit 3
    }
    try {
        [SteadyAgent.BoundFile]::Rename($indexLockStream, $realIndexPath, $true)
        $indexLockOwned = $false
        $indexLockStream.Dispose()
        $indexLockStream = $null
    }
    catch {
        [Console]::Error.WriteLine("Checkpoint index publication failed before the target ref CAS: " + $_.Exception.Message)
        exit 3
    }

    if ($env:STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION) {
        [Environment]::Exit(86)
    }

    $targetRef = if ($headRef) { $headRef } else { "HEAD" }
    if ($env:STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS) {
        $mutationOid = [string]$env:STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS
        if ($mutationOid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
            Stop-WithMessage "Test-only ref mutation object id is invalid."
        }
        & git update-ref -m "checkpoint ref race fixture" $targetRef $mutationOid $oldHead
        if ($LASTEXITCODE -ne 0) {
            Stop-WithMessage "Test-only ref mutation failed."
        }
    }

    try {
        if ($headRef) {
            $headIdentityStream = [SteadyAgent.BoundFile]::OpenReadDelete($resolvedHeadPath)
            $expectedHeadText = 'ref: ' + $headRef + "`n"
            if ((Get-StreamUtf8Text -Stream $headIdentityStream) -cne $expectedHeadText) {
                throw 'Symbolic HEAD bytes changed before checkpoint CAS.'
            }
        }
        $preCasIdentity = Get-CheckpointHeadIdentity
        $preCasTargetOid = Get-CheckpointTargetOid -HeadRef $headRef
    }
    catch {
        $casProvenNotApplied = $true
        Stop-WithMessage $_.Exception.Message
    }
    if ([string]$preCasIdentity.HeadRef -ne $headRef -or
        [string]$preCasIdentity.HeadOid -ne $oldHead -or
        $preCasTargetOid -ne $oldHead) {
        $casProvenNotApplied = $true
        try {
            Recover-CheckpointTransaction `
                -JournalPath $journalPath `
                -ExpectedIndexPath $realIndexPath `
                -ExpectedBackupPath $indexBackupPath `
                -IndexLockPath $indexLockPath `
                -GitCommonDirectory $gitCommonDirectory `
                -CasProvenNotApplied | Out-Null
            $journalCreated = $false
        }
        catch {
            Stop-WithMessage ("Checkpoint pre-CAS recovery failed closed: " + $_.Exception.Message)
        }
        Stop-WithMessage "HEAD identity or target ref changed before checkpoint CAS; commit was not attached."
    }

    if ($env:STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY) {
        $testSwitch = Invoke-GitQuiet @(
            'symbolic-ref',
            'HEAD',
            ([string]$env:STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY)
        )
        if ($testSwitch.Code -eq 0) {
            $casProvenNotApplied = $true
            Stop-WithMessage 'The bound symbolic HEAD identity allowed a competing switch.'
        }
        Write-Host 'TEST symbolic HEAD switch blocked after identity bind'
    }

    $refCasResult = Invoke-CheckpointRefCas `
        -HeadRef $headRef `
        -NewCommit $newCommit `
        -OldHead $oldHead
    if ($null -ne $headIdentityStream) {
        $headIdentityStream.Dispose()
        $headIdentityStream = $null
    }
    if ($refCasResult.Code -ne 0) {
        $casProvenNotApplied = $true
        try {
            Recover-CheckpointTransaction `
                -JournalPath $journalPath `
                -ExpectedIndexPath $realIndexPath `
                -ExpectedBackupPath $indexBackupPath `
                -IndexLockPath $indexLockPath `
                -GitCommonDirectory $gitCommonDirectory `
                -CasProvenNotApplied | Out-Null
            $journalCreated = $false
        }
        catch {
            Stop-WithMessage ("Checkpoint CAS recovery failed closed: " + $_.Exception.Message)
        }
        Stop-WithMessage "Target ref changed before checkpoint publication; commit was not attached."
    }

    try {
        Recover-CheckpointTransaction `
            -JournalPath $journalPath `
            -ExpectedIndexPath $realIndexPath `
            -ExpectedBackupPath $indexBackupPath `
            -IndexLockPath $indexLockPath `
            -GitCommonDirectory $gitCommonDirectory | Out-Null
        $journalCreated = $false
    }
    catch {
        Stop-WithMessage ("Checkpoint attachment succeeded, but journal finalization failed closed: " + $_.Exception.Message)
    }
    $indexBackupPath = $null

    Write-Host "[OK] Checkpoint commit created."

    Write-Host ""
    Write-Host "[REFLECT?] Record only recurring, generalizable pitfalls in the project's maintained lessons file."
}
finally {
    if ($env:GIT_INDEX_FILE) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    if ($env:GIT_OBJECT_DIRECTORY) { Remove-Item Env:GIT_OBJECT_DIRECTORY -ErrorAction SilentlyContinue }
    if ($env:GIT_ALTERNATE_OBJECT_DIRECTORIES) { Remove-Item Env:GIT_ALTERNATE_OBJECT_DIRECTORIES -ErrorAction SilentlyContinue }
    if ($null -ne $indexLockStream) { $indexLockStream.Dispose() }
    if ($null -ne $realIndexStream) { $realIndexStream.Dispose() }
    if ($null -ne $headIdentityStream) { $headIdentityStream.Dispose() }
    foreach ($binding in $candidateFileBindings) {
        if ($null -ne $binding.Stream) { $binding.Stream.Dispose() }
    }
    if ($journalCreated -and (Test-Path -LiteralPath $journalPath)) {
        try {
            Recover-CheckpointTransaction `
                -JournalPath $journalPath `
                -ExpectedIndexPath $resolvedRealIndexPath `
                -ExpectedBackupPath $journalBackupPath `
                -IndexLockPath $resolvedIndexLockPath `
                -GitCommonDirectory $gitCommonDirectory `
                -CasProvenNotApplied:$casProvenNotApplied | Out-Null
            $journalCreated = $false
        }
        catch {
            [Console]::Error.WriteLine("Checkpoint journal recovery remains pending: " + $_.Exception.Message)
        }
    }
    if ($tempIndex -and (Test-Path -LiteralPath $tempIndex)) { Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue }
    if ($publishIndex -and (Test-Path -LiteralPath $publishIndex)) { Remove-Item -LiteralPath $publishIndex -Force -ErrorAction SilentlyContinue }
    if ($messageFile -and (Test-Path -LiteralPath $messageFile)) { Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path -LiteralPath $journalPath) -and
        $indexBackupPath -and (Test-Path -LiteralPath $indexBackupPath)) {
        Remove-Item -LiteralPath $indexBackupPath -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $journalPath) -and
        $quarantineDirectory -and (Test-Path -LiteralPath $quarantineDirectory)) {
        try {
            Remove-SafeCheckpointQuarantine `
                -Path $quarantineDirectory `
                -GitCommonDirectory $gitCommonDirectory
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
    if ($quarantineRoot -and (Test-Path -LiteralPath $quarantineRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $quarantineRoot -Force -ErrorAction SilentlyContinue
    }
    if ($checkpointLockTaken -and $null -ne $checkpointMutex) { $checkpointMutex.ReleaseMutex() }
    if ($null -ne $checkpointMutex) { $checkpointMutex.Dispose() }
    for ($leaseIndex = $gitDirectoryLeases.Count - 1; $leaseIndex -ge 0; $leaseIndex--) {
        $gitDirectoryLeases[$leaseIndex].Dispose()
    }
    Pop-Location
}
