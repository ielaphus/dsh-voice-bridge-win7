# vosk.ps1 — local speech recognition definitions (dot-source, no side effects).
# Vosk is used instead of whisper on this host: whisper always encodes a full
# 30-second window and this CPU (i7 M 620, no AVX) needed ~107 s per clip.
# Vosk decodes the same clip in well under a second once its model is loaded,
# so the model is cached for the lifetime of the PowerShell process.
#
# Usage:
#   . .\vosk.ps1
#   $text = Get-VoskText -ModelDir 'C:\...\vosk-model-small-ru-0.22' -WavPath 'C:\...\rec.wav'

$script:VoskRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'bin\vosk\vosk-win64-0.3.45'

$script:VoskCode = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class VoskApi
{
    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr vosk_model_new(string modelPath);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void vosk_model_free(IntPtr model);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr vosk_recognizer_new(IntPtr model, float sampleRate);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void vosk_recognizer_free(IntPtr recognizer);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int vosk_recognizer_accept_waveform(IntPtr recognizer, byte[] data, int length);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr vosk_recognizer_final_result(IntPtr recognizer);

    [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void vosk_set_log_level(int logLevel);

    private static IntPtr cachedModel = IntPtr.Zero;
    private static string cachedPath = null;
    private static bool silenced = false;

    // UTF-8 pointer -> managed string. Marshal.PtrToStringAnsi would decode the
    // Russian JSON as ANSI and turn it into mojibake, so read bytes by hand.
    private static string Utf8From(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return "";
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0) length++;
        byte[] buffer = new byte[length];
        Marshal.Copy(pointer, buffer, 0, length);
        return Encoding.UTF8.GetString(buffer);
    }

    // Skip RIFF chunks until the PCM payload of a 16-bit mono WAV is found.
    private static byte[] ReadPcm(string wavPath, out int sampleRate)
    {
        byte[] all = File.ReadAllBytes(wavPath);
        sampleRate = 16000;
        int offset = 12;
        while (offset + 8 <= all.Length)
        {
            string id = Encoding.ASCII.GetString(all, offset, 4);
            int size = BitConverter.ToInt32(all, offset + 4);
            if (id == "fmt " && offset + 8 + 16 <= all.Length)
            {
                sampleRate = BitConverter.ToInt32(all, offset + 8 + 4);
            }
            if (id == "data")
            {
                int start = offset + 8;
                int available = all.Length - start;
                if (size > available || size <= 0) size = available;
                byte[] pcm = new byte[size];
                Array.Copy(all, start, pcm, 0, size);
                return pcm;
            }
            offset += 8 + size + (size % 2);
        }
        throw new Exception("no data chunk in " + wavPath);
    }

    private static IntPtr GetModel(string modelPath)
    {
        if (!silenced)
        {
            // Kaldi-style LOG lines on stderr would otherwise flood the console.
            vosk_set_log_level(-1);
            silenced = true;
        }
        if (cachedModel != IntPtr.Zero && cachedPath == modelPath) return cachedModel;
        if (cachedModel != IntPtr.Zero)
        {
            vosk_model_free(cachedModel);
            cachedModel = IntPtr.Zero;
        }
        cachedModel = vosk_model_new(modelPath);
        if (cachedModel != IntPtr.Zero) cachedPath = modelPath;
        return cachedModel;
    }

    public static bool ModelReady(string modelPath)
    {
        return GetModel(modelPath) != IntPtr.Zero;
    }

    public static string Transcribe(string modelPath, string wavPath)
    {
        int rate;
        byte[] pcm = ReadPcm(wavPath, out rate);

        IntPtr model = GetModel(modelPath);
        if (model == IntPtr.Zero) return "__ERROR__ model load failed: " + modelPath;

        IntPtr rec = vosk_recognizer_new(model, (float)rate);
        if (rec == IntPtr.Zero) return "__ERROR__ recognizer init failed";

        string result;
        try
        {
            vosk_recognizer_accept_waveform(rec, pcm, pcm.Length);
            result = Utf8From(vosk_recognizer_final_result(rec));
        }
        finally
        {
            // Only the recognizer is per-turn: the model stays cached.
            vosk_recognizer_free(rec);
        }
        return result;
    }

    public static void Unload()
    {
        if (cachedModel != IntPtr.Zero)
        {
            vosk_model_free(cachedModel);
            cachedModel = IntPtr.Zero;
            cachedPath = null;
        }
    }
}
'@

# Native DLL is loaded by full path first: DllImport("libvosk.dll") then resolves
# against the already-loaded module instead of the process search path.
if (-not ('VoskApi' -as [type])) {
  $dll = Join-Path $script:VoskRoot 'libvosk.dll'
  if (-not (Test-Path $dll)) { throw "libvosk.dll not found at $dll" }
  Add-Type -TypeDefinition $script:VoskCode -Language CSharp
  $loader = @'
using System;
using System.Runtime.InteropServices;
public class NativeLoader
{
    // LOAD_WITH_ALTERED_SEARCH_PATH: lets libvosk.dll find its sibling runtime
    // DLLs (libstdc++-6, libgcc_s_seh-1, libwinpthread-1) in its own folder.
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);
}
'@
  if (-not ('NativeLoader' -as [type])) { Add-Type -TypeDefinition $loader -Language CSharp }
  $h = [NativeLoader]::LoadLibraryExW($dll, [IntPtr]::Zero, 0x00000008)
  if ($h -eq [IntPtr]::Zero) { throw "LoadLibraryExW failed for $dll" }
}

$script:SlovarPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'slovar.txt'

function Get-SlovarPath {
  return $script:SlovarPath
}

# Replacement map loaded from slovar.txt and reused until the file changes:
#   как услышал => как надо
# Loading is a few dozen milliseconds once; applying is O(words in the phrase)
# because entries are indexed by their first word. No restart is needed after an
# edit — the file stamp is compared on every call.
$script:SlovarStamp = ''
$script:SlovarIndex = $null
$script:SlovarMaxWords = 1

function Update-SlovarCache {
  $path = $script:SlovarPath
  if (-not (Test-Path $path)) {
    $script:SlovarStamp = ''
    $script:SlovarIndex = $null
    return
  }
  $item = Get-Item $path
  $stamp = [string]$item.LastWriteTimeUtc.Ticks + ':' + [string]$item.Length
  if ($stamp -eq $script:SlovarStamp) { return }

  $index = @{}
  $maxWords = 1
  $lines = [IO.File]::ReadAllLines($path, (New-Object System.Text.UTF8Encoding($false)))
  foreach ($line in $lines) {
    $s = ([string]$line).TrimStart([char[]]@([char]0xFEFF)).Trim()
    if ($s -eq '' -or $s.StartsWith('#')) { continue }
    $split = $s.IndexOf('=>')
    if ($split -lt 1) { continue }
    $left = [regex]::Replace($s.Substring(0, $split).Trim().ToLower(), '\s+', ' ')
    $right = $s.Substring($split + 2).Trim()
    if ($left -eq '' -or $right -eq '') { continue }
    $index[$left] = $right
    $count = ([regex]::Split($left, ' ')).Count
    if ($count -gt $maxWords) { $maxWords = $count }
  }

  $script:SlovarIndex = $index
  $script:SlovarMaxWords = $maxWords
  $script:SlovarStamp = $stamp
}

function Convert-VoskSlovar {
  param([string]$Text)
  if ($Text -eq '') { return $Text }
  Update-SlovarCache
  if ($script:SlovarIndex -eq $null -or $script:SlovarIndex.Count -eq 0) { return $Text }

  # Vosk output is lowercase without punctuation, so match on lowercased words
  # and take the replacement verbatim ("DeepSeek", "API").
  $tokens = [regex]::Split($Text.ToLower(), '\s+')
  $out = New-Object System.Collections.ArrayList
  $i = 0
  while ($i -lt $tokens.Count) {
    $matched = $false
    $maxLen = [Math]::Min($script:SlovarMaxWords, $tokens.Count - $i)
    for ($len = $maxLen; $len -ge 1; $len--) {
      if ($len -eq 1) { $candidate = $tokens[$i] }
      else { $candidate = ($tokens[$i..($i + $len - 1)] -join ' ') }
      if ($script:SlovarIndex.ContainsKey($candidate)) {
        [void]$out.Add([string]$script:SlovarIndex[$candidate])
        $i += $len
        $matched = $true
        break
      }
    }
    if (-not $matched) {
      [void]$out.Add($tokens[$i])
      $i++
    }
  }
  return ($out -join ' ')
}

function Get-VoskText {
  param(
    [string]$ModelDir = '',
    [string]$WavPath = ''
  )
  if ($ModelDir -eq '') { $ModelDir = Join-Path (Split-Path -Parent $script:SlovarPath) 'bin\vosk-model-small-ru-0.22' }
  if (-not (Test-Path $ModelDir)) { return "__ERROR__ model dir missing: $ModelDir" }
  if ($WavPath -eq '') { $WavPath = Join-Path (Join-Path (Split-Path -Parent $script:SlovarPath) 'tmp') 'rec.wav' }
  if (-not (Test-Path $WavPath)) { return "__ERROR__ wav missing: $WavPath" }

  $json = [VoskApi]::Transcribe($ModelDir, $WavPath)
  if ($json.StartsWith('__ERROR__')) { return $json }

  # {"text" : "привет как дела"}
  $m = [regex]::Match($json, '"text"\s*:\s*"([^"]*)"')
  if (-not $m.Success) { return '' }
  $text = $m.Groups[1].Value
  # Vosk keeps spaces inside words for Russian; collapse and trim.
  $text = [regex]::Replace($text, '\s+', ' ').Trim()
  return (Convert-VoskSlovar -Text $text)
}
