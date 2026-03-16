<#
.SYNOPSIS
  Manages BitLocker on the OS volume with TPM+PIN pre-boot authentication.

.DESCRIPTION
  -Action Enable  : Enables BitLocker on the OS volume (default C:), adds TPM+PIN,
                    creates and saves a recovery key.
  -Action Disable : Decrypts the volume.
  -Action Suspend : Suspends BitLocker.
  -Action Resume  : Resumes BitLocker.

.NOTES
  Run this script in an elevated PowerShell session (Run as Administrator).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Enable","Disable","Suspend","Resume")]
    [string]$Action = "Enable",

    [ValidatePattern("^[A-Z]:$")]
    [string]$MountPoint = "C:",

    [ValidateSet("XtsAes128","XtsAes256","Aes128","Aes256")]
    [string]$EncryptionMethod = "XtsAes256",

    [switch]$UsedSpaceOnly,
    [switch]$BackupRecoveryToAAD,
    [switch]$Quiet
)

function Write-Info { param($m) if (-not $Quiet) { Write-Host "[INFO]  $m" -ForegroundColor Cyan } }
function Write-Warn { param($m) Write-Warning $m }
function Write-Err  { param($m) Write-Error $m }

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal]
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    if (-not $isAdmin) {
        Write-Err "This script must be run as Administrator."
        exit 1
    }
}

function Assert-BitLockerModule {
    if (-not (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Err "BitLocker PowerShell module is not available."
        exit 1
    }
}

function Get-OsVolume {
    return Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
}

function Assert-TPMReady {
    try { $tpm = Get-Tpm } catch {
        Write-Err "Unable to query TPM. Ensure TPM is enabled in BIOS/UEFI."
        exit 1
    }

    if (-not $tpm.TpmPresent) {
        Write-Err "TPM not detected. TPM+PIN requires a TPM chip."
        exit 1
    }
    if (-not $tpm.TpmReady) {
        Write-Err "TPM is present but not initialized."
        exit 1
    }

    Write-Info "TPM is present and ready."
}

function ConvertToPlain {
    param([SecureString]$Sec)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    return $plain
}

function Read-PinSecure {
    $pin1 = Read-Host "Enter BitLocker PIN (4-20 digits)" -AsSecureString
    $pin2 = Read-Host "Confirm PIN" -AsSecureString

    $p1 = ConvertToPlain -Sec $pin1
    $p2 = ConvertToPlain -Sec $pin2

    if ($p1 -ne $p2) { throw "PIN entries do not match." }

    if ($p1.Length -lt 4 -or $p1.Length -gt 20 -or ($p1 -notmatch "^[0-9]+$")) {
        throw "PIN must contain 4 to 20 numeric digits."
    }

    return $pin1
}

function Ensure-RecoveryProtector {
    param([string]$MountPoint)

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1

    if (-not $rec) {
        Write-Info "Adding Recovery Password protector..."
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector | Out-Null
    }
}

function Save-RecoveryKeyLocally {
    param([string]$MountPoint)

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1
    if (-not $rec) { return }

    $dir = Join-Path $env:PUBLIC "Documents\\BitLocker-RecoveryKeys"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $file = Join-Path $dir ("RecoveryKey_{0}_{1}.txt" -f $MountPoint.TrimEnd(':'), (Get-Date -Format "yyyyMMdd_HHmmss"))

    $data = @(
        "Drive        : $MountPoint"
        "Timestamp    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Protector ID : $($rec.KeyProtectorId)"
        "Recovery Key : $($rec.RecoveryPassword)"
    )

    $data | Out-File -FilePath $file -Encoding ASCII
    Write-Info "Recovery key saved to $file"
}

function Backup-RecoveryKey-ToAAD {
    param([string]$MountPoint)

    if (-not (Get-Command BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue)) {
        Write-Warn "AAD backup not supported on this system."
        return
    }

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1

    if ($rec) {
        Write-Info "Backing up recovery key to Entra ID (AAD)..."
        BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rec.KeyProtectorId
    }
}

function Set-BitLockerTpmPin {
    param(
        [string]$MountPoint,
        [SecureString]$Pin
    )

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $existingPin = $vol.KeyProtector | Where-Object KeyProtectorType -eq "TpmPin"

    if ($existingPin) {
        Write-Warn "A TPM+PIN protector already exists."

        $resp = Read-Host "Replace existing PIN? (Y/N)"
        if ($resp -notmatch "^[Yy]$") {
            Write-Info "Keeping existing PIN. Skipping."
            return
        }

        Write-Info "Removing existing TPM+PIN protector..."
        manage-bde -protectors -delete $MountPoint -id $existingPin.KeyProtectorId | Out-Null
    }

    $plain = ConvertToPlain -Sec $Pin

    Write-Info "Adding TPM+PIN using manage-bde..."
    $cmd = "manage-bde.exe -protectors -add $MountPoint -TPMAndPIN -PIN $plain"

    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -NoNewWindow -PassThru -Wait

    if ($proc.ExitCode -eq 0) {
        Write-Info "TPM+PIN added successfully."
    } else {
        Write-Err "manage-bde returned exit code $($proc.ExitCode)"
    }

    $plain = $null
}

function Enable-WithPin {
    Assert-TPMReady

    $vol = Get-OsVolume
    if ($vol.ProtectionStatus -ne "On") {
        Write-Info "Enabling BitLocker..."
        Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod $EncryptionMethod -UsedSpaceOnly:$UsedSpaceOnly -TpmProtector -SkipHardwareTest
        Write-Info "Encryption started."
    } else {
        Write-Info "BitLocker already enabled."
    }

    $pin = Read-PinSecure
    Set-BitLockerTpmPin -MountPoint $MountPoint -Pin $pin

    Ensure-RecoveryProtector -MountPoint $MountPoint
    Save-RecoveryKeyLocally -MountPoint $MountPoint

    if ($BackupRecoveryToAAD) { Backup-RecoveryKey-ToAAD -MountPoint $MountPoint }

    Write-Warn "Reboot required for the pre-boot PIN screen."
}

function Disable-Decrypt { Disable-BitLocker -MountPoint $MountPoint }
function Suspend-Protection { Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 }
function Resume-Protection  { Resume-BitLocker -MountPoint $MountPoint }

try {
    Assert-Admin
    Assert-BitLockerModule

    switch ($Action) {
        "Enable"  { Enable-WithPin }
        "Disable" { Disable-Decrypt }
        "Suspend" { Suspend-Protection }
        "Resume"  { Resume-Protection }
    }
}
catch {
    Write-Err "$($_.Exception.Message)"
    exit 1
}