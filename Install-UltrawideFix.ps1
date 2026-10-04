<#
.SYNOPSIS
    Creates a separate, patched copy of Quake Live (Steam) that renders a true
    ultrawide (wider than 16:9) picture without horizontal stretching.

.DESCRIPTION
    Quake Live caps its horizontal field of view at 16:9 and stretches anything
    wider. This script:

      1. Finds the Steam Quake Live install (app 282440), or uses -SourcePath.
      2. Verifies that cgamex86.dll inside baseq3\bin.pk3 is the exact supported
         build (known SHA-256 and expected bytes at the patch offset). If not,
         it aborts without copying anything.
      3. Copies the whole install to -Destination (outside any Steam library).
         The Steam install itself is only read, never modified.
      4. In the COPY only, replaces the float 9.0 used by the 16:9 FOV preset
         with 16*Height/Width, and repacks bin.pk3.
      5. Deletes stale unpacked cgamex86.dll files in the copy's per-user
         <steamid>\baseq3 folders, writes an autoexec.cfg block with the
         resolution settings, and creates a desktop shortcut.

    The patched copy is for OFFLINE / LOCAL play with Steam in Offline Mode
    only. Read the VAC warning in README.md before using it.

    Requires Windows PowerShell 5.1 or PowerShell 7+. No third-party tools.

.PARAMETER SourcePath
    Quake Live install folder. Default: auto-detected from Steam.

.PARAMETER Destination
    Folder for the patched copy. Must not exist (or be empty) and must be
    outside every Steam library. Prompted for if omitted.

.PARAMETER Width
.PARAMETER Height
    Target resolution. Default: the primary monitor's current resolution
    (read in physical pixels, DPI-aware). Must be wider than 16:9.

.PARAMETER ShortcutName
    Desktop shortcut name. Default: 'Quake Live (Ultrawide, Offline)'.

.PARAMETER NoShortcut
    Do not create a desktop shortcut.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.EXAMPLE
    .\Install-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide' -WhatIf
    Dry run: runs every check and computes the patched hash, writes nothing.

.EXAMPLE
    .\Install-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide' -Width 3440 -Height 1440
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourcePath,
    [string]$Destination,
    [int]$Width,
    [int]$Height,
    [string]$ShortcutName = 'Quake Live (Ultrawide, Offline)',
    [switch]$NoShortcut,
    [switch]$Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants
$script:AppId             = '282440'
$script:OriginalDllSha256 = '310542161AE03CC09A2EDF7C5933A3CB5E2F13D791F59D5A33A62721BBF39953'
$script:PatchOffset       = 0x7246c
$script:OriginalBytes     = [byte[]](0x00, 0x00, 0x10, 0x41)   # float32 9.0, little-endian
$script:DllEntryName      = 'cgamex86.dll'
$script:MarkerFileName    = 'ultrawide-fix.json'
$script:CfgBeginMarker    = '// >>> quake-live-ultrawide-fix (managed block, do not edit)'
$script:CfgEndMarker      = '// <<< quake-live-ultrawide-fix'

# ---------------------------------------------------------------- helpers
function Get-ByteArraySha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Format-HexBytes {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

function Get-PatchBytes {
    param([int]$Width, [int]$Height)
    $value = [single](16.0 * $Height / $Width)
    $bytes = [BitConverter]::GetBytes($value)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return , $bytes
}

function Get-FullPathNormalized {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd('\', '/')
}

function Test-PathIsUnder {
    param([string]$Child, [string]$Parent)
    $c = (Get-FullPathNormalized $Child) + [System.IO.Path]::DirectorySeparatorChar
    $p = (Get-FullPathNormalized $Parent) + [System.IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SteamRoot {
    $candidates = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in 'SteamPath', 'InstallPath') {
                if ($props.PSObject.Properties[$name] -and $props.$name) { $candidates += ($props.$name -replace '/', '\') }
            }
        } catch { }
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return (Get-FullPathNormalized $c) } }
    return $null
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $root = Get-SteamRoot
    if (-not $root) { return , $libs.ToArray() }
    $libs.Add($root)
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw
        foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\' -replace '/', '\'
            if ((Test-Path -LiteralPath $p) -and -not ($libs | Where-Object { $_ -ieq (Get-FullPathNormalized $p) })) {
                $libs.Add((Get-FullPathNormalized $p))
            }
        }
    }
    return , $libs.ToArray()
}

function Find-QuakeLiveInstall {
    param([string[]]$Libraries)
    foreach ($lib in $Libraries) {
        $acf = Join-Path $lib ("steamapps\appmanifest_{0}.acf" -f $script:AppId)
        if (Test-Path -LiteralPath $acf) {
            $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
            $dir = if ($m.Success) { $m.Groups[1].Value } else { 'Quake Live' }
            $path = Join-Path $lib ("steamapps\common\{0}" -f $dir)
            if (Test-Path -LiteralPath (Join-Path $path 'quakelive_steam.exe')) { return $path }
        }
    }
    return $null
}

function Get-PrimaryMonitorResolution {
    # Physical pixels of the primary display's current mode (independent of DPI scaling).
    if (-not ('UltrawideFix.Display' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace UltrawideFix {
  public static class Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
      public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
      public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
      public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public static int[] Primary() {
      try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
      DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(null, -1, ref dm)) return null;
      return new int[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency };
    }
  }
}
"@
    }
    return [UltrawideFix.Display]::Primary()
}

function Read-ZipEntryBytes {
    param([System.IO.Compression.ZipArchive]$Archive, [string]$EntryName)
    $entry = $Archive.GetEntry($EntryName)
    if (-not $entry) { throw "Entry '$EntryName' not found in archive." }
    $ms = New-Object System.IO.MemoryStream
    $s = $entry.Open()
    try { $s.CopyTo($ms) } finally { $s.Dispose() }
    return , $ms.ToArray()
}

function Test-SupportedDll {
    # Returns $null if supported, otherwise a reason string.
    param([byte[]]$DllBytes)
    $hash = Get-ByteArraySha256 $DllBytes
    if ($hash -ne $script:OriginalDllSha256) {
        return "cgamex86.dll SHA-256 is $hash, expected $($script:OriginalDllSha256)."
    }
    if ($DllBytes.Length -lt ($script:PatchOffset + 4)) { return 'cgamex86.dll is too small.' }
    $cur = [byte[]]$DllBytes[$script:PatchOffset..($script:PatchOffset + 3)]
    if ((Format-HexBytes $cur) -ne (Format-HexBytes $script:OriginalBytes)) {
        return "Unexpected bytes at offset 0x{0:X}: {1} (expected {2})." -f $script:PatchOffset, (Format-HexBytes $cur), (Format-HexBytes $script:OriginalBytes)
    }
    return $null
}

function Get-PatchedDllBytes {
    param([byte[]]$DllBytes, [byte[]]$PatchBytes)
    $copy = [byte[]]$DllBytes.Clone()
    [Array]::Copy($PatchBytes, 0, $copy, $script:PatchOffset, 4)
    return , $copy
}

function Read-OriginalDllFromPk3 {
    param([string]$Pk3Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Pk3Path)
    try { return , (Read-ZipEntryBytes -Archive $zip -EntryName $script:DllEntryName) }
    finally { $zip.Dispose() }
}

function Write-PatchedPk3 {
    # Replaces cgamex86.dll inside the given pk3 (must be the COPY) and returns the new DLL hash.
    param([string]$Pk3Path, [int]$Width, [int]$Height)
    $patch = Get-PatchBytes -Width $Width -Height $Height
    $zip = [System.IO.Compression.ZipFile]::Open($Pk3Path, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $orig = Read-ZipEntryBytes -Archive $zip -EntryName $script:DllEntryName
        $reason = Test-SupportedDll $orig
        if ($reason) { throw "Unsupported game version: $reason" }
        $patched = Get-PatchedDllBytes -DllBytes $orig -PatchBytes $patch
        $zip.GetEntry($script:DllEntryName).Delete()
        $new = $zip.CreateEntry($script:DllEntryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $w = $new.Open()
        try { $w.Write($patched, 0, $patched.Length) } finally { $w.Dispose() }
    } finally { $zip.Dispose() }
    $check = Read-OriginalDllFromPk3 -Pk3Path $Pk3Path
    $checkBytes = [byte[]]$check[$script:PatchOffset..($script:PatchOffset + 3)]
    if ((Format-HexBytes $checkBytes) -ne (Format-HexBytes $patch)) { throw 'Verification failed: patched bytes not found after repacking.' }
    return (Get-ByteArraySha256 $check)
}

function Get-UserConfigFolders {
    # <copy>\<17-digit SteamID64>\baseq3 folders, detected dynamically.
    param([string]$Root)
    $result = @()
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^\d{17}$') {
            $b = Join-Path $d.FullName 'baseq3'
            if (Test-Path -LiteralPath $b) { $result += $b }
        }
    }
    return , $result
}

function Get-AutoexecBlock {
    param([int]$Width, [int]$Height)
    return @(
        $script:CfgBeginMarker,
        'seta r_mode "-1"',
        ('seta r_customWidth "{0}"' -f $Width),
        ('seta r_customHeight "{0}"' -f $Height),
        'seta r_fullscreen "1"',
        'seta vid_xpos "0"',
        'seta vid_ypos "0"',
        'seta sv_pure "0"',
        $script:CfgEndMarker
    ) -join "`r`n"
}

function Set-AutoexecBlock {
    # Keeps any existing user lines; replaces only our managed block. ASCII, no BOM.
    param([string]$Path, [int]$Width, [int]$Height)
    $existing = ''
    if (Test-Path -LiteralPath $Path) { $existing = [System.IO.File]::ReadAllText($Path) }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:CfgBeginMarker) + '.*?' + [regex]::Escape($script:CfgEndMarker) + '\r?\n?'
    $kept = ([regex]::Replace($existing, $pattern, "`r`n")).TrimEnd("`r", "`n")
    $text = if ($kept) { $kept + "`r`n" + (Get-AutoexecBlock $Width $Height) + "`r`n" } else { (Get-AutoexecBlock $Width $Height) + "`r`n" }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.ASCIIEncoding))
}

function Copy-InstallTree {
    param([string]$From, [string]$To)
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Get-ChildItem -LiteralPath $From -Force | Copy-Item -Destination $To -Recurse -Force
    $a = @(Get-ChildItem -LiteralPath $From -Recurse -File -Force)
    $b = @(Get-ChildItem -LiteralPath $To -Recurse -File -Force)
    $sa = ($a | Measure-Object Length -Sum).Sum; $sb = ($b | Measure-Object Length -Sum).Sum
    if ($a.Count -ne $b.Count -or $sa -ne $sb) { throw "Copy verification failed: $($a.Count) files/$sa bytes vs $($b.Count) files/$sb bytes." }
    return $a.Count
}

# ---------------------------------------------------------------- main
function Invoke-Install {
    Write-Host ''
    Write-Host 'Quake Live ultrawide fix - installer' -ForegroundColor Cyan
    Write-Host 'WARNING: the patched copy is for OFFLINE play with Steam in Offline Mode only.' -ForegroundColor Yellow
    Write-Host '         Modified game files can trigger a VAC ban if used online. See README.md.' -ForegroundColor Yellow
    Write-Host ''

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Get-Process -Name 'quakelive_steam' -ErrorAction SilentlyContinue) {
        throw 'Quake Live is running. Close it and run the script again.'
    }

    # --- source
    $libraries = Get-SteamLibraries
    if (-not $SourcePath) {
        $SourcePath = Find-QuakeLiveInstall -Libraries $libraries
        if (-not $SourcePath) { throw 'Could not find the Steam Quake Live install. Pass -SourcePath.' }
    }
    $SourcePath = Get-FullPathNormalized $SourcePath
    $srcPk3 = Join-Path $SourcePath 'baseq3\bin.pk3'
    if (-not (Test-Path -LiteralPath (Join-Path $SourcePath 'quakelive_steam.exe')) -or -not (Test-Path -LiteralPath $srcPk3)) {
        throw "Not a Quake Live install (quakelive_steam.exe or baseq3\bin.pk3 missing): $SourcePath"
    }
    Write-Host "Source       : $SourcePath"

    # --- resolution
    if (-not $Width -or -not $Height) {
        $res = $null
        try { $res = Get-PrimaryMonitorResolution } catch { }
        if (-not $res) { throw 'Could not read the primary monitor resolution. Pass -Width and -Height.' }
        if (-not $Width)  { $Width  = $res[0] }
        if (-not $Height) { $Height = $res[1] }
        Write-Host ("Primary monitor: {0}x{1} @ {2} Hz" -f $res[0], $res[1], $res[2])
    }
    if ($Width -le 0 -or $Height -le 0) { throw 'Width and Height must be positive.' }
    if (([long]$Width * 9) -le ([long]$Height * 16)) {
        throw ("{0}x{1} is not wider than 16:9. Quake Live already handles 16:9 and narrower correctly; nothing to fix." -f $Width, $Height)
    }
    $patchBytes = Get-PatchBytes -Width $Width -Height $Height
    $patchValue = [BitConverter]::ToSingle($patchBytes, 0)
    Write-Host ("Resolution   : {0}x{1} (aspect {2:N3}); patch value 16*{1}/{0} = {3:N4} -> bytes {4}" -f $Width, $Height, ($Width / $Height), $patchValue, (Format-HexBytes $patchBytes))

    # --- verify the source build before copying anything
    $origDll = Read-OriginalDllFromPk3 -Pk3Path $srcPk3
    $reason = Test-SupportedDll $origDll
    if ($reason) {
        throw "Unsupported game version. $reason This script only supports the Quake Live build whose cgamex86.dll SHA-256 is $($script:OriginalDllSha256). Nothing was changed."
    }
    $expectedDll = Get-ByteArraySha256 (Get-PatchedDllBytes -DllBytes $origDll -PatchBytes $patchBytes)
    $srcPk3Hash = (Get-FileHash -LiteralPath $srcPk3 -Algorithm SHA256).Hash
    Write-Host "Source bin.pk3 SHA-256      : $srcPk3Hash"
    Write-Host "Original cgamex86.dll SHA-256: $($script:OriginalDllSha256) (supported build: OK)"
    Write-Host "Patched cgamex86.dll SHA-256 : $expectedDll (expected)"

    # --- destination
    if (-not $Destination) { $Destination = Read-Host 'Destination folder for the patched copy (outside Steam libraries)' }
    if (-not $Destination) { throw 'No destination given.' }
    $Destination = Get-FullPathNormalized $Destination
    foreach ($lib in $libraries) {
        if (Test-PathIsUnder -Child $Destination -Parent $lib) { throw "Destination is inside a Steam library ($lib). Choose a folder outside Steam." }
    }
    if ((Test-PathIsUnder -Child $Destination -Parent $SourcePath) -or (Test-PathIsUnder -Child $SourcePath -Parent $Destination)) {
        throw 'Destination must not overlap the source install.'
    }
    if ((Test-Path -LiteralPath $Destination) -and @(Get-ChildItem -LiteralPath $Destination -Force).Count -gt 0) {
        throw "Destination already exists and is not empty: $Destination (run Uninstall-UltrawideFix.ps1 first, or pick another folder)."
    }
    Write-Host "Destination  : $Destination"

    if (-not $WhatIfPreference -and -not $Force) {
        $answer = Read-Host 'Create the patched OFFLINE copy now? Type Y to continue'
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
    }

    # --- copy
    if ($PSCmdlet.ShouldProcess($Destination, "Copy Quake Live install from '$SourcePath'")) {
        Write-Host 'Copying install (the Steam install is only read)...'
        $n = Copy-InstallTree -From $SourcePath -To $Destination
        Write-Host "Copied $n files."
    }

    # --- patch the copy
    $dstPk3 = Join-Path $Destination 'baseq3\bin.pk3'
    $dllHash = $null
    if ($PSCmdlet.ShouldProcess($dstPk3, 'Patch cgamex86.dll (16:9 FOV constant) inside the copy')) {
        $dllHash = Write-PatchedPk3 -Pk3Path $dstPk3 -Width $Width -Height $Height
        if ($dllHash -ne $expectedDll) { throw "Patched DLL hash $dllHash does not match expected $expectedDll." }
        Write-Host "Patched cgamex86.dll SHA-256 : $dllHash"
    }

    # --- per-user folders: stale DLLs + autoexec
    # In a dry run the copy does not exist yet, so inspect the source to predict the copy's layout.
    $layoutRoot = if (Test-Path -LiteralPath (Join-Path $Destination 'baseq3')) { $Destination } else { $SourcePath }
    $relative = @()
    foreach ($f in (Get-UserConfigFolders -Root $layoutRoot)) { $relative += $f.Substring($layoutRoot.Length).TrimStart('\', '/') }
    if ($relative.Count -eq 0) {
        $relative += 'baseq3'
        Write-Host 'No per-user <steamid>\baseq3 folder found (game never launched?); writing autoexec.cfg to the copy''s baseq3 folder instead.' -ForegroundColor Yellow
    }
    foreach ($rel in $relative) {
        $t = Join-Path $Destination $rel
        $staleInLayout = Join-Path (Join-Path $layoutRoot $rel) $script:DllEntryName
        if (($rel -ne 'baseq3') -and (Test-Path -LiteralPath $staleInLayout)) {
            $stale = Join-Path $t $script:DllEntryName
            if ($PSCmdlet.ShouldProcess($stale, 'Delete stale unpacked cgamex86.dll (the game re-extracts the patched one)')) {
                Remove-Item -LiteralPath $stale -Force
            }
        }
        $ae = Join-Path $t 'autoexec.cfg'
        if ($PSCmdlet.ShouldProcess($ae, "Write managed autoexec block ($Width x $Height, fullscreen, sv_pure 0)")) {
            Set-AutoexecBlock -Path $ae -Width $Width -Height $Height
        }
    }

    # --- marker (used by the uninstaller as a safety check)
    $marker = Join-Path $Destination $script:MarkerFileName
    if ($PSCmdlet.ShouldProcess($marker, 'Write install marker')) {
        $info = [ordered]@{
            tool = 'quake-live-ultrawide-fix'; createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            width = $Width; height = $Height; patchOffset = ('0x{0:X}' -f $script:PatchOffset)
            patchBytes = (Format-HexBytes $patchBytes); originalDllSha256 = $script:OriginalDllSha256
            patchedDllSha256 = $dllHash; sourceBinPk3Sha256 = $srcPk3Hash
        }
        ($info | ConvertTo-Json) | Set-Content -LiteralPath $marker -Encoding ASCII
    }

    # --- shortcut
    if (-not $NoShortcut) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop ($ShortcutName + '.lnk')
        if ($PSCmdlet.ShouldProcess($lnk, 'Create desktop shortcut')) {
            try {
                $ws = New-Object -ComObject WScript.Shell
                $sc = $ws.CreateShortcut($lnk)
                $sc.TargetPath = Join-Path $Destination 'quakelive_steam.exe'
                $sc.WorkingDirectory = $Destination
                $sc.IconLocation = (Join-Path $Destination 'quakelive_steam.exe') + ',0'
                $sc.Description = 'Patched ultrawide Quake Live copy - launch ONLY with Steam in Offline Mode'
                $sc.Save()
                Write-Host "Shortcut     : $lnk"
            } catch { Write-Warning "Could not create the shortcut: $($_.Exception.Message)" }
        }
    }

    # --- summary
    Write-Host ''
    if ($WhatIfPreference) {
        Write-Host 'Dry run complete. Nothing was written.' -ForegroundColor Green
    } else {
        $after = (Get-FileHash -LiteralPath $srcPk3 -Algorithm SHA256).Hash
        Write-Host "Source bin.pk3 after install : $after (unchanged: $($after -eq $srcPk3Hash))"
        Write-Host "Copy bin.pk3 SHA-256         : $((Get-FileHash -LiteralPath $dstPk3 -Algorithm SHA256).Hash)"
        Write-Host 'Done.' -ForegroundColor Green
    }
    Write-Host 'REMINDER: switch Steam to Offline Mode (Steam > Go Offline...) BEFORE launching the patched copy.' -ForegroundColor Yellow
    Write-Host '          Never run it while Steam is online and never join online servers with it.' -ForegroundColor Yellow
}

Invoke-Install
