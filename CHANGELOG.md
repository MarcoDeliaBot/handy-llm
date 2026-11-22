# Changelog

## 1.1.0 - 2026-11-22

- Skill uploads cleanly to claude.ai: LF line endings in `SKILL.md` (enforced by `.gitattributes`) and a description under 200 characters.
- New `scripts/make-skill-zip.ps1`: builds `dist/handy-llm.zip` and checks the upload rules first.
- README: how to install the skill in the Claude app or in Claude Code.

## 1.0.0 - 2026-11-21

- Workers panel (`handy-panel.cmd`, http://localhost:8765): local and cloud workers, four lanes with fallback, encrypted keys, usage table.
- Private lane: local workers only, unless the user allows cloud workers with a warning.
- Scripts: `handy.ps1`, `handy-queue.ps1`, `handy-files.ps1` follow the panel's lanes.