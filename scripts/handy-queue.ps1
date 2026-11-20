# handy-queue.ps1 - run every task file (*.txt) of a folder, one after another, with handy.ps1.
# Tasks already finished with OK are skipped, so the queue can be restarted safely.
# Files whose name starts with _ are notes, not tasks, and are skipped too.
#
# Usage (in the background):
#   Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<path>\handy-queue.ps1"','-Folder','"<job folder>"'
# Optional: -Lane text|code|private (workers chosen in the panel), or -Api openai -BaseUrl <url> -Model <model>,
# plus -Think -Json -Ctx <n>. Everything is passed to handy.ps1.
# Progress: <job folder>\_queue.status  (RUNNING | n of N | file, then DONE | N tasks | time)
param(
  [Parameter(Mandatory=$true)][string]$Folder,
  [string]$Lane = "",
  [string]$Api = "",
  [string]$BaseUrl = "",
  [string]$Model = "",
  [int]$Ctx = 0,
  [switch]$Think,
  [switch]$Json
)
$utf8 = New-Object System.Text.UTF8Encoding $false
$done = Join-Path $Folder '_queue.status'
$list = @(Get-ChildItem $Folder -Filter *.txt | Where-Object { $_.Name -notmatch '\.result\.txt$' -and $_.Name -notmatch '^_' } | Sort-Object Name)
$extra = @()
if ($Lane) { $extra += '-Lane', $Lane }
if ($Api) { $extra += '-Api', $Api }
if ($BaseUrl) { $extra += '-BaseUrl', $BaseUrl }
if ($Model) { $extra += '-Model', $Model }
if ($Ctx -gt 0) { $extra += '-Ctx', $Ctx }
if ($Think) { $extra += '-Think' }
if ($Json) { $extra += '-Json' }
$n = 0
foreach ($f in $list) {
  $n++
  [IO.File]::WriteAllText($done, "RUNNING | $n of $($list.Count) | $($f.Name)", $utf8)
  $out = [IO.Path]::ChangeExtension($f.FullName, '.result.txt')
  if (Test-Path "$out.status") { if ((Get-Content -Raw -Encoding UTF8 "$out.status") -match '^OK') { continue } }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'handy.ps1') -Task $f.FullName @extra
}
[IO.File]::WriteAllText($done, "DONE | $($list.Count) tasks | " + (Get-Date -Format 'HH:mm:ss'), $utf8)
