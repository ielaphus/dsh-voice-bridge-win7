@echo off
rem word.cmd - read and edit .docx documents through Node inside DSH Desktop.
rem ASCII only, CRLF line endings. Usage: word.cmd -Action read -Path doc.docx
setlocal
set ELECTRON_RUN_AS_NODE=1
"D:\porogram files\dsh\DSH-Desktop-2.0.10-Win7-portable\app\DSH Desktop.exe" "%~dp0word.js" %*
exit /b %ERRORLEVEL%
