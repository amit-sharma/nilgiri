# Installs OpenSSH Server (Windows built-in feature). Used by Ansible's
# alternative connection plugin and for human RDP-free ops on workstations.
$ErrorActionPreference = "Stop"

$cap = Get-WindowsCapability -Online -Name OpenSSH.Server* | Where-Object State -eq NotPresent
if ($cap) {
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}

Set-Service -Name sshd       -StartupType Automatic
Set-Service -Name ssh-agent  -StartupType Automatic
Start-Service sshd
Start-Service ssh-agent

# Default shell to PowerShell (not cmd) so ansible's psrp/ssh plugin behaves
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

New-NetFirewallRule -DisplayName "OpenSSH-SSH-In" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
