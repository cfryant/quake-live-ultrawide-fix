<#
.SYNOPSIS
    Removes a patched Quake Live copy created by Install-UltrawideFix.ps1 and its
    desktop shortcut. Never touches the Steam install.

.PARAMETER Destination
    The patched copy folder. Prompted for if omitted.

.PARAMETER ShortcutName
    Desktop shortcut name. Default: 'Quake Live (Ultrawide, Offline)'.
    The shortcut is removed only if it points into -Destination.

.PARAMETER Force
    Skip the confirmation prompt. Does NOT bypass the safety checks.

.EXAMPLE
    .\Uninstall-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Destination,
    [string]$ShortcutName = 'Quake Live (Ultrawide, Offline)',
    [switch]$Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$MarkerFileName = 'ultrawide-fix.json'

function Get-FullPathNormalized { param([string]$Path) return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/') }

function Test-PathIsUnder {
    param([string]$Child, [string]$Parent)
    $c = (Get-FullPathNormalized $Child) + [System.IO.Path]::DirectorySeparatorChar
    $p = (Get-FullPathNormalized $Parent) + [System.IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SteamLibraries {
    $libs = @()
    $root = $null
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in 'SteamPath', 'InstallPath') {
                if (-not $root -and $props.PSObject.Properties[$name] -and $props.$name -and (Test-Path -LiteralPath ($props.$name -replace '/', '\'))) { $root = $props.$name -replace '/', '\' }
            }
        } catch { }
    }
    if (-not $root) { return , $libs }
    $libs += (Get-FullPathNormalized $root)
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\' -replace '/', '\'
            if (Test-Path -LiteralPath $p) { $libs += (Get-FullPathNormalized $p) }
        }
    }
    return , $libs
}

function Invoke-Uninstall {
    if (-not $Destination) { $Destination = Read-Host 'Patched copy folder to remove' }
    if (-not $Destination) { throw 'No destination given.' }
    $Destination = Get-FullPathNormalized $Destination
    if (-not (Test-Path -LiteralPath $Destination)) { throw "Folder not found: $Destination" }

    if (Get-Process -Name 'quakelive_steam' -ErrorAction SilentlyContinue) { throw 'Quake Live is running. Close it first.' }

    # Safety: never remove anything inside a Steam library, and only remove folders created by the installer.
    foreach ($lib in (Get-SteamLibraries)) {
        if ((Test-PathIsUnder -Child $Destination -Parent $lib) -or (Test-PathIsUnder -Child $lib -Parent $Destination)) {
            throw "Refusing: $Destination overlaps the Steam library $lib. The Steam install is never touched by this tool."
        }
    }
    $marker = Join-Path $Destination $MarkerFileName
    if (-not (Test-Path -LiteralPath $marker)) {
        throw "Refusing: $Destination has no $MarkerFileName, so it was not created by Install-UltrawideFix.ps1."
    }
    $info = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($info.tool -ne 'quake-live-ultrawide-fix') { throw "Refusing: $marker is not an install marker from this tool." }
    $files = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force)
    $size = ($files | Measure-Object Length -Sum).Sum
    Write-Host ("Patched copy : {0} ({1} files, {2:N2} GB, {3}x{4}, created {5})" -f $Destination, $files.Count, ($size / 1GB), $info.width, $info.height, $info.createdUtc)

    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop ($ShortcutName + '.lnk')
    $removeLnk = $false
    if (Test-Path -LiteralPath $lnk) {
        try {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
            if ($target -and (Test-PathIsUnder -Child $target -Parent $Destination)) { $removeLnk = $true; Write-Host "Shortcut     : $lnk -> $target" }
            else { Write-Host "Shortcut $lnk points elsewhere ($target); it will be left alone." }
        } catch { Write-Warning "Could not read shortcut $lnk; it will be left alone." }
    }

    if (-not $WhatIfPreference -and -not $Force) {
        $answer = Read-Host 'Permanently delete this patched copy (and its shortcut)? Type Y to continue'
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
    }
    if ($PSCmdlet.ShouldProcess($Destination, 'Delete patched Quake Live copy')) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
        Write-Host "Removed $Destination"
    }
    if ($removeLnk -and $PSCmdlet.ShouldProcess($lnk, 'Delete desktop shortcut')) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "Removed $lnk"
    }
    Write-Host 'Done. The Steam install was not touched.' -ForegroundColor Green
}

Invoke-Uninstall
