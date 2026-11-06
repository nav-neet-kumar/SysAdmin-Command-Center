# Office Command Center - helper (PowerShell 5.1+, nothing to install).
# Serves the control panel on 127.0.0.1 only and runs your commands/launches as YOUR Windows account.
#
# Security (all always on):
#   * Only loopback clients are served; Host header allow-list (anti DNS-rebinding)
#   * Random per-run session token on every /api call (constant-time compare)
#   * Origin + Sec-Fetch-Site checks (anti CSRF), strict CSP, no framing, no caching
#   * Only items you saved can be launched; terminal commands that look risky need confirmation
#   * Everything is logged (command output is never logged); no passwords are ever stored
param([int]$Port = 8765)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebDir = Join-Path $Root 'web'
$IsWin  = ($env:OS -eq 'Windows_NT')
$Base   = if ($env:OCC_HOME) { $env:OCC_HOME } elseif ($env:APPDATA) { Join-Path $env:APPDATA 'OfficeCommandCenter' } else { Join-Path $HOME '.officecommandcenter' }
$CfgDir = Join-Path $Base 'config'
$LogDir = Join-Path $Base 'logs'
New-Item -ItemType Directory -Force -Path $CfgDir, $LogDir | Out-Null
$AuditFile = Join-Path $LogDir 'audit.log'
$PickScript = Join-Path $Root 'pick-file.ps1'
$HomeDir = [Environment]::GetFolderPath('UserProfile'); if (-not $HomeDir) { $HomeDir = $HOME }

# One helper per user session
$createdNew = $false
try { $Mutex = New-Object System.Threading.Mutex($true, 'Local\OfficeCommandCenterHelper', [ref]$createdNew) } catch { $createdNew = $true }
if (-not $createdNew) { exit 0 }

try { [Net.ServicePointManager]::SecurityProtocol = 3072 -bor 12288 } catch { try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch { } }

# ---------------------------------------------------------------- audit log
$SecretRx = [regex]'(?i)((?:-|/)?(?:password|passwd|pwd|secret|token|api[-_]?key)\s*[=: ]\s*)("[^"]*"|''[^'']*''|\S+)'
function Protect-Secrets([string]$t) { return $SecretRx.Replace($t, '$1[REDACTED]') }
function Write-Audit([string]$event, [hashtable]$f = @{}) {
    try {
        $rec = [ordered]@{ ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); event = $event }
        foreach ($k in $f.Keys) { $rec[$k] = $f[$k] }
        if ((Test-Path $AuditFile) -and ((Get-Item $AuditFile).Length -gt 1MB)) { Move-Item $AuditFile "$AuditFile.1" -Force }
        Add-Content -Path $AuditFile -Value (ConvertTo-Json -InputObject $rec -Compress) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- validation
$HostRx = [regex]'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?)*$'
function Test-HostName([string]$s) {
    if (-not $s -or $s.Contains('%')) { return $false }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) { return $true }
    return $HostRx.IsMatch($s)
}
function Test-HttpUrl([string]$u) {
    $x = $null
    if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$x)) { return $false }
    if ($x.Scheme -ne 'http' -and $x.Scheme -ne 'https') { return $false }
    if ($x.UserInfo) { return $false }
    return [bool]$x.Host
}
function Test-RdpHost([string]$s) {
    if (-not $s) { return $false }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) { return $true }
    $parts = $s.Split(':')
    if ($parts.Count -eq 1) { return (Test-HostName $s) }
    if ($parts.Count -eq 2 -and $parts[1] -match '^\d{1,5}$' -and [int]$parts[1] -ge 1 -and [int]$parts[1] -le 65535) { return (Test-HostName $parts[0]) }
    return $false
}
# Monitor target: http(s) URL, "host" (ping) or "host:port" (TCP check)
function ConvertTo-Target([string]$t) {
    if ($t -match '^https?://') { if (Test-HttpUrl $t) { return @{ kind = 'url'; target = $t } } else { return $null } }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($t, [ref]$ip)) { return @{ kind = 'ping'; target = $t; host = $t } }
    $p = $t.Split(':')
    if ($p.Count -eq 1 -and (Test-HostName $t)) { return @{ kind = 'ping'; target = $t; host = $t } }
    if ($p.Count -eq 2 -and $p[1] -match '^\d{1,5}$' -and [int]$p[1] -ge 1 -and [int]$p[1] -le 65535 -and (Test-HostName $p[0])) { return @{ kind = 'tcp'; target = $t; host = $p[0]; port = [int]$p[1] } }
    return $null
}
function Clean-Str($v, [string]$field, [int]$max, [bool]$required = $false) {
    if ($null -eq $v) { $v = '' }
    $s = ([string]$v).Trim()
    if ($required -and -not $s) { throw "$field is required" }
    if ($s.Length -gt $max) { throw "$field is too long (max $max)" }
    if ($s -match '[\x00-\x1f\x7f]') { throw "$field contains invalid characters" }
    return $s
}
function Clean-Item([string]$kind, $raw) {
    $id = [string]$raw.id
    if ($id -notmatch '^[A-Za-z0-9_-]{1,40}$') { $id = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    $name = Clean-Str $raw.name 'name' 60 $true
    switch ($kind) {
        'sites' {
            $url = Clean-Str $raw.url 'url' 2048 $true
            if (-not (Test-HttpUrl $url)) { throw 'URL must start with http:// or https:// and must not contain a username/password' }
            return [ordered]@{ id = $id; name = $name; url = $url }
        }
        'monitors' {
            $t = Clean-Str $raw.target 'target' 2048 $true
            if (-not (ConvertTo-Target $t)) { throw 'Target must be a URL (https://...), an IP/host to ping, or host:port for a TCP check' }
            return [ordered]@{ id = $id; name = $name; target = $t }
        }
        'apps' {
            return [ordered]@{ id = $id; name = $name; path = (Clean-Str $raw.path 'path' 260 $true); args = (Clean-Str $raw.args 'arguments' 500); admin = ($raw.admin -eq $true) }
        }
        'rdp' {
            $h = Clean-Str $raw.host 'host' 260 $true
            if (-not (Test-RdpHost $h)) { throw 'Host must be an IP address or hostname (optionally :port)' }
            return [ordered]@{ id = $id; name = $name; host = $h }
        }
    }
    throw 'Unknown list'
}

# ---------------------------------------------------------------- storage
$Kinds = @('sites', 'monitors', 'apps', 'rdp')
function Read-Items([string]$kind) {
    $p = Join-Path $CfgDir "$kind.json"
    if (-not (Test-Path $p)) { return ,@() }
    try { $d = Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Audit 'config_corrupt' @{ file = $kind }; Move-Item $p "$p.corrupt" -Force; return ,@() }
    return ,@($d.items | Where-Object { $null -ne $_ })
}
$State = [hashtable]::Synchronized(@{
        Results = [hashtable]::Synchronized(@{}); Targets = @(); Interval = 60
        Wake = (New-Object System.Threading.AutoResetEvent $false); Pick = $null
    })
function Update-Targets {
    $list = @()
    $sites = Read-Items 'sites'
    foreach ($s in $sites) { $list += @{ id = $s.id; kind = 'url'; target = $s.url } }
    $mons = Read-Items 'monitors'
    foreach ($m in $mons) { $t = ConvertTo-Target ([string]$m.target); if ($t) { $t.id = $m.id; $list += $t } }
    $State.Targets = $list
}
function Save-Items([string]$kind, $items) {
    if ($null -eq $items) { $items = @() }
    $items = @($items)
    if ($items.Count -gt 200) { throw 'Too many items (max 200)' }
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    $n = 0
    foreach ($raw in $items) {
        $n++
        try { $c = Clean-Item $kind $raw } catch { throw "$kind #${n}: $($_.Exception.Message)" }
        if ($seen.ContainsKey($c.id)) { $c.id = [guid]::NewGuid().ToString('N').Substring(0, 12) }
        $seen[$c.id] = $true
        [void]$list.Add($c)
    }
    $json = ConvertTo-Json -InputObject ([ordered]@{ items = @($list.ToArray()) }) -Depth 5
    $p = Join-Path $CfgDir "$kind.json"
    Set-Content -Path "$p.tmp" -Value $json -Encoding UTF8
    Move-Item "$p.tmp" $p -Force
    Write-Audit 'config_saved' @{ collection = $kind; count = $list.Count }
    Update-Targets
    $State.Wake.Set() | Out-Null
    return ,@($list.ToArray())
}
function Initialize-Defaults {
    $seed = @{
        sites = @(@{ name = 'Microsoft 365'; url = 'https://www.office.com' }, @{ name = 'GitHub'; url = 'https://github.com' })
        monitors = @()
        apps = @(
            @{ name = 'CMD'; path = 'cmd.exe'; admin = $false }, @{ name = 'PowerShell'; path = 'powershell.exe'; admin = $false },
            @{ name = 'Services'; path = 'services.msc'; admin = $false }, @{ name = 'Task Manager'; path = 'taskmgr.exe'; admin = $false })
        rdp = @()
    }
    foreach ($k in $Kinds) { if (-not (Test-Path (Join-Path $CfgDir "$k.json"))) { [void](Save-Items $k $seed[$k]) } }
}
function Find-Item([string]$kind, $id) {
    $items = Read-Items $kind
    foreach ($i in $items) { if ($i.id -eq [string]$id) { return $i } }
    return $null
}

# ---------------------------------------------------------------- website / IP monitor (background runspace)
$MonitorLoop = @'
$check = {
    param($t)
    $res = @{ id = $t.id; kind = $t.kind; status = 'offline'; code = $null; ms = $null; error = $null; at = (Get-Date).ToString('HH:mm:ss') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($t.kind -eq 'url') {
            $req = [Net.HttpWebRequest]::Create($t.target)
            $req.Method = 'GET'; $req.Timeout = 8000; $req.ReadWriteTimeout = 8000
            $req.UserAgent = 'OfficeCommandCenter/1.0'; $req.AllowAutoRedirect = $true; $req.MaximumAutomaticRedirections = 5
            if ($req.Proxy) { $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials }
            $code = 0
            try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close() }
            catch [Net.WebException] {
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() }
                else { throw }
            }
            $res.code = $code; $res.ms = [int]$sw.ElapsedMilliseconds
            $res.status = if ($code -lt 400) { 'online' } elseif ($code -lt 500) { 'degraded' } else { 'offline' }
        }
        elseif ($t.kind -eq 'ping') {
            $p = New-Object Net.NetworkInformation.Ping
            $r = $p.Send($t.host, 2000)
            if ($r.Status -eq 'Success') { $res.status = 'online'; $res.ms = [int]$r.RoundtripTime } else { $res.error = [string]$r.Status }
        }
        else {
            $c = New-Object Net.Sockets.TcpClient
            try {
                $iar = $c.BeginConnect($t.host, [int]$t.port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) { $c.EndConnect($iar); $res.status = 'online'; $res.ms = [int]$sw.ElapsedMilliseconds }
                else { $res.error = 'Timeout' }
            } finally { $c.Close() }
        }
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        $res.error = 'Not reachable'
        if ($ex -is [Net.WebException]) {
            switch ([string]$ex.Status) {
                'NameResolutionFailure' { $res.error = 'DNS lookup failed' }
                'ConnectFailure'        { $res.error = 'Connection refused' }
                'Timeout'               { $res.error = 'Timed out' }
                'TrustFailure'          { $res.error = 'TLS certificate problem' }
                'SecureChannelFailure'  { $res.error = 'TLS certificate problem' }
                default                 { $res.error = 'Not reachable' }
            }
        }
        elseif ($ex -is [Net.Sockets.SocketException]) { $res.error = 'Connection failed' }
    }
    return $res
}
$pool = [runspacefactory]::CreateRunspacePool(1, 8); $pool.Open()
while ($true) {
    try {
        $jobs = @()
        foreach ($t in @($State.Targets)) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($check.ToString()).AddArgument($t)
            $jobs += [pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke() }
        }
        foreach ($j in $jobs) {
            try { $r = $j.ps.EndInvoke($j.h); if ($r) { $State.Results[[string]$r[0].id] = $r[0] } } catch { }
            $j.ps.Dispose()
        }
    } catch { }
    try {
        $live = @{}; foreach ($t in @($State.Targets)) { $live[[string]$t.id] = $true }
        foreach ($k in @($State.Results.Keys)) { if (-not $live.ContainsKey($k)) { $State.Results.Remove($k) } }
    } catch { }
    [void]$State.Wake.WaitOne([int]($State.Interval * 1000))
}
'@
function Start-Monitor {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('State', $State)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($MonitorLoop)
    [void]$ps.BeginInvoke()
}

# ---------------------------------------------------------------- terminal (one persistent PowerShell session, your account, not elevated)
$Term = [hashtable]::Synchronized(@{ Runspace = $null; PS = $null; Handle = $null; Output = $null; Finished = $true; Cwd = $HomeDir })
function Reset-Term {
    if ($Term.PS) { try { $Term.PS.Stop() } catch { } ; try { $Term.PS.Dispose() } catch { } }
    if ($Term.Runspace) { try { $Term.Runspace.Close(); $Term.Runspace.Dispose() } catch { } }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    try { $rs.SessionStateProxy.Path.SetLocation($HomeDir) | Out-Null } catch { }
    $Term.Runspace = $rs; $Term.PS = $null; $Term.Handle = $null; $Term.Output = $null; $Term.Finished = $true; $Term.Cwd = $HomeDir
}
function Test-TermBusy { return ($Term.Handle -and -not $Term.Handle.IsCompleted) }
function Start-TermCommand([string]$cmd) {
    if ($Term.PS) { try { $Term.PS.Dispose() } catch { } }
    $ps = [powershell]::Create(); $ps.Runspace = $Term.Runspace
    [void]$ps.AddScript(". {`n$cmd`n} *>&1 | Out-String -Stream -Width 200")
    $in = New-Object 'System.Management.Automation.PSDataCollection[psobject]'; $in.Complete()
    $out = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $Term.PS = $ps; $Term.Output = $out; $Term.Finished = $false
    $Term.Handle = $ps.BeginInvoke($in, $out)
}
function Get-TermPoll([int]$cursor) {
    $lines = @()
    $out = $Term.Output
    $completed = $true
    if ($Term.Handle) { $completed = $Term.Handle.IsCompleted }
    if ($out) {
        $n = $out.Count
        if ($cursor -lt 0) { $cursor = 0 }
        if ($n - $cursor -gt 2000) { $n = $cursor + 2000 }
        for ($i = $cursor; $i -lt $n; $i++) { $lines += ([string]$out[$i]) }
        $cursor = $n
        if (-not $completed -and $out.Count -gt 50000) { try { $Term.PS.Stop() } catch { }; $lines += '[output limit reached - command stopped]' }
    }
    $busy = -not $completed
    if ($completed -and $out -and $cursor -lt $out.Count) { $busy = $true }   # still draining
    if ($completed -and -not $Term.Finished -and -not $busy) {
        try { [void]$Term.PS.EndInvoke($Term.Handle) } catch { $lines += $_.Exception.InnerException.Message }
        try { foreach ($e in $Term.PS.Streams.Error) { $lines += ([string]$e) } } catch { }
        try { $Term.Cwd = $Term.Runspace.SessionStateProxy.Path.CurrentLocation.Path } catch { }
        $Term.Finished = $true
    }
    return @{ lines = @($lines); cursor = $cursor; busy = $busy; cwd = $Term.Cwd }
}
$Risky = @(
    @('\b(del|erase|rd|rmdir|rm|ri)\b', 'deletes files or folders'),
    @('\b(move|ren|rename|robocopy|xcopy)\b', 'moves, renames or bulk-copies files'),
    @('\b(format|diskpart|fsutil|vssadmin|bcdedit)\b|\bcipher\s+/w', 'changes disks or boot configuration'),
    @('\bshutdown\b', 'shuts down or restarts the computer'),
    @('\b(taskkill|kill|spps)\b', 'terminates processes'),
    @('\breg(\.exe)?\s+(add|delete|import|load|unload|restore)\b', 'modifies the registry'),
    @('\bnet1?\s+(user|localgroup|accounts|stop|share)\b', 'changes users, groups or services'),
    @('\bsc(\.exe)?\s+(delete|stop|config|create)\b', 'changes services'),
    @('\bschtasks\b.*\s/(create|delete|change)\b', 'changes scheduled tasks'),
    @('\bnetsh\b.*\b(firewall|advfirewall|reset|set|add|delete)\b', 'changes network or firewall settings'),
    @('\b(takeown|icacls|cacls|cmdkey|runas)\b', 'changes permissions or credentials'),
    @('\bwevtutil\s+(cl|clear-log)\b', 'clears event logs'),
    @('\b(certutil|bitsadmin|mshta)\b', 'can download or run remote content'),
    @('\b(Remove|Stop|Restart|Disable|Clear|Unregister|Uninstall|Format|Reset|Revoke|Block)-[A-Za-z]+', 'destructive or state-changing cmdlet'),
    @('\b(Set|New|Add|Enable|Install|Register|Grant)-(ExecutionPolicy|ItemProperty|LocalUser|LocalGroup\w*|Service|NetFirewall\w*|NetIPAddress|DnsClient\w*|AD\w+)\b', 'changes system or account configuration'),
    @('\b(Invoke-Expression|iex|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|DownloadString|DownloadFile|Start-BitsTransfer)\b', 'runs or downloads remote content'),
    @('(?<![\w-])-(EncodedCommand|enc|ec)\b', 'uses an encoded (hidden) command'),
    @('\bStart-Process\b.*-Verb\s+RunAs', 'requests elevation')
)
function Get-RiskReasons([string]$cmd) {
    $out = @()
    foreach ($r in $Risky) { if ([regex]::IsMatch($cmd, $r[0], 'IgnoreCase') -and ($out -notcontains $r[1])) { $out += $r[1] } }
    return ,$out
}
function Get-History {
    $res = @()
    if (Test-Path $AuditFile) {
        $tail = @(Get-Content -Path $AuditFile -Tail 400 -Encoding UTF8)
        for ($i = $tail.Count - 1; $i -ge 0 -and $res.Count -lt 30; $i--) {
            try { $r = $tail[$i] | ConvertFrom-Json } catch { continue }
            if ($r.event -eq 'command') { $res += @{ ts = $r.ts; command = $r.command } }
        }
    }
    return ,$res
}

# ---------------------------------------------------------------- app discovery + file picker
function Get-InstalledApps {
    if (-not $IsWin) { return ,@() }
    $dirs = @()
    if ($env:ProgramData) { $dirs += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') }
    if ($env:APPDATA) { $dirs += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') }
    $sh = New-Object -ComObject WScript.Shell
    $seen = @{}; $res = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($f in (Get-ChildItem -Path $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
            $name = $f.BaseName
            if ($name -match '(?i)uninstall|readme|release notes|license|documentation|^help$') { continue }
            if ($seen.ContainsKey($name.ToLower())) { continue }
            $target = ''
            try { $target = $sh.CreateShortcut($f.FullName).TargetPath } catch { }
            $seen[$name.ToLower()] = $true
            $res += @{ name = $name; path = $(if ($target) { $target } else { $f.FullName }) }
        }
    }
    return ,@($res | Sort-Object { $_.name } | Select-Object -First 500)
}
function Start-Pick {
    if ($State.Pick -and -not $State.Pick.HasExited) { return }
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -STA -WindowStyle Hidden -File `"$PickScript`""
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $State.Pick = [Diagnostics.Process]::Start($psi)
}

# ---------------------------------------------------------------- HTTP plumbing
$AllowedHosts = @("127.0.0.1:$Port", "localhost:$Port")
$AllowedOrigins = @("http://127.0.0.1:$Port", "http://localhost:$Port")
$Token = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $tb = New-Object byte[] 32; $rng.GetBytes($tb)
$Token = -join ($tb | ForEach-Object { $_.ToString('x2') })
$Csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

function Http([int]$code, $detail) { return [pscustomobject]@{ Code = $code; Detail = $detail } }
function Send-Bytes($ctx, [int]$code, [string]$type, [byte[]]$bytes, [string]$corp = 'same-origin') {
    $r = $ctx.Response
    $r.StatusCode = $code; $r.ContentType = $type
    $r.AddHeader('Content-Security-Policy', $Csp); $r.AddHeader('X-Frame-Options', 'DENY')
    $r.AddHeader('X-Content-Type-Options', 'nosniff'); $r.AddHeader('Referrer-Policy', 'no-referrer')
    $r.AddHeader('Cross-Origin-Resource-Policy', $corp); $r.AddHeader('Cache-Control', 'no-store')
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}
function Send-Text($ctx, [int]$code, [string]$text) { Send-Bytes $ctx $code 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($text)) }
function Send-Json($ctx, [int]$code, $obj) { Send-Bytes $ctx $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 8 -Compress))) }
function Test-TokenEqual([string]$a, [string]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int]$a[$i] -bxor [int]$b[$i]) }
    return ($d -eq 0)
}
function Read-Body($req) {
    if (-not $req.HasEntityBody) { return $null }
    if ($req.ContentLength64 -lt 0) { throw (Http 411 'Content-Length required') }
    if ($req.ContentLength64 -gt 262144) { throw (Http 413 'Request too large') }
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if (-not $txt.Trim()) { return $null }
    try { return ($txt | ConvertFrom-Json) } catch { throw (Http 400 'Invalid JSON') }
}

# ---------------------------------------------------------------- API
function Invoke-Api($req, [string]$method, [string]$path) {
    $key = "$method $path"
    if ($method -ne 'GET' -and $req.HasEntityBody -and ([string]$req.ContentType) -notlike 'application/json*') { throw (Http 415 'JSON required') }

    if ($key -eq 'GET /api/config') {
        $s = Read-Items 'sites'; $m = Read-Items 'monitors'; $a = Read-Items 'apps'; $r = Read-Items 'rdp'
        return @{ sites = $s; monitors = $m; apps = $a; rdp = $r; me = @{ user = [Environment]::UserName; computer = [Environment]::MachineName } }
    }
    if ($method -eq 'PUT' -and $path -match '^/api/items/(sites|monitors|apps|rdp)$') {
        $b = Read-Body $req
        if ($null -eq $b) { throw (Http 400 'Missing body') }
        return @{ items = (Save-Items $Matches[1] $b.items) }
    }
    if ($key -eq 'GET /api/status') {
        $list = @()
        foreach ($k in @($State.Results.Keys)) { $list += $State.Results[$k] }
        return @{ results = $list; interval = $State.Interval }
    }
    if ($key -eq 'POST /api/status/refresh') { $State.Wake.Set() | Out-Null; return @{ ok = $true } }

    if ($key -eq 'POST /api/launch/app') {
        $b = Read-Body $req; $item = Find-Item 'apps' $b.id
        if (-not $item) { throw (Http 404 'Application not found') }
        $sp = @{ FilePath = [string]$item.path }
        if ($item.args) { $sp.ArgumentList = [string]$item.args }
        if ($item.admin -eq $true) { $sp.Verb = 'RunAs' }
        try { Start-Process @sp } catch { throw (Http 400 $_.Exception.Message) }
        Write-Audit 'launch' @{ name = $item.name; path = $item.path; admin = ($item.admin -eq $true) }
        return @{ ok = $true }
    }
    if ($key -eq 'POST /api/launch/rdp') {
        $b = Read-Body $req; $item = Find-Item 'rdp' $b.id
        if (-not $item) { throw (Http 404 'Server not found') }
        if (-not (Test-RdpHost ([string]$item.host))) { throw (Http 400 'Invalid host') }
        try { Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:$($item.host)" } catch { throw (Http 400 $_.Exception.Message) }
        Write-Audit 'rdp' @{ name = $item.name; host = $item.host }
        return @{ ok = $true }
    }
    if ($key -eq 'GET /api/apps/discover') { $a = Get-InstalledApps; return @{ items = $a } }
    if ($key -eq 'POST /api/pick') { Start-Pick; return @{ ok = $true } }
    if ($key -eq 'GET /api/pick') {
        $p = $State.Pick
        if (-not $p) { return @{ done = $true; path = '' } }
        if (-not $p.HasExited) { return @{ done = $false; path = '' } }
        $path = $p.StandardOutput.ReadToEnd().Trim(); $State.Pick = $null
        return @{ done = $true; path = $path }
    }

    if ($key -eq 'POST /api/term/run') {
        $b = Read-Body $req; $cmd = [string]$b.command
        if (-not $cmd.Trim() -or $cmd.Length -gt 4000) { throw (Http 422 'Command must be 1-4000 characters') }
        if ($cmd -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { throw (Http 422 'Command contains invalid characters') }
        if (Test-TermBusy) { throw (Http 409 @{ busy = $true; message = 'A command is still running. Stop it first.' }) }
        $reasons = Get-RiskReasons $cmd
        if ($reasons.Count -gt 0 -and $b.confirm -ne $true) {
            Write-Audit 'command_pending_confirm' @{ command = (Protect-Secrets $cmd.Substring(0, [Math]::Min(500, $cmd.Length))) }
            throw (Http 409 @{ needs_confirm = $true; reasons = $reasons; message = 'This command needs confirmation.' })
        }
        Write-Audit 'command' @{ command = (Protect-Secrets $cmd.Substring(0, [Math]::Min(1000, $cmd.Length))); confirmed_risky = ($reasons.Count -gt 0) }
        Start-TermCommand $cmd
        return @{ ok = $true }
    }
    if ($key -eq 'GET /api/term/poll') {
        $c = 0; [void][int]::TryParse([string]$req.QueryString['cursor'], [ref]$c)
        return (Get-TermPoll $c)
    }
    if ($key -eq 'POST /api/term/stop') { if ($Term.PS -and (Test-TermBusy)) { try { $Term.PS.Stop() } catch { } }; Write-Audit 'term_stop'; return @{ ok = $true } }
    if ($key -eq 'POST /api/term/reset') { Reset-Term; Write-Audit 'term_reset'; return @{ ok = $true; cwd = $Term.Cwd } }
    if ($key -eq 'GET /api/history') { $h = Get-History; return @{ items = $h } }

    if ($key -eq 'POST /api/quit') { Write-Audit 'helper_quit'; $script:Quit = $true; return @{ ok = $true } }
    throw (Http 404 'Not found')
}

function Handle-Request($ctx) {
    $req = $ctx.Request; $method = $req.HttpMethod; $path = $req.Url.AbsolutePath
    if (-not [System.Net.IPAddress]::IsLoopback($req.RemoteEndPoint.Address)) { Write-Audit 'blocked_non_loopback'; Send-Text $ctx 403 'Forbidden'; return }
    $hostHdr = ([string]$req.Headers['Host']).ToLowerInvariant()
    if ($AllowedHosts -notcontains $hostHdr) { Send-Text $ctx 403 'Forbidden'; return }

    # /ping is the only endpoint readable cross-origin: it lets CommandCenter.html (opened from disk) see that we're alive. It returns "ok", no data.
    if ($method -eq 'GET' -and $path -eq '/ping') { Send-Bytes $ctx 200 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('ok')) 'cross-origin'; return }
    if ($method -eq 'GET' -and $path -eq '/') {
        $html = (Get-Content -Path (Join-Path $WebDir 'index.html') -Raw -Encoding UTF8).Replace('__TOKEN__', $Token)
        Send-Bytes $ctx 200 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($html)); return
    }
    if ($method -eq 'GET' -and $path -eq '/static/style.css') { Send-Bytes $ctx 200 'text/css; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $WebDir 'style.css'))); return }
    if ($method -eq 'GET' -and $path -eq '/static/app.js') { Send-Bytes $ctx 200 'application/javascript; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $WebDir 'app.js'))); return }
    if (-not $path.StartsWith('/api/')) { Send-Text $ctx 404 'Not found'; return }

    $site = [string]$req.Headers['Sec-Fetch-Site']
    if ($site -and $site -ne 'same-origin' -and $site -ne 'none') { Write-Audit 'blocked_cross_site' @{ path = $path }; Send-Text $ctx 403 'Forbidden'; return }
    if ($method -ne 'GET' -and $AllowedOrigins -notcontains [string]$req.Headers['Origin']) { Write-Audit 'blocked_bad_origin' @{ path = $path }; Send-Text $ctx 403 'Forbidden'; return }
    if (-not (Test-TokenEqual ([string]$req.Headers['X-CC-Token']) $Token)) {
        Write-Audit 'auth_failure' @{ path = $path }
        Send-Json $ctx 401 @{ detail = 'Session expired. Reload the page.' }; return
    }
    try {
        $result = Invoke-Api $req $method $path
        Send-Json $ctx 200 $result
    } catch {
        $o = $_.TargetObject
        if ($o -is [pscustomobject] -and $o.PSObject.Properties['Code']) { Send-Json $ctx $o.Code @{ detail = $o.Detail } }
        elseif ($o -is [string]) { Send-Json $ctx 422 @{ detail = $_.Exception.Message } }
        else { Write-Audit 'internal_error' @{ path = $path; error = $_.Exception.Message }; Send-Json $ctx 500 @{ detail = 'Internal error' } }
    }
}

# ---------------------------------------------------------------- start
Initialize-Defaults
Update-Targets
Reset-Term
Start-Monitor
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Audit 'start_failed' @{ error = $_.Exception.Message }; exit 1 }
Write-Audit 'helper_started' @{ port = $Port }
if ($env:OCC_TEST_TOKEN_FILE) { Set-Content -Path $env:OCC_TEST_TOKEN_FILE -Value $Token }   # test hook only
$script:Quit = $false
while ($listener.IsListening -and -not $script:Quit) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    try { Handle-Request $ctx } catch { try { $ctx.Response.Abort() } catch { } }
}
try { $listener.Stop() } catch { }
