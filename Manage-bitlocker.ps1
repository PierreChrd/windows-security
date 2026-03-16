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
  Run as Administrator. Compatible with PowerShell 5.1.
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

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator."
        exit 1
    }
}

function Assert-BitLockerModule {
    if (-not (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Error "BitLocker module is not available on this system."
        exit 1
    }
}

function Get-OsVolume {
    return Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
}

function Assert-TPMReady {
    try { $tpm = Get-Tpm } catch {
        Write-Error "Unable to query TPM. Ensure TPM is enabled in UEFI."
        exit 1
    }

    if (-not $tpm.TpmPresent) {
        Write-Error "TPM not detected."
        exit 1
    }
    if (-not $tpm.TpmReady) {
        Write-Error "TPM is not initialized."
        exit 1
    }

    Write-Info "TPM is present and ready."
}

function Read-PinSecure {
    $pin1 = Read-Host "Enter BitLocker PIN (4-20 digits)" -AsSecureString
    $pin2 = Read-Host "Confirm PIN" -AsSecureString

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin1))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin2))

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
        Write-Info "Adding recovery password protector..."
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
        Write-Warn "AAD backup not supported."
        return
    }

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1

    if ($rec) {
        BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rec.KeyProtectorId
        Write-Info "Recovery key backed up to Entra ID (AAD)."
    }
}

function Add-Or-Replace-TpmPinProtector {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MountPoint,

        [Parameter(Mandatory=$true)]
        [SecureString]$Pin
    )

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $existingPin = $vol.KeyProtector | Where-Object KeyProtectorType -eq "TpmPin"

    if ($existingPin) {
        Write-Warn "A TPM+PIN protector already exists."

        $choice = Read-Host "Replace existing PIN? (Y/N)"
        if ($choice -notmatch "^[Yy]$") {
            Write-Info "Keeping existing TPM+PIN. Skipping."
            return
        }

        Write-Info "Removing existing TPM+PIN protector..."
        manage-bde -protectors -delete $MountPoint -id $existingPin.KeyProtectorId | Out-Null
    }

    Write-Info "Adding new TPM+PIN protector..."
    Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmPinProtector -Pin $Pin | Out-Null
    Write-Info "New PIN applied successfully."
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
    Add-Or-Replace-TpmPinProtector -MountPoint $MountPoint -Pin $pin

    Ensure-RecoveryProtector -MountPoint $MountPoint
    Save-RecoveryKeyLocally -MountPoint $MountPoint

    if ($BackupRecoveryToAAD) {
        Backup-RecoveryKey-ToAAD -MountPoint $MountPoint
    }

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
    Write-Error "$($_.Exception.Message)"
    exit 1
}