# ensure-bom.ps1 - keep PowerShell 2.0 able to read the Russian scripts here.
#
# This host runs Windows PowerShell 2.0, which decodes a script as ANSI unless the
# file starts with a UTF-8 BOM. Every tool that rewrites a file can drop that BOM,
# and then the script dies with a parse error on the first Cyrillic literal (e.g.
# "MissingEndParenthesisInMethodCall" in Clear-Markdown). start.cmd runs this file
# first, so a BOM-only accident cannot break the voice bridge again.
#
# ASCII only on purpose: this script must run even when it is the thing being fixed.
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$plain = New-Object System.Text.UTF8Encoding($false)
$withBom = New-Object System.Text.UTF8Encoding($true)
$fixed = New-Object System.Collections.ArrayList

foreach ($file in @(Get-ChildItem $here)) {
  if ($file.PSIsContainer) { continue }
  if (-not (@('.ps1', '.txt') -contains $file.Extension)) { continue }

  $bytes = [IO.File]::ReadAllBytes($file.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if ($hasBom) { continue }

  $nonAscii = $false
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -gt 127) { $nonAscii = $true; break }
  }
  if (-not $nonAscii) { continue }

  $text = $plain.GetString($bytes)
  [IO.File]::WriteAllText($file.FullName, $text, $withBom)
  [void]$fixed.Add($file.Name)
}

if ($fixed.Count -eq 0) {
  'bom: ok'
} else {
  'bom fixed: ' + ($fixed -join ', ')
}
