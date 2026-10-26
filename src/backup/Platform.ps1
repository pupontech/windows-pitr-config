# Platform safety module: profile discovery, source scoping, path/volume/identity validation.
# Functions and types only. No top-level work beyond the guarded type definition.
# Target Windows PowerShell 5.1 and PowerShell 7. Enforces Windows naming rules on every host.

if (-not ('Pitr.WindowsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Pitr {
    public static class WindowsNative {
        private const uint FILE_SHARE_ALL = 0x00000007;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint VOLUME_NAME_DOS = 0x0;
        private const uint VOLUME_NAME_NT = 0x2;

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
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
        private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(IntPtr hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeInformationByHandleW(IntPtr hFile, StringBuilder lpVolumeNameBuffer,
            uint nVolumeNameSize, out uint lpVolumeSerialNumber, out uint lpMaximumComponentLength,
            out uint lpFileSystemFlags, StringBuilder lpFileSystemNameBuffer, uint nFileSystemNameSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumePathNameW(string lpszFileName, StringBuilder lpszVolumePathName, uint cchBufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetVolumeNameForVolumeMountPointW(string lpszVolumeMountPoint, StringBuilder lpszVolumeName, uint cchBufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstVolumeW(StringBuilder lpszVolumeName, uint cchBufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindNextVolumeW(IntPtr hFindVolume, StringBuilder lpszVolumeName, uint cchBufferLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindVolumeClose(IntPtr hFindVolume);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumePathNamesForVolumeNameW(string lpszVolumeName, char[] lpszVolumePathNames,
            uint cchBufferLength, out uint lpcchReturnLength);

        private static IntPtr OpenForQuery(string path, bool finalPathSemantics) {
            uint flags = FILE_FLAG_BACKUP_SEMANTICS;
            if (!finalPathSemantics) { flags |= FILE_FLAG_OPEN_REPARSE_POINT; }
            return CreateFileW(path, 0, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        }

        // Stable identity of the volume that actually holds the path: volume GUID path plus serial.
        // The handle is opened without FILE_FLAG_OPEN_REPARSE_POINT so a junction, symlink or mount
        // point resolves to its target, which is the physical location the files will really use.
        public static string QueryIdentity(string path) {
            IntPtr handle = IntPtr.Zero;
            try {
                handle = OpenForQuery(path, true);
                if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return null; }
                uint serial = 0;
                uint maxComponent = 0;
                uint flags = 0;
                StringBuilder fsName = new StringBuilder(64);
                if (!GetVolumeInformationByHandleW(handle, null, 0, out serial, out maxComponent, out flags, fsName, (uint)fsName.Capacity)) {
                    return null;
                }
                string serialText = serial.ToString("X8");
                string volumeGuid = GetFinalPathVolumeGuid(path);
                if (string.IsNullOrEmpty(volumeGuid)) { return "serial:" + serialText; }
                return volumeGuid.ToLowerInvariant().TrimEnd('\\') + "|serial:" + serialText;
            } finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) { try { CloseHandle(handle); } catch { } }
            }
        }

        // Volume GUID mount path (\\?\Volume{guid}\) of the volume that holds the *target* of path.
        public static string GetFinalPathVolumeGuid(string path) {
            IntPtr handle = IntPtr.Zero;
            try {
                handle = OpenForQuery(path, true);
                if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return null; }
                StringBuilder name = new StringBuilder(1024);
                uint written = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, VOLUME_NAME_NT);
                if (written == 0) { return null; }
                string nt = name.ToString();
                if (nt.StartsWith("\\??\\", StringComparison.Ordinal)) { nt = "\\Device" + nt.Substring(5); }
                int cut = nt.IndexOf('\\', 8);
                if (cut > 8) { nt = nt.Substring(0, cut); } else { return null; }
                // Translate the NT device name back to a Volume GUID path via any mount point on it.
                StringBuilder mount = new StringBuilder(260);
                if (!GetVolumePathNameW(path, mount, (uint)mount.Capacity)) { return null; }
                StringBuilder guid = new StringBuilder(260);
                if (GetVolumeNameForVolumeMountPointW(mount.ToString(), guid, (uint)guid.Capacity) == IntPtr.Zero) { return null; }
                string result = guid.ToString();
                if (string.IsNullOrEmpty(result)) { return null; }
                return result;
            } finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) { try { CloseHandle(handle); } catch { } }
            }
        }

        // Final path of the *target* in Win32 form, for canonical comparison.
        public static string FinalPath(string path) {
            IntPtr handle = IntPtr.Zero;
            try {
                handle = OpenForQuery(path, true);
                if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return null; }
                StringBuilder name = new StringBuilder(4096);
                if (GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, VOLUME_NAME_DOS) == 0) { return null; }
                return name.ToString();
            } finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) { try { CloseHandle(handle); } catch { } }
            }
        }

        // Every volume GUID path known to this computer, so the OS volume is recognised by identity
        // and not by an assumed drive letter.
        public static string[] AllVolumeGuidPaths() {
            List<string> results = new List<string>();
            StringBuilder buffer = new StringBuilder(260);
            IntPtr find = FindFirstVolumeW(buffer, (uint)buffer.Capacity);
            if (find == IntPtr.Zero || find == new IntPtr(-1)) { return results.ToArray(); }
            try {
                while (true) {
                    results.Add(buffer.ToString());
                    buffer.Length = 0;
                    if (!FindNextVolumeW(find, buffer, (uint)buffer.Capacity)) { break; }
                }
            } finally { FindVolumeClose(find); }
            return results.ToArray();
        }

        public static string[] VolumeMountPoints(string volumeName) {
            List<string> results = new List<string>();
            uint needed = 0;
            char[] buffer = new char[1024];
            bool ok = GetVolumePathNamesForVolumeNameW(volumeName, buffer, (uint)buffer.Length, out needed);
            if (!ok) {
                if (needed > buffer.Length) {
                    buffer = new char[needed];
                    ok = GetVolumePathNamesForVolumeNameW(volumeName, buffer, (uint)buffer.Length, out needed);
                }
                if (!ok) { return results.ToArray(); }
            }
            int start = 0;
            for (int i = 0; i < buffer.Length; i++) {
                if (buffer[i] == '\0') {
                    if (i == start) { break; }
                    results.Add(new string(buffer, start, i - start));
                    start = i + 1;
                }
            }
            return results.ToArray();
        }

        public static bool HasReparseAttribute(string path) {
            return (System.IO.File.GetAttributes(path) & System.IO.FileAttributes.ReparsePoint) == System.IO.FileAttributes.ReparsePoint;
        }

        public static bool IsDirectory(string path) {
            return (System.IO.File.GetAttributes(path) & System.IO.FileAttributes.Directory) == System.IO.FileAttributes.Directory;
        }
    }
}
'@ -ErrorAction Stop
}

function ConvertTo-PitrArgumentException {
    param([string]$Message)
    return (New-Object System.ArgumentException($Message))
}

# Windows reserved device names. CON, NUL, PRN, AUX, COM1-9 and LPT1-9 are rejected: a device
# path cannot be opened as a backup target on any modern Windows, and treating a device as a
# missing file would make the caller believe the destination is fine.
function Get-PitrReservedDeviceName {
    @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
}

function Test-PitrWindowsComponent {
    # $true when the single component is a legal, usable Windows file/directory name. Never throws.
    param([Parameter(Mandatory=$true)][string]$Component)
    if ([string]::IsNullOrEmpty($Component)) { return $false }
    if ($Component -eq '.' -or $Component -eq '..') { return $false }
    if ($Component.Length -gt 255) { return $false }
    foreach ($character in $Component.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 32) { return $false }
        if ($character -eq '<' -or $character -eq '>' -or $character -eq ':' -or $character -eq '"' -or
            $character -eq '/' -or $character -eq '\' -or $character -eq '|' -or $character -eq '?' -or
            $character -eq '*') { return $false }
    }
    if ($Component.EndsWith('.',[StringComparison]::Ordinal)) { return $false }
    if ($Component.EndsWith(' ',[StringComparison]::Ordinal)) { return $false }
    $stem = ($Component.Split('.')[0]).TrimEnd(' ')
    if ($stem.ToUpperInvariant() -in (Get-PitrReservedDeviceName)) { return $false }
    # A device name with a non-standard trailing suffix such as NUL: or CLOCK$ opens the
    # device, not a file on modern Windows; those cases are refused fail-closed.
    if ($Component.Contains('$') -or $Component.IndexOf(':') -ge 0) { return $false }
    if ($stem.ToUpperInvariant() -match '^(CONIN|CONOUT|CON|NUL|AUX|PRN|CLOCK)$') { return $false }
    return $true
}

function ConvertTo-PitrRelativeComponents {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw (ConvertTo-PitrArgumentException 'Relative path is empty.') }
    $normalized = $RelativePath.Replace('\','/')
    if ($normalized.StartsWith('/') -or $normalized.StartsWith(' ') -or $normalized -match '^//') {
        throw (ConvertTo-PitrArgumentException ('Rooted or device relative name is not allowed: ' + $RelativePath))
    }
    if ($normalized.Contains(':')) {
        throw (ConvertTo-PitrArgumentException ('Alternate data streams, drive-relative names and device names are not allowed: ' + $RelativePath))
    }
    $components = New-Object 'Collections.Generic.List[string]'
    foreach ($part in $normalized.Split('/')) {
        if ($part -eq '') { continue }
        if ($part -eq '.') { continue }
        if ($part -eq '..') { throw (ConvertTo-PitrArgumentException ('Path traversal is not allowed: ' + $RelativePath)) }
        if (-not (Test-PitrWindowsComponent -Component $part)) { throw (ConvertTo-PitrArgumentException ('Illegal Windows path component: ' + $part)) }
        $components.Add($part)
    }
    if ($components.Count -eq 0) { throw (ConvertTo-PitrArgumentException ('Relative path has no usable file name: ' + $RelativePath)) }
    return $components
}

function Test-PitrReparseAncestor {
    # Returns the offending reparse point at or above the final path, otherwise $null.
    param([string]$Root,[string[]]$Components)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    if (Test-Path -LiteralPath $Root) {
        try { if (([IO.File]::GetAttributes($Root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $Root } } catch { }
    }
    $current = $Root
    for ($index = 0; $index -lt ($Components.Count - 1); $index++) {
        $current = Join-Path $current $Components[$index]
        if (Test-Path -LiteralPath $current) {
            try { if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $current } } catch { }
        }
    }
    return $null
}

function Test-PitrAncestorOrSame {
    param([string]$Candidate,[string]$Other)
    if ($Candidate -eq $Other) { return $true }
    if ($Other.StartsWith($Candidate + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Other.StartsWith($Candidate + [IO.Path]::AltDirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Test-PitrSafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$RelativePath)
    $components = ConvertTo-PitrRelativeComponents -RelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($Root)) { throw (ConvertTo-PitrArgumentException 'Root is empty.') }
    if (-not [IO.Path]::IsPathRooted($Root)) { throw (ConvertTo-PitrArgumentException ('Root must be an absolute path: ' + $Root)) }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $fullRoot)) { throw (ConvertTo-PitrArgumentException ('Root does not exist: ' + $Root)) }
    $reparse = Test-PitrReparseAncestor -Root $fullRoot -Components ([string[]]$components)
    if ($reparse) { throw (ConvertTo-PitrArgumentException ('Root or ancestor is a reparse point: ' + $reparse)) }
    return ($components -join '/')
}

function Get-PitrPathEntry {
    # Resolves the nearest existing ancestor plus the not-yet-existing remainder.
    # Off Windows a synthetic fixture may point at a location that exists only as far as the
    # root of the fixture, so the climb may terminate on an existing ancestor.
    param([string]$Path,[switch]$Permissive)
    if (-not $Permissive -and -not [IO.Path]::IsPathRooted([string]$Path)) {
        # A relative path resolves against the process working directory, so the volume it names
        # is not the user's intent. Refuse instead of guessing which disk gets the backup.
        throw (ConvertTo-PitrArgumentException ('Path form cannot be verified on Windows: ' + $Path))
    }
    $canonical = [IO.Path]::GetFullPath(([string]$Path).TrimEnd([char]92,[char]47))
    if ([string]::IsNullOrEmpty($canonical)) { $canonical = [IO.Path]::GetFullPath($Path) }
    if (-not $Permissive -and -not [IO.Path]::IsPathRooted($canonical)) {
        throw (ConvertTo-PitrArgumentException ('Path form cannot be verified on Windows: ' + $Path))
    }
    $missing = New-Object 'Collections.Generic.List[string]'
    $anchor = $canonical
    $guard = 0
    while ($true) {
        if (Test-Path -LiteralPath $anchor -ErrorAction SilentlyContinue) { break }
        $guard = $guard + 1
        if ($guard -gt 512) { throw (ConvertTo-PitrArgumentException ('Path cannot be resolved on this computer: ' + $Path)) }
        $leaf = Split-Path $anchor -Leaf
        if ([string]::IsNullOrEmpty($leaf)) { throw (ConvertTo-PitrArgumentException ('Path cannot be resolved on this computer: ' + $Path)) }
        $missing.Insert(0,$leaf)
        $anchor = Split-Path $anchor -Parent
        if ([string]::IsNullOrEmpty($anchor)) { throw (ConvertTo-PitrArgumentException ('Path cannot be resolved on this computer: ' + $Path)) }
    }
    [pscustomobject]@{
        CanonicalPath=$canonical
        ResolvedPath=$anchor
        MissingComponents=$missing.ToArray()
        Separator=[IO.Path]::DirectorySeparatorChar
    }
}

function Get-PitrWindowsHost {
    # Windows identity is a runtime fact, not a spoofable environment assertion.
    # The force hook can exercise synthetic branches off Windows only; it cannot
    # disable native Windows checks or enable fixture identity on a Windows runtime.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return $true }
    return ($env:PITR_FORCE_WINDOWS_HOST -eq '1')
}

function Get-PitrNativeVolumeAvailable {
    try { $null = [Pitr.WindowsNative]; return $true } catch { return $false }
}

function Get-PitrVolumeIdentityFixture {
    # Only non-Windows synthetic fixtures may override identity. Native Windows
    # safety decisions must never consume inherited environment-provided identities.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return $null }
    if (-not $env:PITR_VOLUME_IDENTITY_FIXTURE) { return $null }
    $path = $env:PITR_VOLUME_IDENTITY_FIXTURE
    if (-not [IO.File]::Exists($path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-PitrVolumeIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw (ConvertTo-PitrArgumentException 'Path is empty.') }
    $warnings = New-Object 'Collections.Generic.List[string]'
    $onWindowsHost = Get-PitrWindowsHost
    $entry = Get-PitrPathEntry -Path $Path -Permissive:(-not $onWindowsHost)
    $resolved = $entry.ResolvedPath
    $comparisonPath = [IO.Path]::GetFullPath($entry.CanonicalPath)
    $comparisonResolved = [IO.Path]::GetFullPath($resolved)
    $kind = 'Local'
    $volumeId = $null
    $fileSystem = $null
    $available = $null
    if (-not [IO.Path]::IsPathRooted($entry.CanonicalPath)) {
        # No drive-qualified form on this host (synthetic POSIX fixtures, drive-relative input).
        # The identity deliberately keys on the nearest existing ancestor, which is exactly what
        # Windows does for a path whose leaf does not exist yet: C:\Users\X\new-folder is on C:.
        $hostPrefix = 'host-path:'
        $fixture = Get-PitrVolumeIdentityFixture
        $override = $null
        if ($fixture -and $fixture.PSObject.Properties[$entry.ResolvedPath]) { $override = [string]$fixture.PSObject.Properties[$entry.ResolvedPath].Value }
        $comparison = [IO.Path]::GetFullPath($entry.CanonicalPath)
        return [pscustomobject]@{
            Kind='Local'
            VolumeId=if ($override) { $override } else { $hostPrefix + [IO.Path]::GetFullPath($entry.ResolvedPath) }
            CanonicalPath=$entry.CanonicalPath
            CanonicalComparisonPath=$comparison
            ResolvedPath=$entry.ResolvedPath
            ResolvedComparisonPath=[IO.Path]::GetFullPath($entry.ResolvedPath)
            MissingComponents=$entry.MissingComponents
            FileSystem=$null
            AvailableBytes=$null
            Warnings=@('Path is not drive-qualified on this host; volume identity is derived from the nearest existing ancestor and is not a Windows volume identity.')
        }
    }
    if (-not $onWindowsHost) {
        $warnings.Add('Running on a non-Windows host: volume identity is a host path fallback, never a Windows volume identity.')
    }
    if ($resolved.StartsWith('\\')) {
        $kind = 'Network'
        if ($resolved.StartsWith('\\?\UNC\')) { $unc = '\\' + $resolved.Substring(8) } else { $unc = $resolved }
        $parts = $unc.Split('\')
        $server = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        $share = if ($parts.Count -gt 3) { $parts[3] } else { '' }
        $volumeId = 'unc:' + $server.ToLowerInvariant() + '\' + $share.ToLowerInvariant()
        $warnings.Add('Destination is a network path. Independence of storage, physical device and server cannot be verified; a share may still live on this computer or on the same physical disk. No credentials are read, stored or logged.')
        if ($server -in @('.','localhost','127.0.0.1','::1')) {
            throw (ConvertTo-PitrArgumentException ('A loopback share is not an independent backup destination: ' + $Path))
        }
    } else {
        try { $fileSystem = (Get-Item -LiteralPath $resolved -ErrorAction Stop).PSDrive.FileSystem } catch { $fileSystem = $null }
        try {
            $drive = New-Object IO.DriveInfo($entry.CanonicalPath)
            if ($drive.IsReady) {
                if ([string]::IsNullOrEmpty($fileSystem)) { $fileSystem = $drive.DriveFormat }
                $available = $drive.AvailableFreeSpace
            }
        } catch { }
        $nativeAvailable = Get-PitrNativeVolumeAvailable
        $fixture = Get-PitrVolumeIdentityFixture
        $override = $null
        if ($fixture -and $fixture.PSObject.Properties[$comparisonPath]) { $override = [string]$fixture.PSObject.Properties[$comparisonPath].Value }
        if ($override) {
            $volumeId = $override
        } elseif ($onWindowsHost -and $nativeAvailable) {
            $native = $null
            try { $native = [Pitr.WindowsNative]::QueryIdentity($resolved) } catch { $native = $null }
            if (-not [string]::IsNullOrEmpty($native)) { $volumeId = 'local-' + $native.ToLowerInvariant() }
            $final = $null
            try { $final = [Pitr.WindowsNative]::FinalPath($resolved) } catch { $final = $null }
            if (-not [string]::IsNullOrEmpty($final)) {
                $final = $final -replace '^\\\\\?\\',''
                $final = $final -replace '^UNC\\','\\'
                if ([IO.Path]::IsPathRooted($final)) { $comparisonPath = [IO.Path]::GetFullPath($final); $comparisonResolved = $comparisonPath }
            }
        }
        if ([string]::IsNullOrEmpty($volumeId)) {
            # Windows: the native identity above is mandatory for local paths. Refusing to guess is
            # what stops a mapped drive, SUBST alias or mount point from passing as a real volume.
            if ($onWindowsHost) {
                throw (ConvertTo-PitrArgumentException ('Local volume identity could not be verified natively; refusing to guess: ' + $Path))
            }
            $drive = $null
            try { $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($entry.CanonicalPath)) } catch { $drive = $null }
            if ($null -ne $drive -and $drive.DriveType -eq [IO.DriveType]::Network) { $kind = 'Network' }
            $volumeId = 'host-path:' + $comparisonPath
            $warnings.Add('Volume identity is a host path fallback. It is not evidence that the destination is independent of the operating system volume; real Windows verification is required.')
        }
    }
    [pscustomobject]@{
        Kind=$kind
        VolumeId=$volumeId
        CanonicalPath=$entry.CanonicalPath
        CanonicalComparisonPath=$comparisonPath
        ResolvedPath=$resolved
        ResolvedComparisonPath=$comparisonResolved
        MissingComponents=$entry.MissingComponents
        FileSystem=$fileSystem
        AvailableBytes=$available
        Warnings=$warnings.ToArray()
    }
}

function Test-PitrWritableProbe {
    # Own uniquely named probe file only, always removed. Never writes into user content paths.
    param([string]$Directory)
    $probe = Join-Path $Directory ('.pitr-write-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes = New-Object byte[] 4096
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
            try { [IO.File]::Delete($probe) } catch { }
        }
    }
}

function Test-PitrDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Sources,
        [long]$RequiredBytes=0
    )
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw (ConvertTo-PitrArgumentException 'Destination is empty.') }
    if ($RequiredBytes -lt 0) { throw (ConvertTo-PitrArgumentException 'RequiredBytes cannot be negative.') }
    $onWindowsHost = Get-PitrWindowsHost
    $identity = Get-PitrVolumeIdentity -Path $Destination
    foreach ($source in $Sources) {
        if ([string]::IsNullOrWhiteSpace($source)) { throw (ConvertTo-PitrArgumentException 'A source path is empty; refusing to guess the intended source.') }
        $sourceIdentity = Get-PitrVolumeIdentity -Path $source
        if ($identity.CanonicalComparisonPath -eq $sourceIdentity.CanonicalComparisonPath) {
            throw (ConvertTo-PitrArgumentException ('Backup destination must not be the source itself: ' + $source))
        }
        if (Test-PitrAncestorOrSame -Candidate $sourceIdentity.CanonicalComparisonPath -Other $identity.CanonicalComparisonPath) {
            throw (ConvertTo-PitrArgumentException ('Backup destination is inside the source and would be copied into the backup: ' + $source))
        }
        if (Test-PitrAncestorOrSame -Candidate $identity.CanonicalComparisonPath -Other $sourceIdentity.CanonicalComparisonPath) {
            throw (ConvertTo-PitrArgumentException ('Backup destination is an ancestor of the source: ' + $source))
        }
        if ($identity.Kind -eq 'Local' -and $sourceIdentity.Kind -eq 'Local' -and $identity.VolumeId -eq $sourceIdentity.VolumeId) {
            throw (ConvertTo-PitrArgumentException ('Backup destination is on the same volume as source data and would be destroyed with it: ' + $source))
        }
    }
    if ($onWindowsHost -and $identity.Kind -eq 'Local') {
        $osIdentity = $null
        $systemRoot=$null
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $systemRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        } else { $systemRoot=$env:SystemRoot } # Synthetic non-Windows host branch only.
        if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw (ConvertTo-PitrArgumentException 'Operating system directory cannot be established; refusing the destination.') }
        try { $osIdentity = Get-PitrVolumeIdentity -Path $systemRoot }
        catch { throw (ConvertTo-PitrArgumentException 'Operating system volume identity cannot be established; refusing the destination.') }
        if (-not $osIdentity) { throw (ConvertTo-PitrArgumentException 'Operating system volume identity is unavailable; refusing the destination.') }
        if ($osIdentity -and $identity.VolumeId -eq $osIdentity.VolumeId) {
            throw (ConvertTo-PitrArgumentException ('Backup destination is on the operating system volume; point-in-time recovery would remove it together with the system: ' + $Destination))
        }
        if ($osIdentity -and (Get-PitrNativeVolumeAvailable)) {
            $mountPoints = @()
            try { $mountPoints = [Pitr.WindowsNative]::VolumeMountPoints($osIdentity.VolumeId.Split('|')[0]) } catch { $mountPoints = @() }
            foreach ($mountPoint in $mountPoints) {
                if ([string]::IsNullOrWhiteSpace($mountPoint)) { continue }
                if ($identity.CanonicalComparisonPath.StartsWith($mountPoint,[StringComparison]::OrdinalIgnoreCase)) {
                    throw (ConvertTo-PitrArgumentException ('Backup destination resolves onto the operating system volume through a mount point or alias: ' + $Destination))
                }
            }
        }
    }
    if ($null -ne $identity.AvailableBytes -and $identity.AvailableBytes -lt $RequiredBytes) {
        throw (ConvertTo-PitrArgumentException ('Backup destination does not have enough free space for ' + $RequiredBytes + ' bytes.'))
    }
    try {
        Test-PitrWritableProbe -Directory $identity.ResolvedPath
    } catch {
        throw (ConvertTo-PitrArgumentException ('Backup destination is not writable: ' + $Destination + ' : ' + $_.Exception.Message))
    }
    return $identity
}

function Get-PitrProfiles {
    # Contract surface: normal ProfileList profiles plus Public on the default OS volume only.
    # Inaccessible registrations are exposed with Inaccessible/Reason instead of being omitted.
    $profiles = @(Get-PitrProfileListProfiles)
    if(@($profiles | Where-Object { $_.IsPublic }).Count -eq 0) { $profiles += Get-PitrPublicProfile }
    return $profiles
}

function Get-PitrPublicProfile {
    # Public is a shared directory, not a normal user SID registration. Keep the
    # existing synthetic identity for compatibility with older manifests/fixtures.
    $row=[pscustomobject]@{Sid='S-1-5-32-545';Path=$null;IsPublic=$true;Inaccessible=$true;Reason=$null}
    try {
        if(-not (Get-PitrWindowsHost)) { throw 'Public discovery requires the Windows registry.' }
        $value=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name 'Public' -ErrorAction Stop
        $property=$value.PSObject.Properties['Public']
        if($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw 'Public registry location is unavailable.' }
        $path=[Environment]::ExpandEnvironmentVariables([string]$property.Value)
        $row.Path=$path
        if(-not [IO.Path]::IsPathRooted($path) -or -not [IO.Directory]::Exists($path)) { throw 'Public folder is missing, inaccessible or not an absolute path.' }
        $publicVolume=Get-PitrVolumeIdentity -Path $path
        $osVolume=Get-PitrVolumeIdentity -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows))
        if(-not $publicVolume.VolumeId -or -not $osVolume.VolumeId -or $publicVolume.VolumeId -ne $osVolume.VolumeId) { throw 'Public folder is outside the supported operating-system volume or its volume identity is unavailable.' }
        $row.Inaccessible=$false
    } catch { $row.Reason=$_.Exception.Message }
    return $row
}

function Get-PitrProfileListProfiles {
    # Reads real profile registrations. The fixture hook keeps the same branches testable off Windows.
    if ($env:PITR_PROFILELIST_FIXTURE_PATH) {
        $path = $env:PITR_PROFILELIST_FIXTURE_PATH
        if (-not [IO.File]::Exists($path)) { throw (ConvertTo-PitrArgumentException ('Profile fixture not found: ' + $path)) }
        $rows = @(Import-Csv -LiteralPath $path)
        $fixtures = New-Object 'Collections.Generic.List[object]'
        foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace([string]$row.Sid)) { throw (ConvertTo-PitrArgumentException 'Profile fixture row has no Sid.') }
            $value = [string]$row.Path
            if ([string]::IsNullOrWhiteSpace($value)) {
                $fixtures.Add([pscustomobject]@{ Sid=$row.Sid; Path=$null; IsPublic=$false; Inaccessible=$true; Reason='ProfileImagePath is not readable.' })
                continue
            }
            if ($value -match '%([^%]+)%') { $value = [Environment]::ExpandEnvironmentVariables($value) }
            if (-not [IO.Path]::IsPathRooted($value)) {
                $fixtures.Add([pscustomobject]@{ Sid=$row.Sid; Path=$row.Path; IsPublic=$false; Inaccessible=$true; Reason='ProfileImagePath is not an absolute path.' })
                continue
            }
            if (-not (Test-Path -LiteralPath $value)) {
                # A registered profile whose path is missing cannot be selected as a source on any
                # host; reporting it usable would promise a backup of data that is not there.
                $fixtures.Add([pscustomobject]@{ Sid=$row.Sid; Path=$value; IsPublic=$false; Inaccessible=$true; Reason='Profile path does not exist on this host.' })
                continue
            }
            $fixtures.Add([pscustomobject]@{ Sid=$row.Sid; Path=$value; IsPublic=($row.Sid -eq 'S-1-5-32-545'); Inaccessible=$false; Reason=$null })
        }
        return $fixtures.ToArray()
    }
    $results = New-Object 'Collections.Generic.List[object]'
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    if (-not (Test-Path -LiteralPath $key)) { throw (ConvertTo-PitrArgumentException 'ProfileList registry key is unavailable; profile discovery cannot run.') }
    foreach ($subKey in Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue) {
        $name = Split-Path $subKey.Name -Leaf
        $value = $null
        try { $value = (Get-ItemProperty -LiteralPath $subKey.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath } catch { $value = $null }
        if ([string]::IsNullOrEmpty($value)) {
            $results.Add([pscustomobject]@{ Sid=$name; Path=$null; IsPublic=$false; Inaccessible=$true; Reason='ProfileImagePath is not readable.' })
            continue
        }
        $expanded = $value
        if ($expanded -match '%([^%]+)%') { $expanded = [Environment]::ExpandEnvironmentVariables($expanded) }
        if (-not [IO.Path]::IsPathRooted($expanded)) {
            $results.Add([pscustomobject]@{ Sid=$name; Path=$value; IsPublic=$false; Inaccessible=$true; Reason='ProfileImagePath is not an absolute path.' })
            continue
        }
        if (-not (Test-Path -LiteralPath $expanded)) {
            $results.Add([pscustomobject]@{ Sid=$name; Path=$expanded; IsPublic=$false; Inaccessible=$true; Reason='Profile path does not exist on this host.' })
            continue
        }
        $isPublic = ($name -eq 'S-1-5-32-545')
        $results.Add([pscustomobject]@{ Sid=$name; Path=$expanded; IsPublic=$isPublic; Inaccessible=$false; Reason=$null })
    }
    return $results.ToArray()
}

function New-PitrStableId {
    param([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $algorithm.Dispose() }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $hash[0..15]) { $null = $builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function Get-PitrSourceRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter(Mandatory=$false)][ValidateSet('Complete','Personal','Custom')][string]$Scope='Complete',
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][string[]]$CustomPaths=@()
    )
    $results = New-Object 'Collections.Generic.List[object]'
    $seen = @{}
    foreach ($profile in $Profiles) {
        if ($null -eq $profile) { continue }
        $sid = [string]$profile.Sid
        if ([string]::IsNullOrWhiteSpace($sid)) { throw (ConvertTo-PitrArgumentException 'A selected profile has no SID; refusing to guess profile identity.') }
        if ($null -ne $profile.PSObject.Properties['Inaccessible'] -and $profile.Inaccessible) {
            throw (ConvertTo-PitrArgumentException ('Selected profile is inaccessible and cannot be silently skipped: ' + $sid + ' : ' + [string]$profile.Reason))
        }
        if ([string]::IsNullOrWhiteSpace([string]$profile.Path)) { throw (ConvertTo-PitrArgumentException ('Selected profile has no path: ' + $sid)) }
        if ($Scope -eq 'Custom') { continue }
        $isPublic = ($null -ne $profile.PSObject.Properties['IsPublic'] -and $profile.IsPublic)
        # Complete is one tree, never overlapping Profile and Personal copies.
        $targets = @([pscustomobject]@{ Category='Profile'; Path=$profile.Path; Name='Profile' })
        if ($Scope -eq 'Personal') {
            $targets = @()
            foreach ($folder in @('Desktop','Documents','Downloads','Pictures','Videos','Music','Favorites','Saved Games')) {
                $candidate = Join-Path $profile.Path $folder
                if ([IO.Directory]::Exists($candidate)) {
                    $targets += [pscustomobject]@{ Category='Personal'; Path=$candidate; Name=$folder }
                }
            }
            if ($targets.Count -eq 0) { throw ('No supported personal folders found; select Custom to include redirected folders: ' + $profile.Path) }
        }
        foreach ($target in $targets) {
            $category = $target.Category
            $id = 'profile-' + $sid + '-' + $target.Name.ToLowerInvariant().Replace(' ','-')
            if ($id.Length -gt 96) { $id = 'profile-' + (New-PitrStableId -Text ($sid + '|' + $target.Name)) }
            if ($seen.ContainsKey($id)) { throw (ConvertTo-PitrArgumentException ('Duplicate source id: ' + $id)) }
            $seen[$id] = $true
            $identity = $null
            try { $identity = Get-PitrVolumeIdentity -Path $target.Path } catch { $identity = $null }
            $warnings = if ($identity) { @($identity.Warnings) } else { @('Source volume identity could not be resolved.') }
            if ($Scope -eq 'Personal') { $warnings += @('Personal scope uses existing conventional folders only. Review redirected and cloud folders separately with Custom scope.') }
            $results.Add([pscustomobject]@{
                Id=$id
                Path=$target.Path
                ProfileSid=$sid
                SourceVolumeId=if ($identity) { $identity.VolumeId } else { $null }
                Category=$category
                DisplayName=if ($isPublic) { 'Public' } else { $sid }
                IsPublic=$isPublic
                Complete=($Scope -eq 'Complete')
                Warnings=$warnings
            })
        }
    }
    if ($Scope -eq 'Custom' -and $CustomPaths.Count -eq 0) {
        throw (ConvertTo-PitrArgumentException 'Custom scope requires at least one explicit folder. It never silently includes all profiles.')
    }
    $index = 0
    foreach ($path in $CustomPaths) {
        $index++
        if ([string]::IsNullOrWhiteSpace($path)) { throw (ConvertTo-PitrArgumentException 'A custom folder entry is empty.') }
        $entry = Get-PitrPathEntry -Path $path -Permissive:(-not (Get-PitrWindowsHost))
        # A selected folder must exist; a selected file is accepted by the caller-supplied
        # inventory (spec allows Explorer-readable files) but a missing target is never guessed.
        if (-not (Test-Path -LiteralPath $entry.ResolvedPath)) {
            throw (ConvertTo-PitrArgumentException ('Custom source folder does not exist: ' + $path))
        }
        $target = $entry.ResolvedPath
        foreach ($component in $entry.MissingComponents) { $target = Join-Path $target $component }
        if (-not (Test-Path -LiteralPath $target)) {
            throw (ConvertTo-PitrArgumentException ('Custom source folder does not exist: ' + $path))
        }
        if (-not [IO.Directory]::Exists($target) -and -not [IO.File]::Exists($target)) {
            throw (ConvertTo-PitrArgumentException ('Custom source is neither a file nor a folder: ' + $path))
        }
        $id = 'custom-' + $index + '-' + (New-PitrStableId -Text $entry.CanonicalPath.ToLowerInvariant())
        if ($seen.ContainsKey($id)) { throw (ConvertTo-PitrArgumentException ('Duplicate source id: ' + $id)) }
        $seen[$id] = $true
        $identity = Get-PitrVolumeIdentity -Path $entry.CanonicalPath
        $results.Add([pscustomobject]@{
            Id=$id
            Path=$entry.CanonicalPath
            ProfileSid=$null
            SourceVolumeId=$identity.VolumeId
            Category='Extra'
            DisplayName=(Split-Path $entry.CanonicalPath -Leaf)
            IsPublic=$false
            Complete=($Scope -eq 'Complete')
            Warnings=@($identity.Warnings)
        })
    }
    return $results.ToArray()
}