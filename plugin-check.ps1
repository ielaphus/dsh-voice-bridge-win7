# plugin-check.ps1 - health check for the in-app voice-turn plugin.
#   powershell -ExecutionPolicy Bypass -File plugin-check.ps1
# Prints one line: whether 127.0.0.1:43198 accepts a connection and what the
# plugin answers to {"ping":true}. If the port is closed, the plugin is not
# loaded (cordis.patch.yml is read only at DSH startup: restart the app).
param([int]$Port = 43198)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$logFile = Join-Path $here 'tmp\plugin.log'

$client = New-Object System.Net.Sockets.TcpClient
try {
  $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
  $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
  if (-not $ok) {
    "port : closed - plugin not loaded (restart DSH Desktop)"
    if (Test-Path $logFile) { "log  : " + $logFile + " (exists, tail below)"; Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 5 }
    return
  }
  $client.EndConnect($iar)
} catch {
  "port : connect failed - " + $_.Exception.Message
  return
}

try {
  $stream = $client.GetStream()
  $stream.ReadTimeout = 120000
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $writer = New-Object System.IO.StreamWriter($stream, $utf8)
  $writer.NewLine = "`n"
  $writer.AutoFlush = $true
  $writer.WriteLine('{"ping":true}')
  $reader = New-Object System.IO.StreamReader($stream, $utf8)
  $reply = $reader.ReadLine()
  "port : open"
  "reply: " + $reply
  $writer.Close()
} catch {
  "port : open, but the check failed - " + $_.Exception.Message
} finally {
  try { $client.Close() } catch { }
}

if (Test-Path $logFile) {
  "log  : " + $logFile
  Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 6
}
