# handy-files.ps1 - let a local LLM read and edit the files of ONE folder, through Claude Code.
# Claude Code talks to any Anthropic-compatible endpoint: Ollama exposes one at http://127.0.0.1:11434.
# Permission mode acceptEdits: the model can read and edit files in the folder, it cannot run shell commands.
# Nothing is billed: every request goes to the local model (the "cost" Claude Code prints is only an estimate).
#
# Usage (in the background):
#   Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<path>\handy-files.ps1"','-Folder','"<work folder>"','-Task','"<task.txt>"'
# Output: <task>.files.status (RUNNING / OK / ERROR + the model's final answer) and <task>.files.json
param(
  [Parameter(Mandatory=$true)][string]$Folder,
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$Model = $env:HANDY_MODEL,
  [string]$BaseUrl = $env:HANDY_ANTHROPIC_URL,
  [string]$Token = 'ollama',
  [int]$MaxTurns = 40
)
$utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'handy-config.ps1')
# Without -Model/-BaseUrl, use the first enabled worker of the "files" lane chosen in the panel
# (only workers with an Anthropic-compatible endpoint, such as Ollama, can drive Claude Code).
if (-not $Model -or -not $BaseUrl) {
  $w = @(Get-HandyLaneWorkers (Get-HandyConfig) 'files') | Select-Object -First 1
  if ($w) { if (-not $Model) { $Model = $w.model }; if (-not $BaseUrl) { $BaseUrl = $w.baseUrl } }
  if (-not $Model) { $Model = 'qwen3.8-cc' }
  if (-not $BaseUrl) { $BaseUrl = 'http://127.0.0.1:11434' }
}
$base = [IO.Path]::ChangeExtension($Task, $null).TrimEnd('.')
$status = "$base.files.status"; $output = "$base.files.json"
[IO.File]::WriteAllText($status, "RUNNING | started " + (Get-Date -Format 'HH:mm:ss'), $utf8)
try {
  $env:ANTHROPIC_BASE_URL = $BaseUrl
  $env:ANTHROPIC_AUTH_TOKEN = $Token
  $env:ANTHROPIC_API_KEY = ''
  $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
  $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
  $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model
  $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $text = [IO.File]::ReadAllText($Task, [Text.Encoding]::UTF8)
  Set-Location $Folder
  $t0 = Get-Date
  $ErrorActionPreference = 'Continue'
  $OutputEncoding = New-Object System.Text.UTF8Encoding $false
  # The task goes through standard input: as a command-line argument, Windows PowerShell 5.1 splits it at quotes.
  $out = $text | & claude -p --model $Model --permission-mode acceptEdits --output-format json --max-turns $MaxTurns 2>$null
  $code = $LASTEXITCODE
  $json = ($out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
  [IO.File]::WriteAllText($output, [string]$json, $utf8)
  $j = $json | ConvertFrom-Json
  $models = ($j.modelUsage.PSObject.Properties.Name) -join ', '
  $local = if ($models -eq $Model) { 'local only' } else { "WARNING models used: $models" }
  $info = "{0} | {1:N0}s | turns {2} | {3} | result {4} | exit {5}" -f $(if ($j.is_error) {'ERROR'} else {'OK'}), ((Get-Date) - $t0).TotalSeconds, $j.num_turns, $local, $j.subtype, $code
  [IO.File]::WriteAllText($status, $info + "`nANSWER: " + [string]$j.result, $utf8)
} catch {
  [IO.File]::WriteAllText($status, "ERROR | " + $_.Exception.Message, $utf8)
  exit 1
}
