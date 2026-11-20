# handy-config.ps1 - shared helpers for the workers configuration (dot-source it).
# Everything personal lives outside the repository, in %USERPROFILE%\.handy-llm:
#   workers.json  the workers (local and cloud models) and the lanes
#   keys\<id>.key API keys, encrypted with Windows DPAPI (readable only by this Windows user)
#   usage.jsonl   one line per task: worker, lane, tokens, seconds, result

$script:HandyData = if ($env:HANDY_DATA) { $env:HANDY_DATA } else { Join-Path $env:USERPROFILE '.handy-llm' }
$script:Utf8 = New-Object System.Text.UTF8Encoding $false

function Get-HandyDataDir {
  foreach ($d in @($script:HandyData, (Join-Path $script:HandyData 'keys'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
  return $script:HandyData
}

function New-HandyDefaultConfig {
  $w = @(
    [ordered]@{ id='ollama'; name='Ollama'; kind='local'; tier='local'; api='ollama'; baseUrl='http://127.0.0.1:11434'; model='qwen3.8-cc'; enabled=$true; filesCapable=$true }
    [ordered]@{ id='llamacpp'; name='llama.cpp server'; kind='local'; tier='local'; api='openai'; baseUrl='http://127.0.0.1:8080/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='lmstudio'; name='LM Studio'; kind='local'; tier='local'; api='openai'; baseUrl='http://127.0.0.1:1234/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='groq'; name='Groq'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://api.groq.com/openai/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='cerebras'; name='Cerebras'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://api.cerebras.ai/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='google'; name='Google AI Studio'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://generativelanguage.googleapis.com/v1beta/openai'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='mistral'; name='Mistral'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://api.mistral.ai/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='openrouter'; name='OpenRouter'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://openrouter.ai/api/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='cloudflare'; name='Cloudflare Workers AI'; kind='cloud'; tier='free'; api='openai'; baseUrl='https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/v1'; model=''; enabled=$false; filesCapable=$false }
    [ordered]@{ id='anthropic'; name='Anthropic (Claude)'; kind='cloud'; tier='paid'; api='openai'; baseUrl='https://api.anthropic.com/v1'; model=''; enabled=$false; filesCapable=$false }
  )
  return [ordered]@{
    version = 1
    workers = $w
    lanes = [ordered]@{ text = @('ollama'); code = @('ollama'); files = @('ollama'); private = @('ollama') }
  }
}

function Get-HandyConfig {
  $f = Join-Path (Get-HandyDataDir) 'workers.json'
  if (-not (Test-Path $f)) { Save-HandyConfig (New-HandyDefaultConfig) }
  return ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Save-HandyConfig($cfg) {
  $f = Join-Path (Get-HandyDataDir) 'workers.json'
  [IO.File]::WriteAllText($f, ($cfg | ConvertTo-Json -Depth 8), $script:Utf8)
}

function Test-HandyId([string]$id) { return ($id -match '^[a-z0-9][a-z0-9-]{0,40}$') }

function Set-HandyKey([string]$id, [string]$key) {
  if (-not (Test-HandyId $id)) { throw "invalid worker id" }
  $f = Join-Path (Join-Path (Get-HandyDataDir) 'keys') "$id.key"
  if (-not $key) { Remove-Item $f -ErrorAction SilentlyContinue; return }
  $enc = ConvertTo-SecureString $key -AsPlainText -Force | ConvertFrom-SecureString
  [IO.File]::WriteAllText($f, $enc, $script:Utf8)
}

function Get-HandyKey([string]$id) {
  if (-not (Test-HandyId $id)) { return '' }
  $f = Join-Path (Join-Path (Get-HandyDataDir) 'keys') "$id.key"
  if (-not (Test-Path $f)) { return '' }
  $sec = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8).Trim() | ConvertTo-SecureString
  return (New-Object System.Net.NetworkCredential('', $sec)).Password
}

function Test-HandyHasKey([string]$id) {
  if (-not (Test-HandyId $id)) { return $false }
  return (Test-Path (Join-Path (Join-Path (Get-HandyDataDir) 'keys') "$id.key"))
}

# A worker is cloud when its address is not this PC, or when its model runs in someone else's cloud
# even though it is reached through a local server (Ollama's "name:cloud" models).
function Test-HandyCloud($w) {
  if ([string]$w.baseUrl -notmatch '^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(/|$)') { return $true }
  return ([string]$w.model -match '(:|-)cloud$')
}

# Workers of a lane, in order, enabled only. The private lane never returns cloud workers.
function Get-HandyLaneWorkers($cfg, [string]$lane) {
  $ids = @($cfg.lanes.$lane)
  $out = @()
  foreach ($id in $ids) {
    $w = $cfg.workers | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $w -or -not $w.enabled) { continue }
    if ($lane -eq 'private' -and (Test-HandyCloud $w)) { continue }
    if ($lane -eq 'files' -and -not $w.filesCapable) { continue }
    $out += $w
  }
  return ,$out
}

function Add-HandyUsage($entry) {
  $f = Join-Path (Get-HandyDataDir) 'usage.jsonl'
  $line = ($entry | ConvertTo-Json -Compress -Depth 4)
  [IO.File]::AppendAllText($f, $line + "`n", $script:Utf8)
}

# One chat call to a worker. Returns an object with content, tokens, seconds, finish.
function Invoke-HandyChat($worker, [string]$key, $messages, [double]$temperature = 0.3, [switch]$Json, [switch]$Think, [int]$Ctx = 65536, [int]$Timeout = 1800, [string]$KeepAlive = '10m') {
  $base = ([string]$worker.baseUrl).TrimEnd('/')
  $headers = @{}
  if ($key) { $headers['Authorization'] = "Bearer $key" }
  if ($worker.api -eq 'ollama') {
    $body = [ordered]@{ model = $worker.model; stream = $false; think = [bool]$Think; keep_alive = $KeepAlive; options = @{ num_ctx = $Ctx; temperature = $temperature }; messages = $messages }
    if ($Json) { $body.format = 'json' }
    $uri = "$base/api/chat"
  } else {
    $body = [ordered]@{ model = $worker.model; stream = $false; temperature = $temperature; messages = $messages }
    if ($Json) { $body.response_format = @{ type = 'json_object' } }
    $uri = "$base/chat/completions"
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  $t0 = Get-Date
  $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $Timeout
  $r = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
  $sec = ((Get-Date) - $t0).TotalSeconds
  if ($worker.api -eq 'ollama') {
    $tps = 0; if ($r.eval_duration) { $tps = $r.eval_count / ($r.eval_duration / 1e9) }
    return [pscustomobject]@{ content = [string]$r.message.content; tokensIn = [int]$r.prompt_eval_count; tokensOut = [int]$r.eval_count; seconds = $sec; load = ($r.load_duration / 1e9); tps = $tps; cut = ($r.done_reason -eq 'length') }
  }
  return [pscustomobject]@{ content = [string]$r.choices[0].message.content; tokensIn = [int]$r.usage.prompt_tokens; tokensOut = [int]$r.usage.completion_tokens; seconds = $sec; load = 0; tps = 0; cut = ($r.choices[0].finish_reason -eq 'length') }
}
