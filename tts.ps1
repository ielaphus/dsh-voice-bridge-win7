# tts.ps1 — speech synthesis through RHVoice (no installation).
# Dot-source this, then:
#   $tts = Initialize-Tts -Voice 'Anna'
#   New-SpeechFile -Tts $tts -Text 'Привет.' -Path 'C:\...\speech_0.wav'
#   Stop-Tts -Tts $tts
#
# RHVoice reads stress marks: "+" immediately before the stressed vowel, e.g.
# "зам+ок", "мук+а". The marks come from the answering model.

$script:TtsRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'bin\rhvoice'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'rhvoice_bridge.ps1')

function Initialize-Tts {
  param(
    [string]$Voice = 'Anna',
    [string]$Root = $script:TtsRoot,
    [double]$Pitch = 1.0,
    [double]$Speed = 1.0,
    [double]$Volume = 0.5,
    [int]$OutRate = 44100,
    [double]$Highpass = 90,
    [double]$Lowpass = 7500,
    [double]$Peak = 0.85
  )
  $voiceDir = Join-Path $Root $Voice.ToLower()
  $engine = Start-RhvEngine -Root $Root -VoiceDir $voiceDir -Voice $Voice
  $engine['pitch'] = $Pitch
  $engine['speed'] = $Speed
  $engine['volume'] = $Volume
  $engine['outRate'] = $OutRate
  $engine['highpass'] = $Highpass
  $engine['lowpass'] = $Lowpass
  $engine['peak'] = $Peak
  return $engine
}

function New-SpeechFile {
  param(
    [hashtable]$Tts,
    [string]$Text,
    [string]$Path
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $result = Invoke-RhvSpeak -Engine $Tts -Text $Text -OutPath $Path -Pitch $Tts.pitch -Speed $Tts.speed `
    -Volume $Tts.volume -OutRate $Tts.outRate -Highpass $Tts.highpass -Lowpass $Tts.lowpass -Peak $Tts.peak
  return $result
}

function Stop-Tts {
  param([hashtable]$Tts)
  Stop-RhvEngine -Engine $Tts
}

# Sentences for one-by-one synthesis. Stress marks are preserved: they are just
# "+" inside words and none of the splitting below touches them.
function Split-Sentences {
  param(
    [string]$Text,
    [int]$MaxParts = 8,
    [int]$MaxChars = 400
  )
  $clean = [regex]::Replace($Text, '\s+', ' ').Trim()
  if ($clean -eq '') { return @() }

  $raw = [regex]::Split($clean, '(?<=[.!?])\s+')
  $parts = New-Object System.Collections.ArrayList
  foreach ($piece in $raw) {
    $s = $piece.Trim()
    if ($s.Length -eq 0) { continue }
    if ($s.Length -gt $MaxChars) {
      foreach ($word in [regex]::Split($s, '\s+')) {
        [void]$parts.Add($word)
      }
      continue
    }
    [void]$parts.Add($s)
    if ($parts.Count -ge $MaxParts) { break }
  }

  # merge the tail so nothing is lost and the part count stays bounded
  if ($parts.Count -gt $MaxParts) {
    $head = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $MaxParts - 1; $i++) { [void]$head.Add($parts[$i]) }
    $tail = ''
    for ($i = $MaxParts - 1; $i -lt $parts.Count; $i++) { $tail += ' ' + $parts[$i] }
    [void]$head.Add($tail.Trim())
    return $head.ToArray()
  }

  return $parts.ToArray()
}
