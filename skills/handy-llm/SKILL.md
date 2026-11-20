---
name: handy-llm
description: "Chat mode: after 'use handy' or 'use the local model', Claude splits every job, hands the routine pieces to a local LLM (Ollama or any OpenAI-compatible server) instead of a paid helper model, then checks everything."
---

# handy-llm: a local LLM as free hands

Pattern: **Claude = brain** (splits the job, writes the tasks, checks the results) → **local LLM = hands** (runs on the user's own PC) → **Claude checks** before delivering.
The hands cost **zero tokens** (only electricity). Only Claude's own tokens for splitting, writing tasks and checking are paid.

Reply in the user's language. Result first, tables when there are more than three data points.

---

## 0. Mode: switch it on once, it stays on for the whole chat

**On:** the user writes "from now on use this skill" (or "use handy", "local hands"). From then on it applies to **every later message** in the chat; the user does not repeat it.
**Off:** only when the user says so ("stop handy", "back to the cloud helper").

When switched on: confirm in one line and run the check in §2 at once, so the first job starts without waiting.

**For every job:**
1. **Split** it into small, closed pieces.
2. **Route** each piece with the table in §1: **the local LLM is the default executor** instead of a paid helper model.
3. **Run:** text pieces → queue (§3–5); file pieces → files mode (§6); anything else → as §1 says.
4. **Check** everything the local model returns (§7).
5. **Assemble** and deliver (§9).

---

## 1. Routing

The user chooses the workers in the panel (`handy-panel.cmd`, http://localhost:8765): which local and cloud models are on, and their order in four lanes: `text`, `code`, `files`, `private`. Pass the lane to the scripts (`-Lane text|code|private`; files mode uses the `files` lane) and do not name a model yourself unless the user asks: the scripts follow the panel and fall back to the next worker of the lane by themselves. The status line says which worker answered, and whether data went to a cloud service. Confidential data always goes to `-Lane private`, which uses only local workers unless the user switched on "also allow cloud workers" in the panel. That choice is the user's: never switch it on yourself, and if a status line says `PRIVATE data sent to a cloud service`, mention it in the report.

| Piece of work | Who does it |
|---|---|
| Translations, rewrites, summaries, titles and meta descriptions, classification, extracting data from a text, test cases, bulk checks on texts | **Text mode, `-Lane text`** (§3–5) |
| Writing or fixing code returned as text | **Text mode, `-Lane code`** |
| Reading and editing files in one folder: replacements, additions, fixes in HTML, docs, code, config | **Local LLM, files mode** (§6) |
| Texts or files with confidential data | **`-Lane private`** (local workers only, unless the user allowed cloud in the panel) |
| Shell commands (git, npm, build, deploy), web browsing, connectors, urgent work, pieces the local model failed twice | **Cloud helper** (for example a fast Claude subagent) or Claude itself |
| Payments, sending email or messages, irreversible actions, decisions | **Claude itself**, with the user's approval |

Many pieces are not a reason to switch to parallel cloud helpers: put them all in the local queue, one after another.

---

## 2. Start-up check (one call)

You need a PowerShell on the user's Windows PC: either Claude Code running locally, or a remote-device PowerShell tool. If there is none, say so in one line and use the cloud helper.

```powershell
$d = if ($env:HANDY_HOME) { $env:HANDY_HOME } else { "$env:USERPROFILE\handy-llm" }
"scripts: " + (Test-Path "$d\scripts\handy.ps1") + " / queue: " + (Test-Path "$d\scripts\handy-queue.ps1") + " / files: " + (Test-Path "$d\scripts\handy-files.ps1")
try { "ollama " + (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:11434/api/version -TimeoutSec 5).Content } catch { "OLLAMA NOT RUNNING" }
"claude: " + (Get-Command claude -EA SilentlyContinue).Source
"model: " + $(if ($env:HANDY_MODEL) { $env:HANDY_MODEL } else { 'qwen3.8-cc (default)' })
ollama ps
```

| Result | What to do |
|---|---|
| scripts missing | ask the user to clone the repository into `%USERPROFILE%\handy-llm` (see README) |
| `OLLAMA NOT RUNNING` | start the Ollama app, wait 10 s, check **once** more. With an OpenAI-compatible server instead (LM Studio, llama.cpp, vLLM) check its `/v1/models` |
| model missing | ask before downloading: models are many GB |
| `ERROR | no enabled worker in lane` | ask the user to switch a worker on in the panel |
| `claude` missing | files mode unavailable: file pieces go to the cloud helper |
| another model is loaded and the GPU is small | switching costs 20–60 s each time: put **all** pieces in one queue, never alternate |

Use **one** model for both text and files mode, so it stays loaded.

---

## 3. Writing a text task

One `.txt` file per task, one folder per job:
`%USERPROFILE%\handy-llm\jobs\YYYYMMDD-HHMM-<job>\NN-<name>.txt` (NN = 01, 02… sets the order).

```text
TASK: <one sentence, one goal>
CONTEXT: <who it is for, where the text will go>
INSTRUCTIONS:
1. ...
2. ...
CONSTRAINTS: language, tone, maximum length, what must NOT change (names, numbers, prices, brands, URLs, phone numbers)
OUTPUT FORMAT: <plain text | list | JSON with the exact schema>
TEXT:
<<<
...
>>>
```

Rules:
- **Small, closed** tasks: one goal per file. Ten texts to translate = ten files.
- Long texts: split them into pieces of about **2,500 words**.
- Structured output: put the exact JSON schema in the task and run with `-Json`.
- Needs reasoning: `-Think` (slower, Ollama only). Precise extraction: lower temperature.

Writing the file (UTF-8, accents are safe):

```powershell
$c="$env:USERPROFILE\handy-llm\jobs\20261119-1100-translations"; New-Item -ItemType Directory -Force -Path $c | Out-Null
@'
TASK: ...
'@ | Set-Content -Encoding UTF8 "$c\01-services-page.txt"
```

No line of the text may start with `'@`; if one does, split that line.

---

## 4. Running text tasks (always in the background)

Remote PowerShell tools often stop waiting after about a minute: always start in the background and poll with short calls.

```powershell
$c="<job folder>"
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$env:USERPROFILE\handy-llm\scripts\handy-queue.ps1`"",'-Folder',"`"$c`""
```

Options: `-Lane text|code|private` (default `text`), `-Think`, `-Json`. Naming a server (`-Api`, `-BaseUrl`, `-Model`) bypasses the panel.

**Progress** (repeat until `DONE`):

```powershell
$c="<job folder>"; for($i=0;$i -lt 11;$i++){ Start-Sleep 4; if((Get-Content -Raw -Encoding UTF8 "$c\_queue.status" -EA SilentlyContinue) -match '^DONE'){break} }; Get-Content -Raw -Encoding UTF8 "$c\_queue.status"
```

On long jobs, tell the user where it stands (for example "3 of 10 done").

---

## 5. Reading text results

```powershell
Get-ChildItem "<job folder>" -Filter *.result.txt | % { "== $($_.Name) =="; Get-Content -Raw -Encoding UTF8 "$($_.FullName).status"; Get-Content -Raw -Encoding UTF8 $_.FullName }
```

| Status | Meaning |
|---|---|
| `OK | <worker> | …` | done: go to the check. `fallback after:` lists the workers that failed first; `NOTE: data sent to a cloud service` means a cloud worker answered |
| `WARNING: task possibly TRUNCATED` | the text did not fit: split it |
| `WARNING: answer CUT by length` | the answer stopped early: split the task |
| `ERROR | …` | see §8 |

---

## 6. Files mode (Claude Code with the local model)

`handy-files.ps1` runs Claude Code with the local model behind it (Ollama exposes an Anthropic-compatible endpoint). The model **reads and edits the files of one folder and cannot run commands** (`acceptEdits`). The model must support tool calling.

**Before starting**
1. Pick the **smallest folder** that holds the files: the model can read and edit everything inside it.
2. Prepare a before/after comparison: in a git repository `git status --porcelain` must be clean (or note the dirty files); otherwise copy the files to `jobs\<job>\before\`.
3. Folders inside WSL (`\\wsl.localhost\...`): Claude Code asks for manual approval of every write there, so the job stalls. Copy the files to a Windows working copy, run the model on the copy, check, then copy them back with `Copy-Item -Force` (line endings and accents survive).
4. Never let it work directly in a folder a running service is serving from: work on a copy.

**The task** (`.txt` in `jobs\<job>\`): list the files, the exact changes (old text → new text), what must NOT be touched, and end with "When done, answer with one line: which files you changed and how many changes you made".

**Fixed start-up time:** Claude Code's own instructions are about 16,000 tokens; a local model needs 1–3 minutes to read them at every new folder. Put **all** changes for one folder in **one** task. A tiny urgent fix is faster with the cloud helper.

```powershell
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$env:USERPROFILE\handy-llm\scripts\handy-files.ps1`"",'-Folder',"`"<work folder>`"",'-Task',"`"<task.txt>`""
```

**Progress** (repeat until it no longer says `RUNNING`):

```powershell
$st="<task without .txt>.files.status"; for($i=0;$i -lt 11;$i++){ Start-Sleep 4; if((Get-Content -Raw -Encoding UTF8 $st -EA SilentlyContinue) -notmatch '^RUNNING'){break} }; Get-Content -Raw -Encoding UTF8 $st
```

- No `local only` in the status: stop and tell the user.
- The ANSWER asks for manual approval: the folder is in WSL or protected; use a working copy.
- The ANSWER is a question: the task was incomplete; complete it and run again.
- Still `RUNNING` after minutes: usually it is still reading. With Ollama, check `Get-Content "$env:LOCALAPPDATA\Ollama\server.log" -Tail 3`; stop it only if the log has not moved for 2 minutes.

Files mode never commits, pushes, builds, installs or publishes.

---

## 7. Check (mandatory, always)

Nothing from the local model reaches the user, a final file or a repository unchecked.

**Texts:** every item is there (N in = N out); names, numbers, prices, dates, brands, URLs and phone numbers identical to the source; nothing invented; language, tone and length respected (count words or characters with PowerShell; JSON must pass `ConvertFrom-Json`).

**Files:** only the requested changes (`git diff` or the `before\` copy); every changed line matches the task; no extra files; old text gone and new text present the right number of times (`Select-String`); accents and structure intact.

Also apply the user's own rules for that kind of work (SEO, ads, email tone…), and change only what the user asked.

Result per piece: **OK** | **fixed by me** | **redone**.

---

## 8. When something goes wrong

| Problem | What to do |
|---|---|
| Wrong result | **one** retry with precise corrections ("you changed the price: it must stay 49 €"). Wrong again → cloud helper or Claude. Do not insist |
| Files mode touched something it should not | restore (git or `before\`), tighten the task, retry once; then cloud helper |
| Connection error or timeout | run §2 again, retry **once** |
| PC not reachable | tell the user in one line and use the cloud helper |
| Very slow | the GPU is probably switching between models: group the work |

Never delete old job folders without the user's permission.

---

## 9. Report to the user

- The outcome in one line (for example "10 pieces done locally, 9 OK, 1 fixed by me").
- Table: piece | who did it | result | time.
- Total tokens written by the local model: that is the work done for free.
- For files: which files changed and how many changes.
