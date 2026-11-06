# Shows the standard Windows "Open file" dialog and prints the chosen path. Started by the helper on demand.
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0; StartPosition = 'CenterScreen' }
$owner.Show()
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = 'Choose an application'
$d.Filter = 'Programs and shortcuts|*.exe;*.lnk;*.msc;*.bat;*.cmd;*.ps1|All files|*.*'
if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.FileName) }
$owner.Close()
