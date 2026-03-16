<#
.SYNOPSIS
  Adds or removes a legal notice (logon banner) displayed on the Windows sign-in / unlock screen.

.DESCRIPTION
  Uses the registry keys:
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
      - LegalNoticeCaption
      - LegalNoticeText

.PARAMETER Title
  Banner title.

.PARAMETER Message
  Banner text.

.PARAMETER Disable
  Removes the existing banner.

.NOTES
  Requires Administrator privileges.
#>

[CmdletBinding()]
param(
    [string]$Title = "Security Warning",
    [string]$Message = "Authorized use only. If you are not authorized to use this machine, disconnect immediately.",
    [switch]$Disable
)

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    if(-not $isAdmin){
        Write-Error "This script must be run as Administrator."
        exit 1
    }
}

Assert-Admin

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

if($Disable){
    Write-Host "[INFO] Removing logon banner…" -ForegroundColor Cyan
    Remove-ItemProperty -Path $regPath -Name "LegalNoticeCaption" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $regPath -Name "LegalNoticeText" -ErrorAction SilentlyContinue
    Write-Host "[OK] Logon banner has been removed." -ForegroundColor Green
    exit 0
}

Write-Host "[INFO] Applying logon banner…" -ForegroundColor Cyan

Set-ItemProperty -Path $regPath -Name "LegalNoticeCaption" -Value $Title
Set-ItemProperty -Path $regPath -Name "LegalNoticeText" -Value $Message

Write-Host "[OK] Banner applied successfully." -ForegroundColor Green
Write-Host "➡️ The message will be visible at next lock/unlock, logon, or restart." -ForegroundColor Yellow
