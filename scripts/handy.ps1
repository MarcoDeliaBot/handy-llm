# handy.ps1 - run ONE text task on a local LLM and write the result to a file.
# Works with Ollama (native API) or any OpenAI-compatible server
# (LM Studio, llama.cpp server, vLLM, Ollama's /v1, ...).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File handy.ps1 -Task <task.txt> [-Think] [-Json]
#   powershell ... -File handy.ps1 -Task <task.txt> -Api openai -BaseUrl http://127.0.0.1:1234/v1 -Model <model-id>
#
# Output: <task>.result.txt and <task>.result.txt.status
#   status starts with RUNNING, OK or ERROR.
param(
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$Output = "",
  [ValidateSet('ollama','openai')][string]$Api = $(if ($env:HANDY_API) { $env:HANDY_API } else { 'ollama' }),
  [string]$BaseUrl = $env:HANDY_BASE_URL,
  [string]$Model = $(if ($env:HANDY_MODEL) { $env:HANDY_MODEL } else { 'qwen3.8-cc' }),
  [string]$ApiKey = $env:HANDY_API_KEY,
  [int]$Ctx = 65536,
  [switch]$Think,
  [switch]$Json,
  [string]$System = "You are a precise executor. Do only the requested task and return only the result: no preamble, no comments, no code fences unless requested.",
  [string]$KeepAlive = "10m",
  [double]$Temperature = 0.3,
  [int]$Timeout = 1800
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
if (-not $Output) { $Output = [IO.Path]::ChangeExtension($Task, '.result.txt') }
if (-not $BaseUrl) { $BaseUrl = if ($Api -eq 'ollama') { 'http://127.0.0.1:11434' } else { 'http://127.0.0.1:1234/v1' } }
$BaseUrl = $BaseUrl.TrimEnd('/')
$status = "$Output.status"
try {
  [IO.File]::WriteAllText($status, "RUNNING | started " + (Get-Date -Format 'HH:mm:ss'), $utf8)
  $text = [IO.File]::ReadAllText($Task, [Text.Encoding]::UTF8)
  $messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $text })
  if ($Api -eq 'ollama') {
    $body = [ordered]@{
      model = $Model; stream = $false; think = [bool]$Think; keep_alive = $KeepAlive
      options = @{ num_ctx = $Ctx; temperature = $Temperature }
      messages = $messages
    }
    if ($Json) { $body.format = 'json' }
    $uri = "$BaseUrl/api/chat"
  } else {
    $body = [ordered]@{ model = $Model; stream = $false; temperature = $Temperature; messages = $messages }
    if ($Json) { $body.response_format = @{ type = 'json_object' } }
    $uri = "$BaseUrl/chat/completions"
  }
  $headers = @{}
  if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  $t0 = Get-Date
  $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $Timeout
  $r = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
  $sec = ((Get-Date) - $t0).TotalSeconds
  if ($Api -eq 'ollama') {
    $content = [string]$r.message.content
    $inTok = $r.prompt_eval_count; $outTok = $r.eval_count
    $tps = 0; if ($r.eval_duration) { $tps = $r.eval_count / ($r.eval_duration / 1e9) }
    $cut = ($r.done_reason -eq 'length')
    $info = "OK | {0} | total {1:N0}s | load {2:N0}s | tokens in {3} | tokens out {4} | {5:N1} tok/s" -f $Model, $sec, ($r.load_duration / 1e9), $inTok, $outTok, $tps
    if ($inTok -ge ($Ctx * 0.95)) { $info += " | WARNING: task possibly TRUNCATED, raise -Ctx or split the text" }
  } else {
    $content = [string]$r.choices[0].message.content
    $inTok = $r.usage.prompt_tokens; $outTok = $r.usage.completion_tokens
    $cut = ($r.choices[0].finish_reason -eq 'length')
    $info = "OK | {0} | total {1:N0}s | tokens in {2} | tokens out {3}" -f $Model, $sec, $inTok, $outTok
  }
  [IO.File]::WriteAllText($Output, $content, $utf8)
  if ($cut) { $info += " | WARNING: answer CUT by length" }
  [IO.File]::WriteAllText($status, $info, $utf8)
} catch {
  [IO.File]::WriteAllText($status, "ERROR | " + $_.Exception.Message, $utf8)
  exit 1
}
