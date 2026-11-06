# Stops the Command Center helper (only the one started from this folder).
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $root 'helper.ps1'
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($target) -and $_.ProcessId -ne $PID })
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
Write-Host ("Stopped {0} helper process(es)." -f $procs.Count)
