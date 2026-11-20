# handy-panel.ps1 - the workers panel: a small web page on this PC to choose which models do the work.
# It listens only on this computer (http://localhost:8765). Nothing is reachable from the network.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File handy-panel.ps1 [-Port 8765] [-Open]
# Stop it with Ctrl+C, or close its window.
param([int]$Port = 8765, [switch]$Open)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'handy-config.ps1')
$root = Split-Path $PSScriptRoot -Parent
$page = Join-Path $root 'panel\index.html'
$jobsDir = Join-Path $root 'jobs'
$prefix = "http://localhost:$Port/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "handy-llm panel: $prefix  (Ctrl+C to stop)"
if ($Open) { Start-Process $prefix }

function Send($ctx, [int]$code, $body, [string]$type = 'application/json; charset=utf-8') {
  $bytes = if ($body -is [byte[]]) { $body } else { [Text.Encoding]::UTF8.GetBytes([string]$body) }
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers['Cache-Control'] = 'no-store'
  $ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
function SendJson($ctx, $obj, [int]$code = 200) { Send $ctx $code ($obj | ConvertTo-Json -Depth 8 -Compress) }
function ReadBody($ctx) {
  $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
  $t = $sr.ReadToEnd(); $sr.Close()
  if ($t) { return ($t | ConvertFrom-Json) } else { return $null }
}

# Workers as the page sees them: never the key itself, only whether one is stored.
function PublicConfig {
  $cfg = Get-HandyConfig
  $ws = foreach ($w in $cfg.workers) {
    $o = [ordered]@{}; foreach ($p in $w.PSObject.Properties) { $o[$p.Name] = $p.Value }
    $o.hasKey = (Test-HandyHasKey $w.id); [pscustomobject]$o
  }
  return [ordered]@{ workers = @($ws); lanes = $cfg.lanes }
}

function ListModels($w) {
  $base = ([string]$w.baseUrl).TrimEnd('/')
  if ($w.api -eq 'ollama') {
    $r = Invoke-RestMethod -Uri "$base/api/tags" -TimeoutSec 8
    return @($r.models | ForEach-Object { $_.name } | Sort-Object)
  }
  $h = @{}; $k = Get-HandyKey $w.id; if ($k) { $h['Authorization'] = "Bearer $k" }
  $r = Invoke-RestMethod -Uri "$base/models" -Headers $h -TimeoutSec 15
  $list = if ($r.data) { $r.data } elseif ($r.result) { $r.result } else { $r }
  return @($list | ForEach-Object { if ($_.id) { $_.id } elseif ($_.name) { $_.name } } | Where-Object { $_ } | Sort-Object -Unique)
}

function Status {
  $o = [ordered]@{ time = (Get-Date).ToString('HH:mm:ss'); ollama = $null; loaded = @(); servers = @(); jobs = @(); usage = @() }
  try { $o.ollama = (Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2).version } catch {}
  if ($o.ollama) {
    try { $o.loaded = @((Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 3).models | ForEach-Object { [ordered]@{ name = $_.name; sizeGB = [math]::Round($_.size / 1GB, 1); vramGB = [math]::Round($_.size_vram / 1GB, 1); until = $_.expires_at } }) } catch {}
  }
  foreach ($w in (Get-HandyConfig).workers) {
    if ($w.kind -ne 'local' -or $w.api -ne 'openai') { continue }
    $up = $false; try { Invoke-WebRequest -UseBasicParsing -Uri (([string]$w.baseUrl).TrimEnd('/') + '/models') -TimeoutSec 2 | Out-Null; $up = $true } catch {}
    $o.servers += [ordered]@{ id = $w.id; name = $w.name; up = $up }
  }
  if (Test-Path $jobsDir) {
    $o.jobs = @(Get-ChildItem $jobsDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
      $q = Join-Path $_.FullName '_queue.status'
      [ordered]@{ name = $_.Name; status = $(if (Test-Path $q) { (Get-Content -Raw -Encoding UTF8 $q).Trim() } else { '' }); changed = $_.LastWriteTime.ToString('dd/MM HH:mm') }
    })
  }
  $u = Join-Path (Get-HandyDataDir) 'usage.jsonl'
  if (Test-Path $u) {
    $rows = Get-Content -Encoding UTF8 $u | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $o.usage = @($rows | Group-Object worker | ForEach-Object {
      $g = $_.Group
      [ordered]@{ worker = $_.Name; kind = $g[0].kind; tasks = $g.Count; ok = @($g | Where-Object { $_.ok }).Count; tokensOut = ($g | Measure-Object tokensOut -Sum).Sum; tokensIn = ($g | Measure-Object tokensIn -Sum).Sum; today = @($g | Where-Object { $_.time -like "$today*" }).Count }
    })
  }
  return $o
}

function SaveConfig($in) {
  $cfg = Get-HandyConfig
  $ids = @{}
  $workers = foreach ($w in $in.workers) {
    if (-not (Test-HandyId ([string]$w.id))) { throw "invalid worker id: $($w.id)" }
    if ([string]$w.baseUrl -notmatch '^https?://') { throw "invalid URL for $($w.id)" }
    $ids[[string]$w.id] = $true
    # Local or cloud is decided by the address, never by the page: the private lane relies on it.
    $isLocal = ([string]$w.baseUrl -match '^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(/|$)')
    [ordered]@{
      id = [string]$w.id; name = [string]$w.name; kind = $(if ($isLocal) { 'local' } else { 'cloud' })
      tier = $(if ($isLocal) { 'local' } elseif ($w.tier -eq 'paid') { 'paid' } else { 'free' }); custom = [bool]$w.custom
      api = $(if ($w.api -eq 'ollama') { 'ollama' } else { 'openai' }); baseUrl = [string]$w.baseUrl
      model = [string]$w.model; enabled = [bool]$w.enabled; filesCapable = [bool]$w.filesCapable
    }
  }
  $lanes = [ordered]@{}
  foreach ($l in @('text','code','files','private')) { $lanes[$l] = @(@($in.lanes.$l) | Where-Object { $ids[[string]$_] } | ForEach-Object { [string]$_ }) }
  Save-HandyConfig ([ordered]@{ version = 1; workers = @($workers); lanes = $lanes })
  # drop keys of removed workers
  Get-ChildItem (Join-Path (Get-HandyDataDir) 'keys') -Filter *.key | Where-Object { -not $ids[$_.BaseName] } | Remove-Item -ErrorAction SilentlyContinue
}

while ($listener.IsListening) {
  try { $ctx = $listener.GetContext() } catch { break }
  try {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    # Only this page may call the API: the Host must be ours (blocks DNS rebinding), and every write
    # must carry the X-Handy header, which a web page on another site cannot send without our consent.
    $hostOk = ($req.Headers['Host'] -in @("localhost:$Port", "127.0.0.1:$Port"))
    if (-not $hostOk) { Send $ctx 403 'forbidden' 'text/plain'; continue }
    if ($req.HttpMethod -eq 'POST' -and $req.Headers['X-Handy'] -ne '1') { Send $ctx 403 'forbidden' 'text/plain'; continue }

    if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      Send $ctx 200 ([IO.File]::ReadAllBytes($page)) 'text/html; charset=utf-8'
    } elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/config') {
      SendJson $ctx (PublicConfig)
    } elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
      SendJson $ctx (Status)
    } elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/config') {
      SaveConfig (ReadBody $ctx); SendJson $ctx (PublicConfig)
    } elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/key') {
      $b = ReadBody $ctx; Set-HandyKey ([string]$b.id) ([string]$b.key); SendJson $ctx @{ ok = $true; hasKey = (Test-HandyHasKey ([string]$b.id)) }
    } elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/models') {
      $b = ReadBody $ctx; $w = (Get-HandyConfig).workers | Where-Object { $_.id -eq $b.id } | Select-Object -First 1
      if (-not $w) { SendJson $ctx @{ error = 'unknown worker (save first)' } 400; continue }
      try { SendJson $ctx @{ models = @(ListModels $w) } } catch { SendJson $ctx @{ error = $_.Exception.Message } 502 }
    } elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/test') {
      $b = ReadBody $ctx; $w = (Get-HandyConfig).workers | Where-Object { $_.id -eq $b.id } | Select-Object -First 1
      if (-not $w) { SendJson $ctx @{ error = 'unknown worker (save first)' } 400; continue }
      try {
        if (-not $w.model) { throw 'no model selected' }
        $k = Get-HandyKey $w.id
        if ($w.kind -eq 'cloud' -and -not $k) { throw 'no API key' }
        $r = Invoke-HandyChat $w $k @(@{ role = 'user'; content = 'Reply with the single word OK.' }) -Timeout 120
        SendJson $ctx @{ ok = $true; answer = $r.content.Trim(); seconds = [math]::Round($r.seconds, 1); tokensOut = $r.tokensOut }
      } catch { SendJson $ctx @{ ok = $false; error = $_.Exception.Message } 200 }
    } else {
      Send $ctx 404 'not found' 'text/plain'
    }
  } catch {
    try { SendJson $ctx @{ error = $_.Exception.Message } 500 } catch {}
  }
}
