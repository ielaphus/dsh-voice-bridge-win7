@echo off
rem Launcher for the DSH voice bridge. ASCII only, CRLF line endings.
cd /d "%~dp0"
rem PowerShell 2.0 needs a UTF-8 BOM to read Russian scripts; fix it if an edit
rem dropped the BOM, otherwise voice.ps1 dies with a parse error.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-bom.ps1" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0voice.ps1" %*
echo.
echo done.
pause
