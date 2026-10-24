param(
  [string]$ModelDir = '',
  [int]$MaxSeconds = 30,
  [int]$MinSeconds = 1,
  [int]$MaxTurns = 0,
  [string]$InputWav = '',
  [string]$Voice = 'Anna',
  [double]$Pitch = 0.90,
  [double]$Speed = 1.1,
  [double]$Volume = 0.5,
  [int]$OutRate = 44100,
  [double]$Highpass = 90,
  [double]$Lowpass = 7500,
  [double]$Gain = 0.85,
  [string]$Hotkey = 'ralt',
  [switch]$ConsoleOnly,
  [switch]$UseAgent,
  [switch]$NewSession,
  [switch]$StopAgent
)
# voice.ps1 — push-to-talk bridge to DSH.
#   hold RIGHT ALT while speaking (release to send): works from ANY window, so
#   the phrases land in DSH while you type in another program. Q or Esc quit, but
#   only while this window is focused (a Russian "й" is the physical Q).
#   -Hotkey space|ralt|rctrl|f9 rebinds the talk key; -ConsoleOnly makes it
#   listen only while this window is active.
#   Vosk        -> text (local)
#   agentd      -> answer text from one warm ACP session
#   RHVoice     -> speech, sentence by sentence, played through Media Foundation
#
# RHVoice replaced Piper: it is ~10x faster (no neural inference), it starts in
# 21 ms, and it honours stress marks ("+" before the stressed vowel), which the
# answering model supplies for ambiguous words.
#
# Console output stays ASCII: this host's console is CP866. The dialogue itself
# is stored only in the DSH session (no second transcript file).
#
# The bridge prints the id of the DSH session that receives the dialogue, and
# -NewSession starts a fresh conversation (the old one keeps its text in the app).

$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($ModelDir -eq '') { $ModelDir = Join-Path $here 'bin\vosk-model-small-ru-0.22' }
. (Join-Path $here 'recorder.ps1')
. (Join-Path $here 'vosk.ps1')
. (Join-Path $here 'agentd.ps1')
. (Join-Path $here 'tts.ps1')

$tmp = Join-Path $here 'tmp'
$recWav = Join-Path $tmp 'rec.wav'
$answerFile = Join-Path $tmp 'agentd-answer.txt'
$sessionFile = Join-Path $tmp 'agentd-session.txt'

# Which DSH session receives the dialogue is not guessable from the app alone,
# so the bridge prints it. Console stays ASCII (CP866 host): only the id is
# printed, and only when it changes.
$script:lastShownSession = ''
function Show-VoiceSession {
  $id = ''
  if (Test-Path $sessionFile) {
    try { $id = ([IO.File]::ReadAllText($sessionFile, (New-Object System.Text.UTF8Encoding($false)))).Trim() } catch { $id = '' }
  }
  if ($id -eq '') {
    if ($script:lastShownSession -ne '(creating)') {
      "  session : (creating)"
      $script:lastShownSession = '(creating)'
    }
    return
  }
  if ($id -ne $script:lastShownSession) {
    "  session : " + $id
    "            ^ this DSH session holds the dialogue as text (sidebar list)"
    $script:lastShownSession = $id
  }
}

if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Force -Path $tmp | Out-Null }
$env:ELECTRON_RUN_AS_NODE = '1'

# --- playback --------------------------------------------------------------
# Media Foundation renders the same way a normal media player does; WinMM's
# SoundPlayer rasped on this machine with identical files.
$fallbackPlayer = New-Object System.Media.SoundPlayer
$wpfAvailable = $false
try {
  [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')
  [void][System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')
  $wpfAvailable = ([System.Windows.Media.MediaPlayer] -ne $null)
} catch {
  $wpfAvailable = $false
}

function Get-WavSeconds {
  param([string]$Path)
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $rate = 24000
    $dataLen = 0
    $pos = 12
    while ($pos + 8 -le $bytes.Length) {
      $id = [Text.Encoding]::ASCII.GetString($bytes, $pos, 4)
      $size = [BitConverter]::ToInt32($bytes, $pos + 4)
      if ($id -eq 'fmt ') {
        $rate = [BitConverter]::ToInt32($bytes, $pos + 12)
      } elseif ($id -eq 'data') {
        $dataLen = [Math]::Min($size, $bytes.Length - $pos - 8)
        break
      }
      $pos += 8 + $size + ($size % 2)
    }
    if ($rate -le 0 -or $dataLen -le 0) { return 0 }
    return [double]$dataLen / 2.0 / [double]$rate
  } catch {
    return 0
  }
}

function Play-WavFile {
  param([string]$Path, [double]$Volume = 1.0, [int]$SettleMs = 200, [int]$TailMs = 60)
  if (-not (Test-Path $Path)) { return $false }

  $expected = Get-WavSeconds -Path $Path

  if ($wpfAvailable) {
    $media = $null
    try {
      $media = New-Object System.Windows.Media.MediaPlayer
      $media.Volume = $Volume
      $media.Open((New-Object System.Uri($Path)))
      Start-Sleep -Milliseconds $SettleMs
      $media.Play()
      if ($expected -gt 0) {
        Start-Sleep -Milliseconds ([int](($expected + 0.15) * 1000))
      } else {
        Start-Sleep -Seconds 5
      }
      try { $media.Stop() } catch { }
      try { $media.Close() } catch { }
      Start-Sleep -Milliseconds $TailMs
      return $true
    } catch {
      try {
        if ($media -ne $null) { $media.Stop(); $media.Close() }
      } catch { }
      return $false
    }
  }

  try {
    $fallbackPlayer.SoundLocation = $Path
    $fallbackPlayer.Load()
    $fallbackPlayer.PlaySync()
    return $true
  } catch {
    return $false
  }
}

# --- answer text to speech-ready text --------------------------------------
# Markdown must not be read aloud, and math must be spoken in Russian words.
# A "+" inside a word is a stress mark for RHVoice, so the symbol rules below
# require a digit on both sides and leave words untouched.
function Clear-Markdown {
  param([string]$Text)
  $s = $Text
  $s = [regex]::Replace($s, '(?s)```.*?```', ' ')
  $s = [regex]::Replace($s, '`([^`]*)`', '$1')
  $s = [regex]::Replace($s, '!?\[([^\]]*)\]\([^)]*\)', '$1')
  $s = [regex]::Replace($s, '(?m)^\s{0,3}#{1,6}\s*', '')
  $s = [regex]::Replace($s, '(\*\*|__)(.*?)\1', '$2')
  $s = [regex]::Replace($s, '\*([^*]+)\*', '$1')
  $s = [regex]::Replace($s, '(?m)^\s*[-*]\s+', '')
  $s = [regex]::Replace($s, '(\d)\s*\+\s*(\d)', '$1 плюс $2')
  $s = [regex]::Replace($s, '(\d)\s*=\s*(\d)', '$1 равно $2')
  $s = [regex]::Replace($s, '(\d)\s*[\u00D7*]\s*(\d)', '$1 умножить на $2')
  $s = [regex]::Replace($s, '(\d)\s*\u00F7\s*(\d)', '$1 разделить на $2')
  $s = [regex]::Replace($s, '(\d)\s*%', '$1 процентов')
  $s = [regex]::Replace($s, '[\u2014\u2013]', ', ')
  $s = [regex]::Replace($s, '\s+', ' ')
  return $s.Trim()
}

# --- engines ---------------------------------------------------------------
$tts = $null
$ttsStatus = 'disabled'
try {
  # Speaker buzzing is fought in the synth stage: the 24 kHz RHVoice stream is
  # high-passed, low-passed twice, resampled to the device rate and peak-limited
  # (see Process() in rhvoice_bridge.ps1). Pitch/Gain are tuned per machine.
  $tts = Initialize-Tts -Voice $Voice -Pitch $Pitch -Speed $Speed -Volume $Volume `
    -OutRate $OutRate -Highpass $Highpass -Lowpass $Lowpass -Peak $Gain
  $ttsStatus = 'RHVoice ' + $tts.version + ', ' + $Voice + ', pitch ' + $Pitch + ', speed ' + $Speed +
    ', vol ' + $Volume + ', out ' + $OutRate + ' Hz, lp ' + $Lowpass + ', peak ' + $Gain
} catch {
  $ttsStatus = 'FAILED: ' + $_.Exception.Message
}

$agentStatus = 'disabled'
if ($NewSession) {
  # A fresh conversation needs a fresh ACP session, and the running daemon owns
  # the old one, so it is stopped here; the id file is dropped with it.
  [void](Stop-Agentd)
  if (Test-Path $sessionFile) { Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue }
  $script:lastShownSession = ''
}
if ($InputWav -eq '' -or $UseAgent) { $agentStatus = Start-Agentd -WaitSeconds 0 }
if ($agentStatus -eq 'timeout') { $agentStatus = 'starting' }

"=============================================="
"  DSH voice bridge (push to talk)"
"  model : " + $ModelDir
"  input : " + (Get-RecorderDevices) + " device(s)"
"  out   : " + $(if ($wpfAvailable) { "Media Foundation" } else { "WinMM SoundPlayer (fallback)" })
"  tts   : " + $ttsStatus
"  agent : " + $agentStatus
$keyLabel = $Hotkey.ToUpper()
if ($keyLabel -eq 'RALT' -or $keyLabel -eq 'RIGHTALT' -or $keyLabel -eq 'ALTGR') { $keyLabel = 'RIGHT ALT' }
if ($keyLabel -eq 'RCTRL' -or $keyLabel -eq 'RIGHTCTRL') { $keyLabel = 'RIGHT CTRL' }
"  HOLD " + $keyLabel + " while speaking, release to send"
if ($ConsoleOnly) {
  "  key works only while THIS window is active; Q or Esc = quit   max " + $MaxSeconds + " s per turn"
} else {
  "  key works from ANY window; Q or Esc (this window only) = quit   max " + $MaxSeconds + " s per turn"
}
"  log   : " + (Join-Path $tmp 'agentd.log')
"=============================================="
Show-VoiceSession

# Load the recognizer once, now, so the first real turn does not pay for it.
"warming recognizer..."
$warmWav = Join-Path $tmp 'warmup.wav'
$warmRec = Record-Wav -Path $warmWav -Seconds 1 -Normalize $false
if ($warmRec -like 'ok:*') { [void](Get-VoskText -ModelDir $ModelDir -WavPath $warmWav) }
"recognizer ready"

$turn = 0
$failed = 0

while ($true) {
  if ($MaxTurns -gt 0 -and $turn -ge $MaxTurns) { break }
  $turn++

  ""
  "--- turn " + $turn + " ---"
  Show-VoiceSession

  if ($InputWav -ne '') {
    if (-not (Test-Path $InputWav)) { "INPUT WAV MISSING: " + $InputWav; break }
    Copy-Item -Path $InputWav -Destination $recWav -Force
    "using wav: " + $InputWav
  } else {
    $rec = Record-PushToTalk -Path $recWav -MaxSeconds $MaxSeconds -MinSeconds $MinSeconds `
      -TalkKey $Hotkey -TalkNeedsConsole $ConsoleOnly -QuitNeedsConsole $true
    if ($rec -eq 'quit') { "quit requested"; break }
    if ($rec -like 'short:*') {
      "too short (" + $rec.Substring(6) + " ms): hold " + $keyLabel + " while speaking"
      continue
    }
    if ($rec -notlike 'ok:*') {
      "RECORD FAILED: " + $rec
      $failed++
      continue
    }
    "rec " + $rec.Substring(3)
    $peakMatch = [regex]::Match($rec, 'peak=(\d+)')
    if ($peakMatch.Success) {
      $peakValue = [int]$peakMatch.Groups[1].Value
      if ($peakValue -lt 500) {
        "WARN peak=" + $peakValue + " is very low: speak closer to the laptop mic."
      }
    }
  }

  $sttStarted = Get-Date
  $text = Get-VoskText -ModelDir $ModelDir -WavPath $recWav
  $sttMs = [int]((Get-Date) - $sttStarted).TotalMilliseconds
  if ($text -like '__ERROR__*') {
    "STT ERROR: " + $text
    $failed++
    continue
  }
  if (-not $text -or $text.Length -lt 2) {
    "no speech recognized"
    continue
  }
  "heard " + $text.Length + " chars -> DSH (stt " + $sttMs + " ms)"

  # --- answer ---
  $answer = ''
  $llmMs = 0
  if (-not (Test-AgentdPort)) { [void](Wait-Agentd -TimeoutSeconds 30) }
  $reply = Ask-Agentd -Text $text -TimeoutSeconds 240
  Show-VoiceSession

  if ($reply.ok) {
    $llmMs = $reply.ms
    if (Test-Path $answerFile) {
      $answer = [IO.File]::ReadAllText($answerFile, (New-Object System.Text.UTF8Encoding($false)))
    }
    "  LLM ok=1 ms=" + $reply.ms + " chars=" + $reply.chars
  } else {
    # No silent second path: a one-shot agent would open ANOTHER DSH session and
    # leave a duplicate of the dialogue behind. The turn is dropped instead.
    "agent unavailable (" + $reply.error + "), turn skipped"
    "see " + (Join-Path $tmp 'agentd.log') + " and tmp\agentd.pid"
    $failed++
    continue
  }

  $answer = $answer.Trim()
  if ($answer.Length -lt 2) {
    "no answer text"
    $failed++
    continue
  }

  # --- speech, sentence by sentence ---
  if ($tts -eq $null) {
    "TTS unavailable, answer text is in " + $answerFile
    $failed++
    continue
  }

  $clean = Clear-Markdown -Text $answer
  $sentences = Split-Sentences -Text $clean -MaxParts 8
  if ($sentences.Count -eq 0) {
    "nothing to speak"
    $failed++
    continue
  }

  Get-ChildItem $tmp -Filter 'speech_*.wav' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

  $synthStarted = Get-Date
  $files = New-Object System.Collections.ArrayList
  $idx = 0
  foreach ($s in $sentences) {
    $file = Join-Path $tmp ('speech_' + $idx + '.wav')
    $res = New-SpeechFile -Tts $tts -Text $s -Path $file
    if (Test-Path $file) { [void]$files.Add($file) }
    $idx++
  }
  $synthMs = [int]((Get-Date) - $synthStarted).TotalMilliseconds
  "  TTS parts=" + $files.Count + " synth_ms=" + $synthMs

  $played = 0
  foreach ($f in $files) {
    if (Play-WavFile -Path $f -SettleMs 120 -TailMs 30) { $played++ } else { "PLAYBACK FAILED: " + $f; break }
  }
  if ($played -gt 0) { "spoken " + $played + " part(s)" } else { $failed++ }
}

if ($tts -ne $null) { Stop-Tts -Tts $tts }
if ($StopAgent) {
  [void](Stop-Agentd)
  "agent stopped"
} elseif ($agentStatus -ne 'disabled') {
  "agent kept warm: next launch continues the SAME session"
  "fresh conversation next time: start.cmd -NewSession"
  "stop it with: powershell -File voice.ps1 -StopAgent"
}
""
"stopped after " + $turn + " turn(s), failures: " + $failed
"text of the dialogue: the DSH session printed above"
