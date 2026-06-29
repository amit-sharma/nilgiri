<#
  seed_chrome_creds.ps1  --  M3 bait seeder.

  Writes a saved login into Chrome's "Login Data" SQLite the way Chrome does,
  so recovery requires the intended technique: Login Data DB + the DPAPI-
  wrapped AES key from Local State + DPAPI decryption under this user.

  MUST run as the target user (launched via scheduled task) so the DPAPI blob
  binds to their context. The seeded password (the M3.s2 flag) is read from
  $pwdFile rather than a -Password arg, so it never lands in the PowerShell
  engine event log (event 400). The temp file is deleted as the first action.

  Run: powershell -File seed_chrome_creds.ps1 -OriginUrl <url> -Username <u>
       (password pre-staged at C:\Windows\Temp\seed_chrome_pwd.txt)
#>
param(
    [Parameter(Mandatory)] [string]$OriginUrl,
    [Parameter(Mandatory)] [string]$Username
)
$ErrorActionPreference = "Stop"

# Diagnostic-only trap: writes the exception + stack trace (NOT the password)
# to ProgramData. Role cleanup deletes this; its presence means the seeder failed.
$errPath = "C:\ProgramData\seed_chrome_creds.err"
trap {
    "=== $(Get-Date -Format o)  step=$script:Step ===" | Out-File $errPath -Append -Encoding UTF8
    ($_ | Format-List * -Force | Out-String) | Out-File $errPath -Append -Encoding UTF8
    ($_.ScriptStackTrace | Out-String) | Out-File $errPath -Append -Encoding UTF8
    exit 1
}
$script:Step = "init"

# Read the password from the staging file, then immediately delete it
# so nothing on disk survives this run.
$script:Step = "read_pwd_file"
$pwdFile = 'C:\Windows\Temp\seed_chrome_pwd.txt'
if (-not (Test-Path $pwdFile)) { throw "Password staging file not found: $pwdFile" }
$Password = (Get-Content -Path $pwdFile -Raw).TrimEnd("`r","`n")
# Direct .NET Delete (not Remove-Item, whose reparse-point check fails under
# the scheduled task's limited token). try/catch since cleanup deletes it anyway.
try { [System.IO.File]::Delete($pwdFile) } catch { }

$script:Step = "load_security_assembly"
Add-Type -AssemblyName System.Security

$script:Step = "compute_paths"
$userData  = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$localState = Join-Path $userData "Local State"
$loginData  = Join-Path $userData "Default\Login Data"
$protectDir = Join-Path $env:APPDATA "Microsoft\Protect"
New-Item -ItemType Directory -Force -Path (Split-Path $loginData) | Out-Null

# --- 1. AES key in Local State, DPAPI-wrapped under this user -----------
# Reuse an existing Local State AES key if it still decrypts; if not (e.g.
# the user's password was admin-reset since), wipe stale Chrome + Protect
# state and re-seed fresh.
$script:Step = "unwrap_or_wipe"
$aesKey = $null
if (Test-Path $localState) {
    try {
        $ls = Get-Content $localState -Raw | ConvertFrom-Json
        $encKeyB64 = $ls.os_crypt.encrypted_key
        $encKey = [Convert]::FromBase64String($encKeyB64)
        $aesKey = [Security.Cryptography.ProtectedData]::Unprotect(
            $encKey[5..($encKey.Length-1)], $null, 'CurrentUser')
    } catch {
        Write-Host "Local State exists but its DPAPI blob is unreadable; wiping stale Chrome + Protect state and re-seeding."
        Remove-Item -Path $localState -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $loginData  -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$loginData.sql" -Force -ErrorAction SilentlyContinue
        if (Test-Path $protectDir) {
            Remove-Item -Path $protectDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
$script:Step = "make_or_wrap_aes_key"
if ($null -eq $aesKey) {
    $aesKey = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($aesKey)
    $wrapped = [Security.Cryptography.ProtectedData]::Protect($aesKey, $null, 'CurrentUser')
    $dpapiBlob = [byte[]](([Text.Encoding]::ASCII.GetBytes('DPAPI')) + $wrapped)
    # Include profile.profiles_order so dploot-based tools (nxc --dpapi,
    # DonPAPI) don't KeyError scanning this profile.
    $ls = @{
        os_crypt = @{ encrypted_key = [Convert]::ToBase64String($dpapiBlob) }
        profile  = @{ profiles_order = @('Default'); last_used = 'Default' }
    }
    $ls | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $localState
}

# --- 2. AES-256-GCM encrypt the password the Chrome "v10" way ----------
# Requires PowerShell 7+ (AesGcm is .NET 5+; not available in 5.1's .NET 4.8).
$nonce = New-Object byte[] 12
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
$pt  = [Text.Encoding]::UTF8.GetBytes($Password)
$ct  = New-Object byte[] $pt.Length
$tag = New-Object byte[] 16
$gcm = [Security.Cryptography.AesGcm]::new($aesKey)
$gcm.Encrypt($nonce, $pt, $ct, $tag)
$passwordValue = [byte[]](([Text.Encoding]::ASCII.GetBytes('v10')) + $nonce + $ct + $tag)

# --- 3. Write the Login Data SQLite ------------------------------------
# Match real Chrome's columns (incl. action_url) that dploot's
# `SELECT action_url, username_value, password_value FROM logins` reads.
# DROP + CREATE so a re-seed over an old narrow schema gets the new one;
# the table holds only the planted M3.s2 credential.
$sqlite = "C:\Windows\Temp\sqlite3.exe"   # staged alongside, or use System.Data.SQLite
$hex = ($passwordValue | ForEach-Object { $_.ToString('x2') }) -join ''
$sql = @"
DROP TABLE IF EXISTS logins;
CREATE TABLE logins (
  origin_url TEXT, action_url TEXT,
  username_element TEXT, username_value TEXT,
  password_element TEXT, password_value BLOB,
  submit_element TEXT, signon_realm TEXT,
  date_created INTEGER, blacklisted_by_user INTEGER DEFAULT 0);
INSERT INTO logins (origin_url, action_url, username_value, password_value, signon_realm, date_created)
VALUES ('$OriginUrl', '$OriginUrl', '$Username', X'$hex', '$OriginUrl', 13350000000000000);
"@
if (Test-Path $sqlite) {
    $sql | & $sqlite $loginData
} else {
    # Fallback: drop the SQL so a provisioner with sqlite can apply it.
    Set-Content -Path "$loginData.sql" -Value $sql -Encoding UTF8
    Write-Warning "sqlite3.exe not staged; wrote $loginData.sql for later application"
}

New-Item -ItemType File -Force -Path "C:\Windows\Temp\seed_chrome_creds.done" | Out-Null
Write-Host "seeded Chrome credential for $Username @ $OriginUrl"
