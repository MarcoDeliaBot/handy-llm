# Packs a skill folder into a .zip that claude.ai accepts (Plugin > Aggiungi/Add > Upload).
# Usage: .\scripts\make-skill-zip.ps1 [-Skill handy-llm] [-Out dist]
param([string]$Skill = 'handy-llm', [string]$Out = 'dist')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "skills\$Skill"
$md = Join-Path $src 'SKILL.md'
if (-not (Test-Path $md)) { throw "SKILL.md not found in $src" }
$text = [IO.File]::ReadAllText($md, [Text.Encoding]::UTF8)
if ($text -notmatch '(?s)^---\n.*?\n---\n') { throw 'SKILL.md must start with YAML frontmatter and use LF line endings' }
if ($text -match '(?m)^description:\s*"?(.*?)"?\s*$' -and $matches[1].Length -gt 200) { throw "description is $($matches[1].Length) characters: claude.ai accepts at most 200" }
$outDir = Join-Path $root $Out
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$zip = Join-Path $outDir "$Skill.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\').Replace('\', '/')
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $_.FullName, "$Skill/$rel") | Out-Null
  }
} finally { $z.Dispose() }
"OK | $zip"