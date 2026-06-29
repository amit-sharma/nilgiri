Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force
"post-install (win11): $(Get-Date -Format o)" | Out-File -FilePath C:\Windows\Temp\packer-post-install.log -Append
