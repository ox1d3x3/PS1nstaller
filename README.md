# PS1nstaller (Ox1d3x3)

Windows PowerShell profile + terminal bootstrap installer.

This script sets up a consistent terminal experience on a fresh Windows machine by installing the tools you use (Scoop, Oh My Posh, Terminal-Icons), deploying your profile pack, extracting your `themes.zip`, and optionally installing Nerd Fonts **system-wide**.

---

## Features

- ✅ Sets **ExecutionPolicy (CurrentUser)** to `RemoteSigned`
- ✅ Installs **Scoop** (if missing) + adds the `extras` bucket
- ✅ Installs Scoop apps (e.g. **git**, **meow**) (idempotent)
- ✅ Installs/updates PowerShell module: **Terminal-Icons**
- ✅ Installs/updates **Oh My Posh** via `winget`
- ✅ Downloads your profile pack from this repo ZIP and deploys to:
  - `Documents\WindowsPowerShell` (PowerShell 5.1)
  - `Documents\PowerShell` (PowerShell 7 / pwsh)
- ✅ Extracts **themes.zip** to temp and copies to:
  - `C:\Users\<You>\themes` (i.e. `%USERPROFILE%\themes`)
- ✅ Optional: Installs Nerd Fonts **system-wide** to `C:\Windows\Fonts`

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1+ (works with PowerShell 7 / pwsh too)
- Internet access (GitHub downloads)
- **Administrator** access recommended (required for system-wide font install)

> On locked-down org devices, some steps (Scoop, winget, font install) may be blocked by policy.

---

## Quick start (Recommended)

Open **Windows Terminal / PowerShell as Administrator**, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Powershell_Profile_Install.ps1
```

### Update / overwrite existing configs (backs up first)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Powershell_Profile_Install.ps1 -OverwriteExisting
```

---

## Optional flags

| Flag | What it does |
|------|--------------|
| `-OverwriteExisting` | Overwrites existing profile/theme files (creates a timestamped backup first) |
| `-SkipFonts` | Skips Nerd Fonts install |
| `-AllNerdFonts` | Installs **all** Nerd Fonts (large download; slower) |
| `-SkipOhMyPosh` | Skips Oh My Posh install/upgrade |
| `-SkipScoopApps` | Skips Scoop app/bucket installs |

Examples:

```powershell
# Skip fonts
powershell -NoProfile -ExecutionPolicy Bypass -File .\Powershell_Profile_Install.ps1 -SkipFonts
```

```powershell
# Install all Nerd Fonts (big)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Powershell_Profile_Install.ps1 -AllNerdFonts
```

---

## After install

Close and reopen your terminal so PATH/profile changes apply.

---

## Verify everything

### Oh My Posh

```powershell
Get-Command oh-my-posh
oh-my-posh version
```

### Profile file being loaded

```powershell
$PSVersionTable.PSEdition
$PROFILE
Test-Path $PROFILE
```

### Terminal-Icons module

```powershell
Get-Module -ListAvailable Terminal-Icons
```

### Scoop

```powershell
scoop --version
scoop bucket list
scoop list
```

### Themes folder

```powershell
Test-Path "$env:USERPROFILE\themes"
Get-ChildItem "$env:USERPROFILE\themes" | Select-Object -First 10
```

### Fonts (system-wide)

```powershell
Get-ChildItem "C:\Windows\Fonts" | Where-Object Name -match "JetBrains|Cascadia|Nerd"
```

---

## Common fixes

### Oh My Posh theme not loading

Usually caused by running **pwsh (PowerShell 7)** while your init line is in the wrong profile folder.

Check:

```powershell
$PSVersionTable.PSEdition
$PROFILE
Get-Command oh-my-posh -ErrorAction SilentlyContinue
```

Open your current profile file:

```powershell
notepad $PROFILE
```

Ensure your init line exists. Example (pwsh):

```powershell
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config "$env:USERPROFILE\themes\YOUR_THEME.omp.json" | Invoke-Expression
}
```

Reload:

```powershell
. $PROFILE
```

> Replace `YOUR_THEME.omp.json` with your theme file inside `%USERPROFILE%\themes`.

---

### Icons look broken / squares

That’s a terminal font issue (not Oh My Posh).

In **Windows Terminal**:
- **Settings → Profiles → (Your profile) → Appearance → Font face**
- Pick a Nerd Font, e.g. **JetBrainsMono Nerd Font** or **CaskaydiaCove Nerd Font**

Restart terminal.

---

### winget missing

Install/repair **App Installer** (Microsoft Store), then rerun the script.

---

### Scoop blocked on org devices

Some org policies block script downloads or installing packages. If Scoop fails:
- Try running without Scoop steps: `-SkipScoopApps`
- Or ask IT to allow Scoop/GitHub access

---

## File locations

- PowerShell 5.1 profiles:
  - `C:\Users\<You>\Documents\WindowsPowerShell\`
- PowerShell 7 (pwsh) profiles:
  - `C:\Users\<You>\Documents\PowerShell\`
- Themes:
  - `C:\Users\<You>\themes`
- Fonts (system-wide):
  - `C:\Windows\Fonts`

---

## Notes

- Using `-OverwriteExisting` creates a timestamped backup inside the destination folder(s) before replacing files.
- Installing **all** Nerd Fonts can take time and bandwidth. Default mode installs the most commonly used terminal fonts first.

---
