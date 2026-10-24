# agentd.ps1 — start/stop the resident DSH agent and ask it questions.
# The daemon (agentd.js) keeps one ACP session warm and also runs Piper, so a
# warm turn costs only: question -> answer -> speech.wav.
#
# Protocol (127.0.0.1:43199):
#   send one UTF-8 line, receive one line:
#     "ok <llm_ms> <chars> tts=<0|1> <tts_ms>"   answer in tmp\agentd-answer.txt
#     "err <message>"

$script:AgentdHere = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:AgentdPort = 43199
$script:AgentdExe = 'D:\porogram files\dsh\DSH-Desktop-2.0.10-Win7-portable\app\DSH Desktop.exe'
$script:AgentdScript = Join-Path $script:AgentdHere 'agentd.js'
$script:AgentdAnswer = Join-Path $script:AgentdHere 'tmp\agentd-answer.txt'
$script:AgentdPid = Join-Path $script:AgentdHere 'tmp\agentd.pid'
$script:AgentdLog = Join-Path $script:AgentdHere 'tmp\agentd.log'
$script:AgentdSpeech = Join-Path $script:AgentdHere 'tmp\speech.wav'
$script:AgentdBuild = Join-Path $script:AgentdHere 'tmp\agentd.build'

# Milliseconds since epoch for agentd.js, matching what the daemon writes into
# tmp\agentd.build. Equal values mean the running daemon has current code.
function Get-AgentdSignature {
  if (-not (Test-Path $script:AgentdScript)) { return '0' }
  $utc = (Get-Item $script:AgentdScript).LastWriteTimeUtc
  $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
  return [string][long](($utc - $epoch).TotalMilliseconds)
}

function Test-AgentdPort {
  param([int]$TimeoutMs = 400)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect('127.0.0.1', $script:AgentdPort, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if (-not $ok) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    try { $client.Close() } catch { }
  }
}

function Start-Agentd {
  param([int]$WaitSeconds = 0)

  # Reuse a running daemon when its code is current: the ACP session lives in
  # that process, so reusing it means every launch keeps writing into the same
  # transcript instead of opening a new session. A daemon started before the
  # last edit of agentd.js is restarted (a signature mismatch tells us that).
  if (Test-AgentdPort) {
    $expected = Get-AgentdSignature
    $actual = ''
    if (Test-Path $script:AgentdBuild) {
      $raw = Get-Content $script:AgentdBuild | Select-Object -First 1
      if ($raw -ne $null) { $actual = ([string]$raw).Trim() }
    }
    if ($actual -ne '' -and $actual -eq $expected) { return 'reused' }
    [void](Stop-Agentd)
    if (Test-AgentdPort) { return 'port-busy' }
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:AgentdExe
  $psi.Arguments = '"' + $script:AgentdScript + '"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $script:AgentdHere
  # Detach the daemon's stdio: it must not inherit the caller's stdout, otherwise
  # a pipeline in the caller ("| Select-String") never sees EOF while a warm
  # daemon holds the handle. The daemon writes its log to tmp\agentd.log.
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # Without this the exe runs as the GUI client instead of as Node.
  $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
  $script:AgentdProcess = [System.Diagnostics.Process]::Start($psi)

  if ($WaitSeconds -le 0) { return 'starting' }
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-AgentdPort) { return 'started' }
    Start-Sleep -Milliseconds 300
  }
  return 'timeout'
}

function Wait-Agentd {
  param([int]$TimeoutSeconds = 30)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-AgentdPort) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Get-AgentdPid {
  # Prefer the pid file, fall back to whoever owns the listening port: the pid
  # file can be missing or emptied while the process is still alive.
  if (Test-Path $script:AgentdPid) {
    $raw = (Get-Content $script:AgentdPid | Select-Object -First 1)
    if ($raw -ne $null) {
      $text = [string]$raw
      if ($text.Trim() -match '^\d+$') { return [int]$text.Trim() }
    }
  }

  $owner = 0
  $lines = & netstat.exe -ano | & findstr.exe LISTENING | & findstr.exe (':' + $script:AgentdPort)
  foreach ($line in $lines) {
    $fields = [regex]::Split($line.Trim(), '\s+')
    if ($fields.Length -ge 5) {
      $candidate = $fields[$fields.Length - 1]
      if ($candidate -match '^\d+$') { $owner = [int]$candidate }
    }
  }
  return $owner
}

function Stop-Agentd {
  $daemonPid = Get-AgentdPid
  if ($daemonPid -le 0) { return 'not-running' }

  & taskkill.exe /PID $daemonPid /T /F 2>&1 | Out-Null
  Remove-Item $script:AgentdPid -Force -ErrorAction SilentlyContinue

  # Wait until the port is really free, otherwise the next start races with it.
  for ($i = 0; $i -lt 40; $i++) {
    if (-not (Test-AgentdPort)) { break }
    Start-Sleep -Milliseconds 200
  }
  return 'stopped'
}

function Ask-Agentd {
  param(
    [string]$Text,
    [int]$TimeoutSeconds = 240
  )
  $result = @{ ok = $false; ms = 0; chars = 0; answer = ''; error = '' }

  if (-not (Test-AgentdPort)) { $result.error = 'daemon not listening'; return $result }

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $client.Connect('127.0.0.1', $script:AgentdPort)
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutSeconds * 1000
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $writer = New-Object System.IO.StreamWriter($stream, $utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    $writer.WriteLine($Text)

    $reader = New-Object System.IO.StreamReader($stream, $utf8)
    $line = $reader.ReadLine()
    $writer.Close()

    if (-not $line) { $result.error = 'empty reply'; return $result }
    if ($line.StartsWith('err ')) { $result.error = $line.Substring(4); return $result }

    # "ok <llm_ms> <chars>"
    $m = [regex]::Match($line, '^ok\s+(\d+)\s+(\d+)')
    if (-not $m.Success) { $result.error = 'unexpected reply: ' + $line; return $result }

    $result.ok = $true
    $result.ms = [int]$m.Groups[1].Value
    $result.chars = [int]$m.Groups[2].Value
    if (Test-Path $script:AgentdAnswer) {
      $result.answer = [IO.File]::ReadAllText($script:AgentdAnswer, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $result
  } catch {
    $result.error = $_.Exception.Message
    return $result
  } finally {
    try { $client.Close() } catch { }
  }
}
