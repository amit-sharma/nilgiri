# Generalize before Packer takes the disk snapshot.
#   - No /unattend on the cmdline: sysprep resolves it against A:\ and hangs
#     silently after Pnp_Drivers if absent.
#   - /mode:vm skips app-provisioning checks that hang on Server 2022 Eval and
#     keeps the image safe to clone across VMs of the same type.
#   - Start-Process without -Wait: sysprep triggers shutdown itself.
$ErrorActionPreference = "Stop"

Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\sysprep.exe" `
    -ArgumentList "/generalize", "/oobe", "/shutdown", "/quiet", "/mode:vm" `
    -NoNewWindow
