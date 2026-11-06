# Removes everything install.ps1 added. Your saved lists stay in %APPDATA%\OfficeCommandCenter (delete it yourself if you want).
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $root 'stop-helper.ps1')
Remove-Item -Path 'HKCU:\Software\Classes\occstart' -Recurse -Force -ErrorAction SilentlyContinue
foreach ($p in @((Join-Path ([Environment]::GetFolderPath('Startup')) 'Office Command Center.lnk'),
                 (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Command Center.lnk'))) {
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed $p" }
}
Write-Host 'Uninstalled. You can now delete this folder.'
