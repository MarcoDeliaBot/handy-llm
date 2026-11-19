# handy-llm

**A big model thinks, a local model does the work for free, the big model checks.**

handy-llm lets Claude (or another strong model) act as the **brain** and a model running on your own PC as the **hands**. The brain splits a job into small tasks, hands the routine ones to the local model, then checks every result before you see it. The local work costs no tokens and your data never leaves the PC.

It works with any local LLM you can serve:

| Server | Text tasks | File editing |
|---|---|---|
| [Ollama](https://ollama.com) | ✅ native API | ✅ through Claude Code (Ollama speaks the Anthropic API) |
| LM Studio, llama.cpp server, vLLM, any OpenAI-compatible server | ✅ `-Api openai` | only if the server exposes an Anthropic-compatible endpoint |

The default model is `qwen3.8-cc` (Qwen3.8-27B with a 64k context, see below), but any model works: set `-Model` or the `HANDY_MODEL` environment variable.

## How it works

```
you ──► brain (Claude)  ──splits the job──►  task files (.txt)
                                                  │
                         local LLM on your PC  ◄──┘   free, private
                                                  │
you ◄── brain checks ◄──── results + status ◄─────┘
```

- **Text mode** (`handy.ps1`, `handy-queue.ps1`): one task file in, one result file out. Translations, rewrites, summaries, meta descriptions, classification, data extraction, test cases.
- **Files mode** (`handy-files.ps1`): Claude Code runs with the local model behind it and edits the files of one folder. It can read and edit, it cannot run commands.
- **The skill** (`skills/handy-llm/SKILL.md`): the instructions the brain follows. Switch it on once in a chat ("from now on use this skill") and every job is split, routed to the local model, and checked.

Every script writes a `.status` file (`RUNNING`, `OK`, `ERROR`, plus warnings for truncated input or cut answers), so the brain can start work in the background and poll it.

## Requirements

- Windows with Windows PowerShell 5.1 (PowerShell 7 should work but is not tested)
- A local LLM server, for example Ollama
- For files mode: [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, and a model that supports tool calling
- A GPU that fits your model. Qwen3.8-27B Q4_K_M (17 GB) fits a 24 GB card

## Install

```powershell
git clone https://github.com/MarcoDeliaBot/handy-llm "$env:USERPROFILE\handy-llm"
```

Optional: a 64k-context variant of Qwen3.8 for Ollama (no extra disk space, it reuses the same weights):

```powershell
ollama pull qwen3.8:27b
ollama create qwen3.8-cc -f "$env:USERPROFILE\handy-llm\examples\Modelfile"
```

Then add `skills/handy-llm` to your Claude skills: upload the folder as a skill in the Claude app, or copy it into `~/.claude/skills/` for Claude Code.

## Use the scripts directly

```powershell
cd "$env:USERPROFILE\handy-llm"
mkdir jobs\test
"TASK: translate into English.`nTEXT:`n<<<`nCiao, come stai?`n>>>" | Set-Content -Encoding UTF8 jobs\test\01-hello.txt

# Ollama
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\handy.ps1 -Task jobs\test\01-hello.txt

# any OpenAI-compatible server (LM Studio default port shown)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\handy.ps1 -Task jobs\test\01-hello.txt -Api openai -BaseUrl http://127.0.0.1:1234/v1 -Model <model-id>

Get-Content jobs\test\01-hello.result.txt, jobs\test\01-hello.result.txt.status
```

A whole folder, in order, in the background:

```powershell
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PWD\scripts\handy-queue.ps1`"",'-Folder',"`"$PWD\jobs\test`""
Get-Content jobs\test\_queue.status
```

Edit files in a folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\handy-files.ps1 -Folder C:\path\to\site -Task jobs\test\02-replace-phone.txt
Get-Content jobs\test\02-replace-phone.files.status
```

Environment variables: `HANDY_MODEL`, `HANDY_API` (`ollama` or `openai`), `HANDY_BASE_URL`, `HANDY_API_KEY`, `HANDY_ANTHROPIC_URL` (files mode), `HANDY_HOME` (install folder, used by the skill).

## What to expect

Measured on one AMD RX 7900 XTX (24 GB) with Qwen3.8-27B Q4_K_M through Ollama:

| | |
|---|---|
| Writing speed | 19–40 tokens/s |
| Reading speed | about 145 tokens/s |
| Short text task, model already loaded | about 1 s |
| Model load | 20–30 s |
| Files mode start-up (reading Claude Code's instructions, about 16k tokens) | 2–3 min per folder |
| Files mode, a small job (2 phone numbers replaced, 1 meta tag added) | 2 to 10 min depending on how long the model reasons; all correct in every test |

So: great for many small routine tasks and for private data, slower than a cloud model for urgent or tiny file fixes. One GPU runs one model at a time, so tasks are queued, not parallel.

## Good to know

- **Always check.** The local model is the hands, not the judge: the skill makes the brain verify counts, names, numbers, prices and diffs before delivering.
- **WSL folders:** Claude Code asks for a manual approval for each write to `\\wsl.localhost\...`. Work on a Windows copy and copy the files back.
- **Quotes in tasks:** files mode sends the task through standard input, because Windows PowerShell 5.1 splits command-line arguments at quotes.
- **The `jobs` folder** holds your tasks and results and is ignored by git.

## License

[MIT](LICENSE)
