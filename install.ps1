# One-time, per-user setup. No administrator rights needed. Asks before each change.
#   - makes the "Start helper" button on CommandCenter.html work (registers an occstart: link for YOUR user)
#   - optional: start the helper silently when you log in
#   - optional: Desktop shortcut that opens the control panel
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Ask([string]$q) { return ((Read-Host "$q [Y/n]") -notmatch '^\s*(n|no)\s*$') }

foreach ($f in 'helper.ps1', 'start-hidden.vbs', 'CommandCenter.html', 'web\index.html') {
    if (-not (Test-Path (Join-Path $root $f))) { Write-Error "Missing $f - keep all files together in one folder."; exit 1 }
}

# 1. Files downloaded from the internet carry a "blocked" mark that stops PowerShell scripts from running.
$blocked = @(Get-ChildItem -Path $root -Recurse -File | Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
if ($blocked.Count -gt 0) {
    Write-Host "$($blocked.Count) file(s) in this folder are marked as downloaded from the internet."
    if (Ask 'Unblock them (only the files in this folder)?') { $blocked | Unblock-File; Write-Host 'Unblocked.' }
}

# 2. PowerShell script policy. We never bypass it; we only tell you if it would stop the helper.
$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Host "Your PowerShell policy is '$policy', which prevents helper.ps1 from running."
    Write-Host "The standard fix is RemoteSigned for your user only (local scripts run, downloaded ones must be unblocked)."
    if (Ask 'Set RemoteSigned for your user?') {
        try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force; Write-Host 'Done.' }
        catch { Write-Warning "Could not change it (your organisation's policy may control it): $($_.Exception.Message)" }
    }
}

# 3. "Start helper" link, for this user only (HKCU). It takes no arguments, so a web page cannot pass anything in.
$k = 'HKCU:\Software\Classes\occstart'
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name '(default)' -Value 'URL:Office Command Center helper'
New-ItemProperty -Path $k -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
New-Item -Path "$k\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$k\shell\open\command" -Name '(default)' -Value ('wscript.exe "{0}"' -f (Join-Path $root 'start-hidden.vbs'))
Write-Host 'Start helper link registered.'

$wsh = New-Object -ComObject WScript.Shell

# 4. Optional: start at login
if (Ask 'Start the helper automatically (hidden) when you log in?') {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Office Command Center.lnk'
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = 'wscript.exe'; $s.Arguments = '"{0}"' -f (Join-Path $root 'start-hidden.vbs')
    $s.WorkingDirectory = $root; $s.WindowStyle = 7; $s.Save()
    Write-Host "Autostart added: $lnk"
}

# 5. Optional: desktop shortcut that opens the panel in your default browser
if (Ask 'Create a "Command Center" shortcut on your Desktop?') {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Command Center.lnk'
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = (Join-Path $root 'CommandCenter.html'); $s.WorkingDirectory = $root; $s.Save()
    Write-Host "Shortcut created: $lnk"
}

if (Ask 'Start the helper and open Command Center now?') {
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f (Join-Path $root 'start-hidden.vbs'))
    Start-Sleep -Seconds 2
    Start-Process (Join-Path $root 'CommandCenter.html')
}
Write-Host 'Setup finished.'
