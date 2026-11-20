# handy.ps1 - run ONE text task on a worker (a local or cloud LLM) and write the result to a file.
#
# Two ways to choose the worker:
#   1. Lanes (default): the workers you picked in the panel (handy-panel.ps1) for a lane, in order.
#      If one fails or returns an empty answer, the next one takes over.
#        powershell -NoProfile -ExecutionPolicy Bypass -File handy.ps1 -Task <task.txt> [-Lane text|code|private]
#      The private lane uses only local workers, unless the user allowed cloud workers in the panel.
#   2. Direct: name the server yourself (no panel needed).
#        powershell ... -File handy.ps1 -Task <task.txt> -Api ollama -Model qwen3.8-cc
#        powershell ... -File handy.ps1 -Task <task.txt> -Api openai -BaseUrl http://127.0.0.1:1234/v1 -Model <model-id>
#
# Output: <task>.result.txt and <task>.result.txt.status (RUNNING, OK or ERROR, plus which worker answered).
param(
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$Output = "",
  [ValidateSet('text','code','private')][string]$Lane = 'text',
  [ValidateSet('ollama','openai')][string]$Api,
  [string]$BaseUrl,
  [string]$Model,
  [string]$ApiKey,
  [int]$Ctx = 65536,
  [switch]$Think,
  [switch]$Json,
  [string]$System = "You are a precise executor. Do only the requested task and return only the result: no preamble, no comments, no code fences unless requested.",
  [double]$Temperature = 0.3,
  [int]$Timeout = 1800
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'handy-config.ps1')
$utf8 = New-Object System.Text.UTF8Encoding $false
if (-not $Output) { $Output = [IO.Path]::ChangeExtension($Task, '.result.txt') }
$status = "$Output.status"

# Direct mode when the caller names the server, or the old HANDY_* variables are set.
$direct = $PSBoundParameters.ContainsKey('Api') -or $PSBoundParameters.ContainsKey('BaseUrl') -or $PSBoundParameters.ContainsKey('Model') -or $env:HANDY_MODEL -or $env:HANDY_BASE_URL -or $env:HANDY_API
if ($direct) {
  if (-not $Api) { $Api = if ($env:HANDY_API) { $env:HANDY_API } else { 'ollama' } }
  if (-not $BaseUrl) { $BaseUrl = if ($env:HANDY_BASE_URL) { $env:HANDY_BASE_URL } elseif ($Api -eq 'ollama') { 'http://127.0.0.1:11434' } else { 'http://127.0.0.1:1234/v1' } }
  if (-not $Model) { $Model = if ($env:HANDY_MODEL) { $env:HANDY_MODEL } else { 'qwen3.8-cc' } }
  if (-not $ApiKey) { $ApiKey = $env:HANDY_API_KEY }
  $kind = if ($BaseUrl -match '^https?://(127\.0\.0\.1|localhost|\[::1\])[:/]') { 'local' } else { 'cloud' }
  $workers = @([pscustomobject]@{ id = 'direct'; name = 'direct'; kind = $kind; api = $Api; baseUrl = $BaseUrl; model = $Model; direct = $true })
} else {
  $cfg = Get-HandyConfig
  $workers = Get-HandyLaneWorkers $cfg $Lane
}

$messages = @(@{ role = 'system'; content = $System })
$failures = @()
try {
  [IO.File]::WriteAllText($status, "RUNNING | started " + (Get-Date -Format 'HH:mm:ss'), $utf8)
  if ($workers.Count -eq 0) { throw "no enabled worker in lane '$Lane' (open the panel: scripts\handy-panel.ps1)" }
  $text = [IO.File]::ReadAllText($Task, [Text.Encoding]::UTF8)
  $messages += @{ role = 'user'; content = $text }
  foreach ($w in $workers) {
    if (-not $w.model) { $failures += "$($w.name): no model selected"; continue }
    $key = if ($w.direct) { $ApiKey } else { Get-HandyKey $w.id }
    if ($w.kind -eq 'cloud' -and -not $key) { $failures += "$($w.name): no API key"; continue }
    if ($Lane -eq 'private' -and (Test-HandyCloud $w) -and -not ($cfg -and $cfg.allowCloudPrivate)) { $failures += "$($w.name): cloud model skipped for private data"; continue }
    try {
      [IO.File]::WriteAllText($status, "RUNNING | started " + (Get-Date -Format 'HH:mm:ss') + " | worker $($w.name)", $utf8)
      $r = Invoke-HandyChat $w $key $messages -temperature $Temperature -Json:$Json -Think:$Think -Ctx $Ctx -Timeout $Timeout
      $ok = [bool]($r.content.Trim())
      $isCloud = Test-HandyCloud $w
      if (-not $w.direct) { Add-HandyUsage ([ordered]@{ time = (Get-Date).ToString('s'); worker = $w.id; kind = $(if ($isCloud) { 'cloud' } else { 'local' }); model = $w.model; lane = $Lane; ok = $ok; tokensIn = $r.tokensIn; tokensOut = $r.tokensOut; seconds = [math]::Round($r.seconds, 1) }) }
      if (-not $ok) { $failures += "$($w.name): empty answer after $($r.tokensOut) tokens"; continue }
      [IO.File]::WriteAllText($Output, $r.content, $utf8)
      $info = "OK | {0} ({1}) | lane {2} | total {3:N0}s | tokens in {4} | tokens out {5}" -f $w.name, $w.model, $Lane, $r.seconds, $r.tokensIn, $r.tokensOut
      if ($r.tps) { $info += " | {0:N1} tok/s" -f $r.tps }
      if ($w.api -eq 'ollama' -and $r.tokensIn -ge ($Ctx * 0.95)) { $info += " | WARNING: task possibly TRUNCATED, raise -Ctx or split the text" }
      if ($r.cut) { $info += " | WARNING: answer CUT by length" }
      if ($isCloud -and $Lane -eq 'private') { $info += " | WARNING: PRIVATE data sent to a cloud service (allowed in the panel)" }
      elseif ($isCloud) { $info += " | NOTE: data sent to a cloud service" }
      if ($failures.Count) { $info += " | fallback after: " + ($failures -join '; ') }
      [IO.File]::WriteAllText($status, $info, $utf8)
      exit 0
    } catch {
      $failures += "$($w.name): " + $_.Exception.Message
    }
  }
  throw ("all workers failed: " + ($failures -join '; '))
} catch {
  [IO.File]::WriteAllText($status, "ERROR | " + $_.Exception.Message, $utf8)
  exit 1
}
