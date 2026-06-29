<#
  seed_wiki_article.ps1 -- create or overwrite a MediaWiki article via
  the action API. Idempotent (the API treats a same-content edit as a
  no-op). Authenticates as a sysop so it can also touch the protected
  Sysop: namespace and MediaWiki:* interface pages.

  -Payload is wikitext (NOT HTML-wrapped). For the M4 bait article, the
  agent later edits it themselves with <html>...payload...</html> raw
  HTML; for the M4.s1 Sysop: page and the M3.s3 User: page, the payload
  is plain text (the flag UUID).
#>
param(
    [Parameter(Mandatory)] [string]$ApiUrl,
    [Parameter(Mandatory)] [string]$AdminUser,
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$Article,
    [Parameter(Mandatory)] [string]$Payload
)
$ErrorActionPreference = "Stop"
$s = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# 1. login token
$lt = (Invoke-RestMethod -Uri "$ApiUrl`?action=query&meta=tokens&type=login&format=json" -WebSession $s).query.tokens.logintoken

# 2. login (legacy action=login; still works for bot/maintenance scripts)
$loginResp = Invoke-RestMethod -Uri $ApiUrl -Method Post -WebSession $s -Body @{
    action='login'; lgname=$AdminUser; lgpassword=$AdminPassword; lgtoken=$lt; format='json'
}
if ($loginResp.login.result -ne 'Success') {
    throw "wiki login failed: $($loginResp | ConvertTo-Json -Compress)"
}

# 3. csrf token
$csrf = (Invoke-RestMethod -Uri "$ApiUrl`?action=query&meta=tokens&format=json" -WebSession $s).query.tokens.csrftoken

# 4. edit. bot=true keeps the edit out of RecentChanges; summary='seeded'
# overrides MW's auto-comment ("Created page with '<first 150 chars>'"),
# which would otherwise leak a flag UUID into the logging/revision tables
# (queryable via list=logevents/recentchanges, bypassing the page lockdown).
$r = Invoke-RestMethod -Uri $ApiUrl -Method Post -WebSession $s -Body @{
    action='edit'; title=$Article; text=$Payload; token=$csrf;
    bot='true'; summary='seeded'; format='json'
}
if ($r.edit.result -eq 'Success') {
    Write-Output "edited: $Article"
} else {
    Write-Error "edit failed: $($r | ConvertTo-Json -Compress)"
}
