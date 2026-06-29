# Patch the Default Domain Controllers Policy's GptTmpl.inf so
# LDAPServerIntegrity=2 and LdapEnforceChannelBinding=2. Idempotent.

$ErrorActionPreference = 'Stop'

$guid = '{' + '6AC1786C-016F-11D2-945F-00C04fB984F9' + '}'
$tmpl = "C:\Windows\SYSVOL\domain\Policies\$guid\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
$gpt  = "C:\Windows\SYSVOL\domain\Policies\$guid\GPT.INI"

if (-not (Test-Path $tmpl)) {
    Write-Error "GptTmpl.inf not found at $tmpl"
    exit 1
}

# GptTmpl.inf is UTF-16 LE with BOM.
$content = [System.IO.File]::ReadAllText($tmpl, [System.Text.Encoding]::Unicode)

$signingKey = 'MACHINE\System\CurrentControlSet\Services\NTDS\Parameters\LDAPServerIntegrity'
$cbKey      = 'MACHINE\System\CurrentControlSet\Services\NTDS\Parameters\LdapEnforceChannelBinding'
$signingPat = [regex]::Escape($signingKey) + '=4,\d'
$cbPat      = [regex]::Escape($cbKey) + '=4,\d'
$origContent = $content

# Replace existing value, or append into the [Registry Values] section
if ($content -match $signingPat) {
    $content = [regex]::Replace($content, $signingPat, "$signingKey=4,2")
} else {
    $content = [regex]::Replace($content, '(\[Registry Values\][\r\n]+)', "`$1$signingKey=4,2`r`n")
}
if ($content -match $cbPat) {
    $content = [regex]::Replace($content, $cbPat, "$cbKey=4,2")
} else {
    $content = [regex]::Replace($content, '(\[Registry Values\][\r\n]+)', "`$1$cbKey=4,2`r`n")
}

if ($content -ne $origContent) {
    [System.IO.File]::WriteAllText($tmpl, $content, [System.Text.Encoding]::Unicode)
    # Bump the computer-side (high word) of GPT.INI Version so DCs notice the change.
    $gpti = Get-Content $gpt
    $out = foreach ($l in $gpti) {
        if ($l -match '^Version=(\d+)') {
            $v = [int]$Matches[1]
            $userPart = $v -band 0xFFFF
            $compPart = ($v -shr 16) + 1
            "Version=" + ((($compPart -shl 16) -bor $userPart))
        } else { $l }
    }
    Set-Content $gpt -Value $out
    Write-Output "patched"
} else {
    Write-Output "no-change"
}

# Force a Computer Configuration policy refresh
& gpupdate /force /target:computer 2>&1 | Out-String | Out-Null
Start-Sleep -Seconds 3

# Echo current state of the relevant keys
$p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
Write-Output ("LDAPServerIntegrity=" + $p.LDAPServerIntegrity + " LdapEnforceChannelBinding=" + $p.LdapEnforceChannelBinding)
