<#
.SYNOPSIS
  Manages BitLocker on the OS volume with TPM+PIN pre-boot authentication.

.DESCRIPTION
  -Action Enable  : Enables BitLocker on the system drive (default C:), adds TPM + PIN,
                    creates and saves a recovery key.
  -Action Disable : Disables (decrypts) BitLocker on the target volume.
  -Action Suspend : Temporarily suspends BitLocker protection.
  -Action Resume  : Resumes BitLocker protection if suspended.

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
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    if (-not $isAdmin) {
        Write-Err "This script must be run as Administrator."
        exit 1
    }
}

function Assert-BitLockerModule {
    if (-not (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Err "BitLocker cmdlets are not available on this system."
        exit 1
    }
}

function Get-OsVolume {
    return Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
}

function Assert-TPMReady {
    try {
        $tpm = Get-Tpm
    } catch {
        Write-Err "Unable to query TPM. Ensure TPM is enabled in UEFI firmware."
        exit 1
    }

    if (-not $tpm.TpmPresent) {
        Write-Err "TPM not detected. TPM+PIN requires a TPM chip."
        exit 1
    }
    if (-not $tpm.TpmReady) {
        Write-Err "TPM is present but not ready. Initialize it in UEFI or via TPM.msc."
        exit 1
    }

    Write-Info "TPM is present and ready."
}

function Read-PinSecure {
    # PIN must be numeric only (4 to 20 digits)
    $pin1 = Read-Host "Enter BitLocker PIN (4-20 digits)" -AsSecureString
    $pin2 = Read-Host "Confirm PIN" -AsSecureString

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin1))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin2))

    if ($p1 -ne $p2) {
        throw "PIN entries do not match."
    }

    if ($p1.Length -lt 4 -or $p1.Length -gt 20 -or ($p1 -notmatch "^[0-9]+$")) {
        throw "PIN must contain only digits (4 to 20)."
    }

    return $pin1
}

function Ensure-RecoveryProtector {
    param([string]$MountPoint)

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $hasRecovery = $false

    foreach ($kp in $vol.KeyProtector) {
        if ($kp.KeyProtectorType -eq "RecoveryPassword") {
            $hasRecovery = $true
            break
        }
    }

    if (-not $hasRecovery) {
        Write-Info "Adding a Recovery Password protector..."
        return Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector
    }

    return $null
}

function Save-RecoveryKeyLocally {
    param([string]$MountPoint)

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1

    if (-not $rec) { return }

    $dir = Join-Path $env:PUBLIC "Documents\\BitLocker-RecoveryKeys"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $file = Join-Path $dir ("RecoveryKey_{0}_{1}.txt" -f $MountPoint.TrimEnd(':'), (Get-Date -Format "yyyyMMdd_HHmmss"))

    $text = @(
        "Drive        : $MountPoint"
        "Timestamp    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Protector ID : $($rec.KeyProtectorId)"
        "Recovery Key : $($rec.RecoveryPassword)"
    )

    $text | Out-File -FilePath $file -Encoding ASCII
    Write-Info "Recovery key saved locally at: $file"
}

function Backup-RecoveryKey-ToAAD {
    param([string]$MountPoint)

    if (-not (Get-Command BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue)) {
        Write-Warn "AAD key backup not supported on this device."
        return
    }

    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" | Select-Object -First 1

    if ($rec) {
        BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rec.KeyProtectorId
        Write-Info "Recovery key successfully backed up to Entra ID (AAD)."
    }
}

function Enable-WithPin {
    Assert-TPMReady

    $vol = Get-OsVolume
    if ($vol.ProtectionStatus -eq "On") {
        Write-Info "BitLocker is already enabled on $MountPoint."
    } else {
        Write-Info "Enabling BitLocker on $MountPoint..."
        Enable-BitLocker -MountPoint $MountPoint `
                         -EncryptionMethod $EncryptionMethod `
                         -UsedSpaceOnly:$UsedSpaceOnly `
                         -TpmProtector `
                         -SkipHardwareTest `
                         -ErrorAction Stop

        Write-Info "Encryption started."
    }

    Write-Info "Adding TPM+PIN protector..."
    $pin = Read-PinSecure
    Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmPinProtector -Pin $pin | Out-Null
    Write-Info "PIN successfully added."

    Ensure-RecoveryProtector -MountPoint $MountPoint | Out-Null
    Save-RecoveryKeyLocally -MountPoint $MountPoint

    if ($BackupRecoveryToAAD) {
        Backup-RecoveryKey-ToAAD -MountPoint $MountPoint
    }

    Write-Host "`n*** Reboot required for the pre-boot PIN prompt to appear. ***" -ForegroundColor Yellow
}

function Disable-Decrypt {
    $vol = Get-OsVolume
    if ($vol.ProtectionStatus -ne "On") {
        Write-Info "BitLocker is not enabled on $MountPoint."
        return
    }

    Write-Warn "Decrypting $MountPoint..."
    Disable-BitLocker -MountPoint $MountPoint
}

function Suspend-Protection {
    Write-Info "Suspending BitLocker protection on $MountPoint..."
    Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0
}

function Resume-Protection {
    Write-Info "Resuming BitLocker protection on $MountPoint..."
    Resume-BitLocker -MountPoint $MountPoint
}

# Main
try {
    Assert-Admin
    Assert-BitLockerModule

    switch ($Action) {
        "Enable"  { Enable-WithPin }
        "Disable" { Disable-Decrypt }
        "Suspend" { Suspend-Protection }
        "Resume"  { Resume-Protection }
        default   { Write-Err "Invalid action specified." }
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}