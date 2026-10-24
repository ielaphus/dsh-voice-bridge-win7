@echo off
rem slovar.cmd - voice replacement dictionary helper. ASCII only, CRLF.
rem   slovar.cmd -Add "left => right"   add or fix one entry
rem   slovar.cmd -Check                entries, size, path
rem   slovar.cmd -Test                 verify every entry really fires
setlocal
if /i "%~1"=="-Test" goto test

set ELECTRON_RUN_AS_NODE=1
"D:\porogram files\dsh\DSH-Desktop-2.0.10-Win7-portable\app\DSH Desktop.exe" "%~dp0slovar.js" %*
exit /b %ERRORLEVEL%

:test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0slovar-test.ps1"
exit /b %ERRORLEVEL%
