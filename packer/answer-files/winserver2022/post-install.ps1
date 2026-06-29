# Runs as the firstlogon command after install. Minimal: ensure ExecutionPolicy
# is sane and dump a marker so we can see in serial console that we got here.
Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force
"post-install: $(Get-Date -Format o)" | Out-File -FilePath C:\Windows\Temp\packer-post-install.log -Append
