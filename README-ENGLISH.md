# Windows Hardening Scripts: BitLocker (TPM+PIN) & Logon Legal Notice

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows](https://img.shields.io/badge/Windows-10%2F11%20%7C%20Server-0078D6?logo=windows)
![BitLocker](https://img.shields.io/badge/BitLocker-TPM%2BPIN-green)
![TPM Required](https://img.shields.io/badge/TPM-Required-yellow)
![Security](https://img.shields.io/badge/Security-Hardening-important)
[![Licence GPLv3](https://img.shields.io/badge/Licence-GPLv3-yellow)](LICENSE)
![MadeInFrance](https://img.shields.io/badge/Made_in-🟦⬜🟥-ffffff)

A pair of production‑ready PowerShell scripts for enterprise Windows environments:

- **`Manage-BitLocker.ps1`** — Enables BitLocker on the OS volume with **pre‑boot PIN (TPM+PIN)**, backs up the **recovery key**, and lets you **suspend/resume/disable** protection via a single `-Action` parameter.
- **`Set-LogonWarning.ps1`** — Configures a **legal notice banner** shown **before authentication** (sign‑in / unlock). Can also remove it.

> **Heads‑up:** Run in an **elevated PowerShell**. A restart is required for the BitLocker pre‑boot PIN prompt to appear.

---

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Script 1: Manage-BitLocker.ps1](#script-1-manage-bitlockerps1)
  - [What it does](#what-it-does)
  - [Parameters](#parameters)
  - [Usage Examples](#usage-examples)
  - [Notes & Best Practices](#notes--best-practices)
- [Script 2: Set-LogonWarning.ps1](#script-2-set-logonwarningps1)
  - [What it does](#what-it-does-1)
  - [Parameters](#parameters-1)
  - [Usage Examples](#usage-examples-1)
  - [Notes](#notes)
- [Troubleshooting](#troubleshooting)
- [Security & Compliance](#security--compliance)
- [Deployment (Intune / GPO)](#deployment-intune--gpo)
- [Contributing](#contributing)
- [License](#license)

---

## Overview
These scripts aim to standardize workstation/server hardening:

- **BitLocker with TPM+PIN** provides pre‑boot authentication to protect OS volumes.
- **Legal notice banners** communicate acceptable use and deter unauthorized access at sign‑in/unlock time.

Both scripts are silent‑friendly and designed to be deployed at scale (Intune, GPO, or any RMM).

---

## Prerequisites
- Run **PowerShell as Administrator**.
- Windows **10/11 Pro/Enterprise/Education** or **Windows Server** with the **BitLocker** feature available.
- (Optional) Allow script execution for the current process:
  ```powershell
  Set-ExecutionPolicy RemoteSigned -Scope Process
  ```

---

## Script 1: `Manage-BitLocker.ps1`

### What it does
- Enables BitLocker on the OS volume (default `C:`) using a configurable **encryption method**.
- Adds a **TPM protector** + **pre‑boot PIN** (TPM+PIN) → the blue pre‑boot screen asking for a PIN.
- Ensures a **Recovery Password protector** exists.
- **Backs up** the recovery key locally (in `C:\Users\Public\Documents\BitLocker-RecoveryKeys`) and **optionally to Entra ID (Azure AD)** when supported.
- Supports **Disable (decrypt)**, **Suspend**, and **Resume** via the `-Action` parameter.

### Parameters
- `-Action <Enable|Disable|Suspend|Resume>` — default `Enable`.
- `-MountPoint <Drive:>` — target volume, default `C:`.
- `-EncryptionMethod <XtsAes128|XtsAes256|Aes128|Aes256>` — default `XtsAes256`.
- `-UsedSpaceOnly` — faster initial encryption (encrypt used space only).
- `-BackupRecoveryToAAD` — attempt to back up the key to **Entra ID (AAD)**.
- `-Quiet` — reduce console verbosity.

### Usage Examples
```powershell
# Enable BitLocker + pre-boot PIN, XTS-AES 256, encrypt used space only
./Manage-BitLocker.ps1 -Action Enable -MountPoint C: -EncryptionMethod XtsAes256 -UsedSpaceOnly

# Enable and back up the recovery key to Entra ID (if supported)
./Manage-BitLocker.ps1 -Action Enable -BackupRecoveryToAAD

# Temporarily suspend protection (e.g., before BIOS/firmware updates)
./Manage-BitLocker.ps1 -Action Suspend

# Resume protection
./Manage-BitLocker.ps1 -Action Resume

# Fully disable (decrypt) the volume
./Manage-BitLocker.ps1 -Action Disable
```

### Notes & Best Practices
- A **TPM** that is **present and ready** is required for TPM+PIN on OS volumes.
- Default PIN format is **numeric (4–20 digits)**. To allow **Enhanced PINs (alphanumeric)**, enable the corresponding GPO or registry setting, then adapt the script accordingly.
- A **restart is required** to receive the pre‑boot PIN prompt.
- Secure the **recovery key** in a vault (AAD/AD DS/MBAM/PAM solution).

---

## Script 2: `Set-LogonWarning.ps1`

### What it does
- Adds a **legal notice banner** (title + text) shown **before authentication** (sign‑in / unlock), by setting:
  - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeCaption`
  - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeText`
- Can **remove** the banner with `-Disable`.

### Parameters
- `-Title <string>` — banner title (default: *Security Warning*).
- `-Message <string>` — banner text (default: *Authorized use only…*).
- `-Disable` — removes the banner.

### Usage Examples
```powershell
# Add a banner
./Set-LogonWarning.ps1 `
  -Title "SECURITY WARNING" `
  -Message "This system is for authorized use only. Unauthorized access is prohibited. If you are not authorized, disconnect immediately."

# Remove the banner
./Set-LogonWarning.ps1 -Disable
```

### Notes
- Visible at **lock (Win+L)**, **sign‑in**, and **after restart**.
- Can be enforced centrally via **GPO**.
- Consider **localization** if devices are multilingual.

---

## Troubleshooting
- **"This script must be run as Administrator"** — reopen PowerShell **as Administrator**.
- **TPM not present/ready** — enable/initialize TPM in UEFI, then retry.
- **Banner not visible** — sign out or restart; verify `LegalNotice*` registry keys and competing GPOs.
- **AAD backup not available** — `BackupToAAD-BitLockerKeyProtector` is not present on all SKUs/versions.

---

## Security & Compliance
- Restrict access to the scripts and **log executions**.
- Protect **recovery keys** (encrypted storage, AAD/AD DS/MBAM, vault).
- Pilot first, then roll out broadly.

---

## Deployment (Intune / GPO)
**Intune**
- Deploy as a **PowerShell script** (64‑bit, run as admin) or package as a **Win32 app** with detection.
- Consider a **restart** after `Manage-BitLocker.ps1 -Action Enable`.

**GPO**
- Use **Startup Scripts (Computer)** or **Preferences > Registry** for the banner values.
- Apply BitLocker GPOs to enforce TPM+PIN if required.

---

## Contributing
PRs welcome. Please open an issue for bugs, ideas, or improvements. For major changes, discuss via an issue first.

---

## License
This project is released under the **MIT License**.


## Licence
This project is under **GNU General Public License v3.0** license type.  
Go to  `LICENSE` file for more details.

## Auteur
> Created by **Pierre CHAUSSARD** — https://github.com/PierreChrd
