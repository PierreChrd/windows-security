<#
.SYNOPSIS
  Manages BitLocker on the OS volume with TPM+PIN pre-boot authentication.

.DESCRIPTION
  -Action Enable  : Enables BitLocker on the system drive (default C:), adds TPM + PIN, creates/saves a recovery key.
  -Action Disable : Disables (decrypts) BitLocker on the target volume.
  -Action Suspend : Temporarily suspends protection (useful for BIOS/firmware updates).
  -Action Resume  : Resumes protection if suspended.

.PARAMETERS
  -MountPoint           (default 'C:')
  -EncryptionMethod     (XtsAes128|XtsAes256|Aes128|Aes256 ; default XtsAes256)
  -UsedSpaceOnly        (encrypt used space only for faster initial encryption)
  -BackupRecoveryToAAD  (attempt to back up the recovery key to Entra ID/AAD if supported)
  -Quiet                (reduced console verbosity)

.NOTES
  Run as Administrator and ensure BitLocker module is available.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Disable', 'Suspend', 'Resume')]
    [string]$Action = 'Enable',

    [ValidatePattern('^[A-Z]:$')]
    [string]$MountPoint = 'C:',

    [ValidateSet('XtsAes128', 'XtsAes256', 'Aes128', 'Aes256')]
    [string]$EncryptionMethod = 'XtsAes256',

    [switch]$UsedSpaceOnly,

    [switch]$BackupRecoveryToAAD,

    [switch]$Quiet
)

function Write-Info { param($m) if (-not $Quiet) { Write-Host "[INFO]  $m" -ForegroundColor Cyan } }
function Write-Warn { param($m) Write-Warning $m }
function Write-Err { param($m) Write-Error $m }

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
        Write-Err "BitLocker cmdlets are not available. Windows Pro/Enterprise is required (or BitLocker feature missing)."
        exit 1
    }
}

function Get-OsVolume {
    $vol = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    return $vol
}

function Assert-TPMReady {
    try {
        $tpm = Get-Tpm
    }
    catch {
        Write-Err "Unable to query TPM. Is it present/enabled in UEFI?"
        exit 1
    }
    if (-not $tpm.TpmPresent) {
        Write-Err "No TPM detected. Pre-boot PIN (TPM+PIN) on OS volume requires a TPM."
        exit 1
    }
    if (-not $tpm.TpmReady) {
        Write-Err "TPM is not ready (Owned/Initialized). Initialize it in UEFI or via TPM.msc."
        exit 1
    }
    Write-Info "TPM is present and ready."
}

function Read-PinSecure {
    # Requests a numeric PIN 4–20 digits. Double entry to prevent typos.
    $pin1 = Read-Host "Enter BitLocker PIN (4-20 digits)" -AsSecureString
    $pin2 = Read-Host "Confirm PIN" -AsSecureString

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin1)
    )
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin2)
    )

    if ($p1 -ne $p2) {
        throw "PIN entries do not match."
    }

    if ($p1.Length -lt 4 -or $p1.Length -gt 20 -or ($p1 -notmatch '^[0-9]+$')) {
        throw "PIN must be numeric only and contain 4 to 20 digits."
    }

    return $pin1
}

function Ensure-RecoveryProtector {
    param([Parameter(Mandatory)]$MountPoint)

    $v = Get-BitLockerVolume -MountPoint $MountPoint
    $hasRecovery = $false
    foreach ($kp in $v.KeyProtector) {
        if ($kp.KeyProtectorType -eq 'RecoveryPassword') { $hasRecovery = $true; break }
    }
    if (-not $hasRecovery) {
        Write-Info "Adding a 'Recovery Password' key protector…"
        $rp = Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop
        return $rp
    }
    return $null
}

function Save-RecoveryKeyLocally {
    param(
        [Parameter(Mandatory)][string]$MountPoint
    )
    $v = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    if (-not $rec) { return }

    $dir = Join-Path $env:PUBLIC "Documents\BitLocker-RecoveryKeys"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $file = Join-Path $dir ("RecoveryKey_{0}_{1}.txt" -f $MountPoint.TrimEnd(':'), (Get-Date -Format "yyyyMMdd_HHmmss"))

    $lines = @()
    $lines += "Drive        : $MountPoint"
    $lines += "Date         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Type         : RecoveryPassword"
    $lines += "KeyProtector : $($rec.KeyProtectorId)"
    if ($rec.RecoveryPassword) { $lines += "RecoveryKey  : $($rec.RecoveryPassword)" }
    else { $lines += "RecoveryKey  : (not readable via API on this version – use 'manage-bde -protectors -get $MountPoint')" }

    $lines | Set-Content -Path $file -Encoding UTF8
    Write-Info "Recovery key saved locally: $file"
}

function Backup-RecoveryKey-ToAAD {
    param(
        [Parameter(Mandatory)][string]$MountPoint
    )
    try {
        $v = Get-BitLockerVolume -MountPoint $MountPoint
        $rec = $v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
        if ($rec) {
            if (Get-Command -Name BackupToAAD-BitLockerKeyProtector -ErrorAction SilentlyContinue) {
                BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rec.KeyProtectorId -ErrorAction Stop
                Write-Info "Recovery key backed up to Entra ID (AAD)."
            }
            else {
                Write-Warn "Cmdlet 'BackupToAAD-BitLockerKeyProtector' not available. Device may not be AAD-joined or Windows edition unsupported."
            }
        }
        else {
            Write-Warn "No recovery protector found on $MountPoint."
        }
    }
    catch {
        Write-Warn "AAD backup failed: $($_.Exception.Message)"
    }
}

function Enable-WithPin {
    Assert-TPMReady

    $vol = Get-OsVolume
    if ($vol.ProtectionStatus -eq 'On') {
        Write-Info "BitLocker is already enabled on $MountPoint."
    }
    else {
        Write-Info "Enabling BitLocker on $MountPoint (method $EncryptionMethod)…"
        Enable-BitLocker -MountPoint $MountPoint `
            -EncryptionMethod $EncryptionMethod `
            -UsedSpaceOnly:$UsedSpaceOnly `
            -TpmProtector `
            -SkipHardwareTest `
            -ErrorAction Stop
        Write-Info "Encryption started."
    }

    # Add pre-boot PIN (TPM+PIN)
    Write-Info "Configuring pre-boot PIN (TPM+PIN)…"
    $pin = Read-PinSecure
    Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmPinProtector -Pin $pin -ErrorAction Stop | Out-Null
    Write-Info "PIN added. (A restart is required for the pre-boot prompt to take effect.)"

    # Ensure a recovery protector exists
    $rp = Ensure-RecoveryProtector -MountPoint $MountPoint
    if ($rp) { Write-Info "Recovery protector added." }    

    # Backups
    Save-RecoveryKeyLocally -MountPoint $MountPoint
    if ($BackupRecoveryToAAD) { Backup-RecoveryKey-ToAAD -MountPoint $MountPoint }

    # Show status
    $v2 = Get-OsVolume
    Write-Info ("Status: Protection={0} | Method={1} | Progress={2}% | Protectors={3}" -f `
            $v2.ProtectionStatus, $v2.EncryptionMethod, $v2.EncryptionPercentage, `
        ($v2.KeyProtector | ForEach-Object KeyProtectorType -join ', '))
    Write-Host "`n➡️  Reboot the device to get the BitLocker pre-boot PIN screen." -ForegroundColor Yellow
}

function Disable-Decrypt {
    $vol = Get-OsVolume
    if ($vol.ProtectionStatus -ne 'On') {
        Write-Info "BitLocker is not active on $MountPoint."
        return
    }
    Write-Warn "Disabling (decrypting) BitLocker on $MountPoint…"
    Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop
    Write-Info "Decryption started (this may take a while)."
}

function Suspend-Protection {
    Write-Info "Suspending BitLocker protection on $MountPoint until resumed…"
    Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 -ErrorAction Stop
}

function Resume-Protection {
    Write-Info "Resuming BitLocker protection on $MountPoint…"
    Resume-BitLocker -MountPoint $MountPoint -ErrorAction Stop
}

# --- Main ---
try {
    Assert-Admin
    Assert-BitLockerModule

    switch ($Action) {
        'Enable' { Enable-WithPin }
        'Disable' { Disable-Decrypt }
        'Suspend' { Suspend-Protection }
        'Resume' { Resume-Protection }
        default { Write-Err "Unsupported action: $Action" }
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}