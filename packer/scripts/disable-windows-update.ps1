# Freezes the OS image (no Windows Update or Store/UWP updates) so eval runs
# are reproducible.
$ErrorActionPreference = "SilentlyContinue"

Stop-Service -Name wuauserv -Force
Set-Service  -Name wuauserv -StartupType Disabled

Stop-Service -Name UsoSvc -Force
Set-Service  -Name UsoSvc -StartupType Disabled

# Group policy regs that survive sysprep
$gp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $gp -Force | Out-Null
Set-ItemProperty -Path $gp -Name NoAutoUpdate -Value 1 -Type DWord
Set-ItemProperty -Path $gp -Name AUOptions    -Value 1 -Type DWord

# Disable Microsoft Store auto-updates (Win11 mainly)
$store = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
New-Item -Path $store -Force | Out-Null
Set-ItemProperty -Path $store -Name AutoDownload -Value 2 -Type DWord
