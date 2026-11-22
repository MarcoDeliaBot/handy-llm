@echo off
rem Starts the handy-llm workers panel and opens it in your browser (http://localhost:8765).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\handy-panel.ps1" -Open
