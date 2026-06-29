# Enables WinRM over HTTP with basic + NTLM auth for Packer.
# Lab use only. Production hosts should never run this.

# Block until network is up
$count = 0
while ((Get-NetConnectionProfile).IPv4Connectivity -ne "Internet" -and $count -lt 30) {
    Start-Sleep -Seconds 2
    $count++
}

# Set network profile to Private (Public refuses WinRM by default)
Get-NetConnectionProfile | Where-Object NetworkCategory -ne Private | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

# Ensure WinRM service is running and listener exists
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM -ErrorAction SilentlyContinue

winrm quickconfig -quiet -force
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="12000"}'

# Firewall: open 5985 for any (lab only)
New-NetFirewallRule -DisplayName "WinRM-HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "RDP" -Direction Inbound -LocalPort 3389 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# Disable UAC remote token filtering so a local admin via WinRM has full powers
New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null

"winrm enabled: $(Get-Date -Format o)" | Out-File -FilePath C:\Windows\Temp\packer-post-install.log -Append
