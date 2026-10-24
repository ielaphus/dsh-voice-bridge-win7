# slovar-test.ps1 - verify that every dictionary line actually fires.
#
# It runs each entry's LEFT side through the same Convert-VoskSlovar path the
# bridge uses and compares the result with the RIGHT side, so a reversed or
# dead entry (Latin left side, duplicate, bad separator) is reported instead of
# silently doing nothing. ASCII output only: the console here is CP866 and
# Cyrillic in results goes to the report file instead.
#
#   powershell -ExecutionPolicy Bypass -File slovar-test.ps1
#   slovar.cmd -Test
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here 'vosk.ps1')

$utf8 = New-Object System.Text.UTF8Encoding($false)
$path = Join-Path $here 'slovar.txt'
$report = Join-Path $here 'tmp\slovar-test.txt'
if (-not (Test-Path (Split-Path -Parent $report))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $report) | Out-Null }

$ok = 0
$problems = New-Object System.Collections.ArrayList
$seen = @{}

foreach ($line in [IO.File]::ReadAllLines($path, $utf8)) {
  $s = ([string]$line).TrimStart([char[]]@([char]0xFEFF)).Trim()
  if ($s -eq '' -or $s.StartsWith('#')) { continue }

  $split = $s.IndexOf('=>')
  if ($split -lt 1) {
    [void]$problems.Add('BAD FORMAT (no separator): ' + $s)
    continue
  }
  $left = $s.Substring(0, $split).Trim()
  $right = $s.Substring($split + 2).Trim()
  if ($left -eq '' -or $right -eq '') {
    [void]$problems.Add('EMPTY SIDE: ' + $s)
    continue
  }

  $key = $left.ToLower()
  if ($seen.ContainsKey($key)) {
    [void]$problems.Add('DUPLICATE left side: ' + $s)
    continue
  }
  $seen[$key] = $right

  if (-not [regex]::IsMatch($left, '^[^A-Za-z0-9]+$')) {
    # Cyrillic range as escapes: this file stays pure ASCII so it can never be
    # mis-decoded by PowerShell 2.0 (no BOM, no non-ASCII, no surprises).
    $rightHasCyr = [regex]::IsMatch($right, '[\u0410-\u044F\u0401\u0451]')
    if ($rightHasCyr) {
      [void]$problems.Add('INVERTED (left Latin, right Cyrillic): ' + $s)
    } else {
      [void]$problems.Add('LATIN LEFT (Vosk never outputs it): ' + $s)
    }
    continue
  }
  if ($left.ToLower() -eq $right.ToLower()) {
    [void]$problems.Add('NO-OP (left equals right): ' + $s)
    continue
  }

  $got = Convert-VoskSlovar -Text $left
  if ($got -ne $right) {
    [void]$problems.Add('MISMATCH: ' + $left + ' => ' + $right + '   (got: ' + $got + ')')
    continue
  }
  $ok = $ok + 1
}

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('slovar.txt : ' + $path)
[void]$lines.Add('entries ok : ' + $ok)
[void]$lines.Add('problems   : ' + $problems.Count)
foreach ($p in $problems) { [void]$lines.Add('   ' + $p) }
[IO.File]::WriteAllText($report, ($lines -join "`r`n") + "`r`n", $utf8)

'entries ok : ' + $ok
'problems   : ' + $problems.Count
if ($problems.Count -gt 0) { 'see: ' + $report }
if ($problems.Count -gt 0) { exit 1 }
