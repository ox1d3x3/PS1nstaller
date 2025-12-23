#requires -Version 5.1
<#
PS1nstaller - PowerShell profile/bootstrap installer
Author: Ox1d3x3
Version: 2.5.6

Fixes in 2.5.1:
- Copies profile pack to BOTH:
  - Documents\WindowsPowerShell (Windows PowerShell 5.1)
  - Documents\PowerShell (PowerShell 7 / pwsh)
  This fixes "Oh My Posh theme not working" when your terminal uses pwsh.
- Hardened Scoop bucket detection (handles string + object output)
- Fully automated Nerd Fonts install (system-wide) for a default set.
  Use -AllNerdFonts to install the full Nerd Fonts collection (very large).

Fixes in 2.5.4:
- Detects OneDrive (if installed + path available) and ALSO copies the WindowsPowerShell profile pack to:
  - %OneDrive%\Documents\WindowsPowerShell
  while still copying to the local Documents\WindowsPowerShell.

Run:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\PS1nstaller.ps1

Optional:
  -OverwriteExisting        Overwrite existing profile files (backs up first)
  -SkipFonts               Skip fonts install
  -AllNerdFonts            Install full Nerd Fonts collection (HUGE)
  -Fonts                   Install only specific Nerd Fonts (e.g. -Fonts CascadiaCode,JetBrainsMono)
  -SkipOhMyPosh            Skip winget OhMyPosh step
  -SkipScoopApps           Skip installing Scoop apps/buckets
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$OverwriteExisting,
    [switch]$SkipFonts,
    [switch]$AllNerdFonts,
    [string[]]$Fonts,
    [switch]$SkipOhMyPosh,
    [switch]$SkipScoopApps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------
# Helpers
# ---------------------------

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Step','Info','Skip','Ok','Warn','Err')][string]$Level = 'Info'
    )
    $color = switch ($Level) {
        'Step' { 'Cyan' }
        'Info' { 'Gray' }
        'Skip' { 'Yellow' }
        'Ok'   { 'Green' }
        'Warn' { 'Yellow' }
        'Err'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Ensure-Tls12 {
    try {
        # TLS 1.2 (3072) for older Windows/PS 5.1 HTTPS reliability
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    } catch { }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$NonFatal
    )
    Write-Status $Title 'Step'
    try {
        & $Action
        Write-Status "  [OK] $Title" 'Ok'
    } catch {
        Write-Status "  [FAIL] $Title" 'Err'
        Write-Status "  $($_.Exception.Message)" 'Err'
        if (-not $NonFatal) { throw }
    }
}

function Get-ThisShellPath {
    try {
        $cmd = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        return (Get-Command $cmd -ErrorAction Stop).Source
    } catch { return 'powershell.exe' }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Ensure-Tls12
    try {
        # Prefer BITS when possible (more resilient)
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
            return
        }
    } catch {
        # fallback below
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile
    }
}

function Command-Exists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-OneDriveInstalled {
    # Best-effort check: OneDrive.exe exists in common install locations
    $candidates = @()

    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) {
        $candidates += (Join-Path $pf86 'Microsoft OneDrive\OneDrive.exe')
    }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $true }
    }

    return $false
}

function Get-OneDriveRoot {
    # Prefer environment variables (handles OneDrive Personal + Business)
    $candidates = @(
        $env:OneDrive,
        $env:OneDriveConsumer,
        $env:OneDriveCommercial
    ) | Where-Object { $_ -and $_.Trim() }

    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    # Fallback to default folder name
    $fallback = Join-Path $env:USERPROFILE 'OneDrive'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    return $null
}


function Ensure-ExecutionPolicyRemoteSigned {
    $current = Get-ExecutionPolicy -Scope CurrentUser
    if ($current -ne 'RemoteSigned') {
        Write-Status "  [SETTING] ExecutionPolicy(CurrentUser) -> RemoteSigned" 'Warn'
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force | Out-Null
    } else {
        Write-Status "  [SKIP] ExecutionPolicy already RemoteSigned" 'Skip'
    }
}

# ---------------------------
# Scoop
# ---------------------------

function Ensure-Scoop {
    if (Command-Exists scoop) {
        Write-Status "  [SKIP] Scoop already installed" 'Skip'
        return
    }

    Write-Status "  [INSTALL] Installing Scoop..." 'Info'
    Ensure-Tls12

    # Official installer
    iex "& {$(irm get.scoop.sh)} -RunAsAdmin"
}

function Ensure-ScoopBucket {
    param([Parameter(Mandatory)][string]$Name)

    $raw = & scoop bucket list 2>$null

    $buckets = foreach ($b in $raw) {
        if ($null -eq $b) { continue }

        if ($b -is [string]) {
            $s = $b.Trim()
            if ($s) { $s }
            continue
        }

        $nameProp = $b.PSObject.Properties['Name']
        if ($nameProp) {
            $n = [string]$nameProp.Value
            if ($n) { $n }
            continue
        }

        $s2 = ([string]$b).Trim()
        if ($s2) { $s2 }
    }

    if ($buckets -contains $Name) {
        Write-Status "  [SKIP] Scoop bucket '$Name' already exists" 'Skip'
        return
    }

    Write-Status "  [ADD ] Adding Scoop bucket '$Name'..." 'Info'
    & scoop bucket add $Name | Out-Null
}

function Ensure-ScoopApp {
    param([Parameter(Mandatory)][string]$Name)

    & scoop which $Name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Status "  [SKIP] Scoop app '$Name' already installed" 'Skip'
        return
    }

    Write-Status "  [INST] Installing Scoop app '$Name'..." 'Info'
    & scoop install $Name | Out-Null
}

# ---------------------------
# Modules & Apps
# ---------------------------

function Ensure-PSModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Repository = 'PSGallery'
    )

    $exists = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue
    if (-not $exists) {
        Write-Status "  [INST] Installing PowerShell module '$Name'..." 'Info'
        try { Set-PSRepository -Name $Repository -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module -Name $Name -Repository $Repository -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Status "  [UPDT] Updating PowerShell module '$Name' (if needed)..." 'Info'
        try {
            Update-Module -Name $Name -Scope CurrentUser -Force -ErrorAction Stop
        } catch {
            Write-Status "  [SKIP] Module '$Name' already up-to-date (or update not required)" 'Skip'
        }
    }
}

function Ensure-OhMyPosh {
    if ($SkipOhMyPosh) {
        Write-Status "  [SKIP] Skipping OhMyPosh step (flag set)" 'Skip'
        return
    }

    if (-not (Command-Exists winget)) {
        Write-Status "  [SKIP] winget not found. Skipping OhMyPosh." 'Skip'
        return
    }

    $id = 'JanDeDobbeleer.OhMyPosh'
    $list = & winget list --id $id -e 2>$null
    $isInstalled = ($list | Select-String -SimpleMatch $id) -ne $null

    if (-not $isInstalled) {
        Write-Status "  [INST] Installing OhMyPosh via winget..." 'Info'
        & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    } else {
        Write-Status "  [UPDT] Upgrading OhMyPosh via winget (if available)..." 'Info'
        & winget upgrade --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    }

    Write-Status "  [INFO ] If 'oh-my-posh' isn't recognized yet, restart the terminal (PATH refresh)." 'Warn'
}

# ---------------------------
# Profile pack install (fixes theme not loading in pwsh)
# ---------------------------

function Copy-ProfilePackTo {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir
    )

    Ensure-Directory $DestDir

    $backupDir = Join-Path $DestDir ("Backup_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($OverwriteExisting) {
        Ensure-Directory $backupDir
        Write-Status "  [BACK] Backing up existing files -> $backupDir" 'Warn'
    }

    Get-ChildItem -LiteralPath $SourceDir -File -Force |
        Where-Object { $_.Name -ne 'themes.zip' } |
        ForEach-Object {
        $target = Join-Path $DestDir $_.Name

        if (Test-Path -LiteralPath $target) {
            if ($OverwriteExisting) {
                Copy-Item -LiteralPath $target -Destination $backupDir -Force
                Copy-Item -LiteralPath $_.FullName -Destination $DestDir -Force
                Write-Status "  [OVRW] $($_.Name) -> $DestDir" 'Warn'
            } else {
                Write-Status "  [SKIP] $($_.Name) exists in $DestDir" 'Skip'
            }
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $DestDir -Force
            Write-Status "  [COPY] $($_.Name) -> $DestDir" 'Ok'
        }
    }
}

function Install-ProfilePack {
    $tempRoot = 'C:\Temp'
    $zipPath  = Join-Path $tempRoot 'PowerShellProfile.zip'
    $extract  = Join-Path $tempRoot 'PowerShellProfile'

    Ensure-Directory $tempRoot
    if (Test-Path -LiteralPath $extract) {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $source = 'https://github.com/Ox1de-crypto/powerhell_x1/archive/refs/heads/main.zip'
    Write-Status "  [DL  ] Downloading profile pack..." 'Info'
    Download-File -Uri $source -OutFile $zipPath

    Write-Status "  [UNZ ] Extracting pack..." 'Info'
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $root) { throw "Could not find extracted profile folder under $extract" }
    # If the repo contains a themes.zip, extract it to temp and copy it to a universal folder: C:\OhmyposhThemes
    $themesZip = Get-ChildItem -LiteralPath $root.FullName -Recurse -File -Filter 'themes.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($themesZip) {
        $tempThemes = Join-Path $tempRoot 'OhMyPoshThemes_Temp'
        if (Test-Path -LiteralPath $tempThemes) {
            Remove-Item -LiteralPath $tempThemes -Recurse -Force -ErrorAction SilentlyContinue
        }
        Ensure-Directory $tempThemes

        Write-Status "  [UNZ ] Extracting themes.zip..." 'Info'
        Expand-Archive -Path $themesZip.FullName -DestinationPath $tempThemes -Force

        $themeTarget = 'C:\OhmyposhThemes'
        Ensure-Directory $themeTarget

        if ($OverwriteExisting) {
            $backup = "C:\OhmyposhThemes_Backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
            Ensure-Directory $backup

            $existing = Get-ChildItem -LiteralPath $themeTarget -Force -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Status "  [BACK] Backing up existing themes -> $backup" 'Warn'
                Copy-Item -Path (Join-Path $themeTarget '*') -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path (Join-Path $themeTarget '*') -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Status "  [COPY] Installing themes to $themeTarget (overwrite)..." 'Info'
            Copy-Item -Path (Join-Path $tempThemes '*') -Destination $themeTarget -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Status "  [COPY] Installing themes to $themeTarget (skip existing)..." 'Info'
            $srcFiles = Get-ChildItem -LiteralPath $tempThemes -File -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($sf in $srcFiles) {
                $rel = $sf.FullName.Substring($tempThemes.Length).TrimStart('\')
                $dest = Join-Path $themeTarget $rel
                $destDir = Split-Path -Parent $dest
                Ensure-Directory $destDir

                if (Test-Path -LiteralPath $dest) {
                    Write-Status "  [SKIP] Theme exists: $rel" 'Skip'
                } else {
                    Copy-Item -LiteralPath $sf.FullName -Destination $dest -Force
                    Write-Status "  [COPY] Theme: $rel" 'Ok'
                }
            }
        }

        Remove-Item -LiteralPath $tempThemes -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "  [OK  ] Themes available at: C:\OhmyposhThemes" 'Ok'
    } else {
        Write-Status "  [SKIP] themes.zip not found in profile pack" 'Skip'
    }



    # Install to BOTH profile locations so it works whether you launch pwsh or Windows PowerShell
    $destWinPSLocal = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell'
    $destPwsh       = Join-Path $env:USERPROFILE 'Documents\PowerShell'

    Write-Status "  [COPY] Installing pack to Windows PowerShell profile dir (local Documents)..." 'Info'
    Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destWinPSLocal

    # If OneDrive is installed + path is available, also copy to OneDrive\Documents\WindowsPowerShell
    if (Test-OneDriveInstalled) {
        $oneDriveRoot = Get-OneDriveRoot
        if ($oneDriveRoot) {
            $oneDriveDocs = Join-Path $oneDriveRoot 'Documents'
            if (Test-Path -LiteralPath $oneDriveDocs) {
                $destWinPSOneDrive = Join-Path $oneDriveDocs 'WindowsPowerShell'
                Write-Status "  [COPY] Installing pack to Windows PowerShell profile dir (OneDrive Documents)..." 'Info'
                Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destWinPSOneDrive
            } else {
                Write-Status "  [SKIP] OneDrive detected but '$oneDriveDocs' not found. Skipping OneDrive copy." 'Skip'
            }
        } else {
            Write-Status "  [SKIP] OneDrive installed but OneDrive root path not found. Skipping OneDrive copy." 'Skip'
        }
    } else {
        Write-Status "  [SKIP] OneDrive not detected. Skipping OneDrive Documents copy." 'Skip'
    }

    Write-Status "  [COPY] Installing pack to PowerShell 7 (pwsh) profile dir..." 'Info'
    Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destPwsh

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Write-Status "  [INFO ] Your active profile path depends on the shell:" 'Info'
    Write-Status "         - Windows PowerShell 5.1 (local):   $destWinPSLocal
         - Windows PowerShell 5.1 (OneDrive): <OneDrive>\Documents\WindowsPowerShell (if present)" 'Info'
    Write-Status "         - PowerShell 7 (pwsh):     $destPwsh" 'Info'
}

# ---------------------------
# Nerd Fonts - system-wide install
# ---------------------------

function Broadcast-FontChange {
    try {
        Add-Type -Namespace Win32 -Name FontBroadcast -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public class FontBroadcast {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@ -ErrorAction Stop

        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_FONTCHANGE  = 0x001D
        $SMTO_NORMAL    = 0x0000
        $result         = [IntPtr]::Zero
        [Win32.FontBroadcast]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]0, [IntPtr]0, $SMTO_NORMAL, 1000, [ref]$result) | Out-Null
    } catch {
        # Ignore; fonts will still appear after logoff/reboot if broadcast fails.
    }
}

function Install-FontFileSystemWide {
    param([Parameter(Mandatory)][string]$FontPath)

    if (-not (Test-Path -LiteralPath $FontPath)) { return }

    $fontsDir = Join-Path $env:WINDIR 'Fonts'
    $fileName = [IO.Path]::GetFileName($FontPath)
    $destPath = Join-Path $fontsDir $fileName

    if (Test-Path -LiteralPath $destPath) {
        return
    }

    # Use the Fonts shell folder for proper registration
    $shell = New-Object -ComObject Shell.Application
    $fonts = $shell.Namespace(0x14) # Fonts folder

    # 0x14 = 20 (No UI + Yes to All)
    $fonts.CopyHere($FontPath, 0x14)

    # Give the shell a moment to complete
    Start-Sleep -Milliseconds 150
}

function Get-NerdFontsLatestReleaseAssets {
    Ensure-Tls12
    $headers = @{ 'User-Agent' = 'PS1nstaller' }
    $api = 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest'
    $rel = Invoke-RestMethod -Uri $api -Headers $headers -ErrorAction Stop
    return $rel.assets
}

function Install-NerdFontsSystemWide {
    if ($SkipFonts) {
        Write-Status "  [SKIP] Skipping fonts step (flag set)" 'Skip'
        return
    }

    $tempRoot = Join-Path $env:TEMP 'PS1nstaller_NerdFonts'
    Ensure-Directory $tempRoot

    # Default set (recommended for terminals + icons)
    $defaultFonts = @('CascadiaCode','JetBrainsMono','Meslo','NerdFontsSymbolsOnly')

    $targetFonts = @()
    if ($AllNerdFonts) {
        Write-Status "  [FONTS] Full Nerd Fonts collection requested (very large)..." 'Warn'
        $assets = Get-NerdFontsLatestReleaseAssets
        $targetFonts = $assets |
            Where-Object { $_.name -like '*.zip' -and $_.name -notlike '*Windows*' } |
            Select-Object -ExpandProperty name
    } elseif ($Fonts -and $Fonts.Count -gt 0) {
        $targetFonts = $Fonts | ForEach-Object { "$_.zip" }
    } else {
        $targetFonts = $defaultFonts | ForEach-Object { "$_.zip" }
    }

    Write-Status "  [FONTS] Installing Nerd Fonts system-wide (C:\Windows\Fonts)..." 'Info'
    Write-Status "  [INFO ] Font packages: $($targetFonts.Count)" 'Info'

    $installedCount = 0
    $failedPackages = New-Object System.Collections.Generic.List[string]

    foreach ($zipName in $targetFonts) {
        try {
            $zipPath = Join-Path $tempRoot $zipName
            $pkgName = $zipName

            # Download URL: latest/download supports per-asset direct download
            $url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$zipName"

            Write-Status "  [DL  ] $pkgName" 'Info'
            Download-File -Uri $url -OutFile $zipPath

            $extractDir = Join-Path $tempRoot ([IO.Path]::GetFileNameWithoutExtension($zipName))
            if (Test-Path -LiteralPath $extractDir) {
                Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Ensure-Directory $extractDir

            Write-Status "  [UNZ ] $pkgName" 'Info'
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

            # Install every .ttf/.otf
            $fontFiles = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Include *.ttf,*.otf -ErrorAction SilentlyContinue
            foreach ($f in $fontFiles) {
                Install-FontFileSystemWide -FontPath $f.FullName
            }

            $installedCount++
        } catch {
            $failedPackages.Add($zipName) | Out-Null
            Write-Status ("  [WARN] Failed font package {0}: {1}" -f $zipName, $_.Exception.Message) 'Warn'
        }
    }

    Broadcast-FontChange

    Write-Status "  [OK  ] Font packages processed: $installedCount / $($targetFonts.Count)" 'Ok'
    if ($failedPackages.Count -gt 0) {
        Write-Status "  [WARN] Some font packages failed (network/policy). Re-run to retry:" 'Warn'
        Write-Status "         $($failedPackages -join ', ')" 'Warn'
    } else {
        Write-Status "  [OK  ] Fonts installed. Restart your terminal/apps if icons don't show immediately." 'Ok'
    }

    # Cleanup
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------
# Banner
# ---------------------------

function Show-Banner {
    Write-Host ""
    Write-Host "                                  ___    __        "
    Write-Host "                       ____  _  _<  /___/ /__      "
    Write-Host "                      / __ \| |/_/ / __  / _ \     "
    Write-Host "                     / /_/ />  </ / /_/ /  __/     "
    Write-Host "                     \____/_/|_/_/\__,_/\___/     "
    Write-Host ""
    Write-Status "[PS1nstaller]" 'Ok'
    Write-Status "[Version 2.5.6]" 'Warn'
    Write-Host ""
}

# ---------------------------
# Elevation
# ---------------------------

if (-not (Test-IsAdmin)) {
    Add-Type -AssemblyName System.Windows.Forms
    $msg = "This script must be run as an Administrator.`n`nDo you want to relaunch it as Admin?"
    $title = "Run as Administrator"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $msg, $title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $shell = Get-ThisShellPath
        Start-Process -FilePath $shell -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File', $PSCommandPath
        ) -Verb RunAs | Out-Null
        exit 0
    }

    Write-Status "Sorry, can't run without privileges. Bye!" 'Err'
    Start-Sleep -Seconds 3
    exit 1
}

# ---------------------------
# Main
# ---------------------------

Show-Banner
Write-Status "Wait till process starts..." 'Info'
Start-Sleep -Seconds 1

Invoke-Step -Title "[10% ][Execution policy check]" -Action { Ensure-ExecutionPolicyRemoteSigned }

Invoke-Step -Title "[20% ][Scoop install/check]" -Action { Ensure-Scoop } -NonFatal

if (-not $SkipScoopApps -and (Command-Exists scoop)) {
    Invoke-Step -Title "[30% ][Scoop bucket: extras]" -Action { Ensure-ScoopBucket -Name 'extras' } -NonFatal
    Invoke-Step -Title "[40% ][Scoop app: git]" -Action { Ensure-ScoopApp -Name 'git' } -NonFatal
    Invoke-Step -Title "[50% ][Scoop app: meow]" -Action { Ensure-ScoopApp -Name 'meow' } -NonFatal
} else {
    Write-Status "[SKIP] Scoop apps/bucket step skipped" 'Skip'
}

Invoke-Step -Title "[70% ][PowerShell module: Terminal-Icons]" -Action { Ensure-PSModule -Name 'Terminal-Icons' } -NonFatal

Invoke-Step -Title "[80% ][OhMyPosh (winget)]" -Action { Ensure-OhMyPosh } -NonFatal

Invoke-Step -Title "[90% ][Download + install profile pack]" -Action { Install-ProfilePack } -NonFatal

Invoke-Step -Title "[95% ][Install Nerd Fonts system-wide]" -Action { Install-NerdFontsSystemWide } -NonFatal

Write-Status "[100%][All tasks completed]" 'Ok'

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.MessageBox]::Show("ALL TASKS COMPLETED!", "PS1nstaller")
} catch { }