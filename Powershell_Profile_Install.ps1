#requires -Version 5.1
<#
PS1nstaller - PowerShell profile/bootstrap installer
Version: 2.6.1
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
        'Skip' { 'DarkYellow' }
        'Ok'   { 'Green' }
        'Warn' { 'Yellow' }
        'Err'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
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
    if ($PSVersionTable.PSEdition -eq 'Core') { return (Get-Command pwsh -ErrorAction Stop).Source }
    return (Get-Command powershell.exe -ErrorAction Stop).Source
}

function Ensure-Directory ([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Download-File ($Uri, $OutFile) {
    Ensure-Tls12
    $retryCount = 0
    while ($retryCount -lt 3) {
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
            }
            return
        } catch {
            $retryCount++
            Write-Status "  [WARN] Download failed, retrying ($retryCount/3)..." 'Warn'
            Start-Sleep -Seconds 2
        }
    }
    throw "Failed to download $Uri after 3 attempts."
}

function Command-Exists ($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-ExecutionPolicyRemoteSigned {
    if ((Get-ExecutionPolicy -Scope CurrentUser) -ne 'RemoteSigned') {
        Write-Status "  [SETTING] ExecutionPolicy(CurrentUser) -> RemoteSigned" 'Warn'
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force | Out-Null
    } else {
        Write-Status "  [SKIP] ExecutionPolicy already RemoteSigned" 'Skip'
    }
}

# ---------------------------
# Scoop & Packages
# ---------------------------

function Ensure-Scoop {
    if (Command-Exists scoop) {
        Write-Status "  [SKIP] Scoop already installed" 'Skip'
        return
    }
    Write-Status "  [INSTALL] Installing Scoop..." 'Info'
    Ensure-Tls12
    iex "& {$(irm get.scoop.sh)} -RunAsAdmin"
}

function Ensure-ScoopBucket ($Name) {
    $buckets = scoop bucket list 2>$null | Out-String
    if ($buckets -match $Name) {
        Write-Status "  [SKIP] Scoop bucket '$Name' already exists" 'Skip'
        return
    }
    Write-Status "  [ADD ] Adding Scoop bucket '$Name'..." 'Info'
    scoop bucket add $Name | Out-Null
}

function Ensure-ScoopApp ($Name) {
    $installed = scoop list 2>$null | Out-String
    if ($installed -match $Name) {
        Write-Status "  [SKIP] Scoop app '$Name' already installed" 'Skip'
        return
    }
    Write-Status "  [INST] Installing Scoop app '$Name'..." 'Info'
    scoop install $Name | Out-Null
}

# ---------------------------
# Modules
# ---------------------------

function Ensure-PSModule ($Name) {
    if (-not (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Status "  [INST] Installing PowerShell module '$Name'..." 'Info'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module -Name $Name -Repository 'PSGallery' -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Status "  [SKIP] Module '$Name' already installed" 'Skip'
    }
}

# ---------------------------
# Profile & Themes
# ---------------------------

function Copy-ProfilePackTo ($SourceDir, $DestDir) {
    Ensure-Directory $DestDir
    $backupDir = Join-Path $DestDir ("Backup_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    
    Get-ChildItem -LiteralPath $SourceDir -File -Force | Where-Object { $_.Name -ne 'themes.zip' } | ForEach-Object {
        $target = Join-Path $DestDir $_.Name
        if (Test-Path -LiteralPath $target) {
            if ($OverwriteExisting) {
                Ensure-Directory $backupDir
                Copy-Item -LiteralPath $target -Destination $backupDir -Force
                Copy-Item -LiteralPath $_.FullName -Destination $DestDir -Force
            }
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $DestDir -Force
        }
    }
}

function Install-ProfilePack {
    $tempRoot = Join-Path $env:TEMP 'PSProfileTemp'
    $zipPath  = Join-Path $tempRoot 'PowerShellProfile.zip'
    $extract  = Join-Path $tempRoot 'PowerShellProfile'

    Ensure-Directory $tempRoot
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }

    $source = 'https://github.com/Ox1de-crypto/powerhell_x1/archive/refs/heads/main.zip'
    Write-Status "  [DL  ] Downloading profile pack..." 'Info'
    Download-File -Uri $source -OutFile $zipPath

    Write-Status "  [UNZ ] Extracting pack..." 'Info'
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    
    # Handle Themes
    $themesZip = Get-ChildItem -LiteralPath $root.FullName -Recurse -File -Filter 'themes.zip' | Select-Object -First 1
    if ($themesZip) {
        $themeTarget = 'C:\OhmyposhThemes'
        Ensure-Directory $themeTarget
        Write-Status "  [COPY] Extracting OhMyPosh themes to $themeTarget..." 'Info'
        Expand-Archive -Path $themesZip.FullName -DestinationPath $themeTarget -Force
    }

    # Handle Profiles (Local + PowerShell 7)
    $destWinPSLocal = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell'
    $destPwsh       = Join-Path $env:USERPROFILE 'Documents\PowerShell'

    Write-Status "  [COPY] Installing to Windows PowerShell & PowerShell 7 configs..." 'Info'
    Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destWinPSLocal
    Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destPwsh

    # OneDrive check
    $oneDrive = $env:OneDrive
    if ($oneDrive -and (Test-Path $oneDrive)) {
        $destOneDrive = Join-Path $oneDrive 'Documents\WindowsPowerShell'
        Copy-ProfilePackTo -SourceDir $root.FullName -DestDir $destOneDrive
    }

    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------
# Fonts
# ---------------------------

function Broadcast-FontChange {
    try {
        Add-Type -Namespace Win32 -Name FontBroadcast -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public class FontBroadcast {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@ -ErrorAction Stop
        $result = [IntPtr]::Zero
        [Win32.FontBroadcast]::SendMessageTimeout(0xffff, 0x001D, [IntPtr]0, [IntPtr]0, 0x0000, 1000, [ref]$result) | Out-Null
    } catch {}
}

function Install-NerdFontsSystemWide {
    if ($SkipFonts) { return }

    $tempRoot = Join-Path $env:TEMP 'NerdFontsTemp'
    Ensure-Directory $tempRoot

    # JetBrainsMono prioritized as requested
    $targetFonts = if ($Fonts) { $Fonts } else { @('JetBrainsMono', 'CascadiaCode', 'Meslo') }
    
    $shell = New-Object -ComObject Shell.Application
    $fontsFolder = $shell.Namespace(0x14)

    foreach ($font in $targetFonts) {
        $zipName = "$font.zip"
        $url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$zipName"
        $zipPath = Join-Path $tempRoot $zipName
        $extractDir = Join-Path $tempRoot $font

        try {
            Write-Status "  [DL  ] Downloading $font Nerd Font..." 'Info'
            Download-File -Uri $url -OutFile $zipPath
            
            Ensure-Directory $extractDir
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
            
            # STRICT FILTER: Only grab genuine font files, ignore README.md, LICENSE, etc.
            $fontFiles = Get-ChildItem -LiteralPath $extractDir -File -Recurse | Where-Object { $_.Extension -match '\.(ttf|otf)$' }
            
            foreach ($f in $fontFiles) {
                if (-not (Test-Path (Join-Path $env:WINDIR "Fonts\$($f.Name)"))) {
                    $fontsFolder.CopyHere($f.FullName, 0x14)
                }
            }
            Write-Status "  [OK  ] $font installed successfully." 'Ok'
        } catch {
            Write-Status ("  [WARN] Failed to install {0}: {1}" -f $font, $_.Exception.Message) 'Warn'
        }
    }
    Broadcast-FontChange
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------
# Elevation Check
# ---------------------------
if (-not (Test-IsAdmin)) {
    Write-Status "Elevating privileges..." 'Warn'
    Start-Process (Get-ThisShellPath) -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ---------------------------
# Main Routine
# ---------------------------
Clear-Host
Write-Host @"
                                  ___    __        
                       ____  _  _<  /___/ /__      
                      / __ \| |/_/ / __  / _ \     
                     / /_/ />  </ / /_/ /  __/     
                     \____/_/|_/_/\__,_/\___/     

[PS1nstaller v2.6.1]
"@ -ForegroundColor Cyan
Start-Sleep -Seconds 1

Invoke-Step "[10%] Execution policy check" { Ensure-ExecutionPolicyRemoteSigned }
Invoke-Step "[20%] Scoop base installation" { Ensure-Scoop } -NonFatal

if (-not $SkipScoopApps) {
    Invoke-Step "[30%] Scoop extras bucket" { Ensure-ScoopBucket 'extras' } -NonFatal
    Invoke-Step "[40%] Utilities (git, meow)" { 
        Ensure-ScoopApp 'git'
        Ensure-ScoopApp 'meow' 
    } -NonFatal
}

Invoke-Step "[60%] Terminal-Icons Module" { Ensure-PSModule 'Terminal-Icons' } -NonFatal

Invoke-Step "[70%] OhMyPosh engine (Scoop)" {
    if (-not $SkipOhMyPosh) { Ensure-ScoopApp 'oh-my-posh' }
} -NonFatal

Invoke-Step "[80%] Custom Profile & Themes" { Install-ProfilePack } -NonFatal
Invoke-Step "[90%] System-wide Nerd Fonts" { Install-NerdFontsSystemWide } -NonFatal

Write-Status "`n[100%] Bootstrap Complete. Please restart your terminal." 'Ok'
Write-Status "NOTE: Ensure your Windows Terminal settings.json uses 'JetBrainsMono NFM' as the fontFace to see icons." 'Warn'
