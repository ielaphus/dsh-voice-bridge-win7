# recorder.ps1 — microphone capture definitions (dot-source, no side effects).
# Two modes:
#   Record-Wav  — fixed-length window (tests, diagnostics)
#   Push-To-Talk — record while SPACE is held, stop shortly after release
#
# winmm (waveIn) is used directly: there is no speech recognizer and no ffmpeg
# on this host. Key state comes from GetAsyncKeyState, so the space bar works
# no matter which window has focus.
#
# The internal Conexant mic records very quietly (noise floor around -50 dBFS),
# so PCM is normalised while it is written: peak is lifted toward 16000 with a
# capped gain, and noise below -60 dBFS is left alone so the recognizer has
# nothing to hallucinate words from.

$script:RecorderRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:RecorderCode = @'
using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class DshRec
{
    public const int VK_SPACE = 0x20;
    public const int VK_Q = 0x51;
    public const int VK_ESCAPE = 0x1B;

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    [DllImport("winmm.dll")] private static extern int waveInGetNumDevs();
    [DllImport("winmm.dll")] private static extern int waveInOpen(out IntPtr hwi, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
    [DllImport("winmm.dll")] private static extern int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")] private static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")] private static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")] private static extern int waveInStart(IntPtr hwi);
    [DllImport("winmm.dll")] private static extern int waveInStop(IntPtr hwi);
    [DllImport("winmm.dll")] private static extern int waveInReset(IntPtr hwi);
    [DllImport("winmm.dll")] private static extern int waveInClose(IntPtr hwi);

    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

    public const int VK_RMENU = 0xA5;     // right Alt
    public const int VK_RCONTROL = 0xA3;  // right Ctrl
    public const int VK_F9 = 0x78;

    public static int Devices()
    {
        return waveInGetNumDevs();
    }

    private static bool Down(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    // Keys are polled globally (GetAsyncKeyState), so a press anywhere counts.
    // When gating is on, a key only counts while THIS console window is the
    // foreground window: typing in another window then cannot start a recording,
    // and a Russian "й" (the physical Q) can no longer quit the bridge.
    private static bool WindowActive()
    {
        IntPtr consoleWnd = GetConsoleWindow();
        if (consoleWnd == IntPtr.Zero) return true;
        return GetForegroundWindow() == consoleWnd;
    }

    private static void Beep(int frequency, int durationMs)
    {
        try { Console.Beep(frequency, durationMs); } catch { }
    }

    // Normalise + write + describe. Shared by both recording modes.
    private static string Finalize(string path, byte[] data, int used, int rate, bool normalize)
    {
        int sampleCount = used / 2;
        int peak = 0;
        long sumSq = 0;
        for (int i = 0; i < sampleCount; i++)
        {
            short s = BitConverter.ToInt16(data, i * 2);
            int a = s < 0 ? -s : s;
            if (a > peak) peak = a;
            sumSq += (long)s * (long)s;
        }
        double rms = sampleCount > 0 ? Math.Sqrt((double)sumSq / sampleCount) : 0.0;
        double dbfs = rms <= 0 ? -120.0 : 20.0 * Math.Log10(rms / 32768.0);

        double gain = 1.0;
        bool amplified = false;
        if (normalize && peak > 300 && peak < 16000 && dbfs > -60.0)
        {
            gain = 16000.0 / peak;
            if (gain > 8.0) gain = 8.0;
            if (gain > 1.05)
            {
                amplified = true;
                for (int i = 0; i < sampleCount; i++)
                {
                    short s = BitConverter.ToInt16(data, i * 2);
                    int v = (int)Math.Round(s * gain);
                    if (v > 32767) v = 32767;
                    if (v < -32768) v = -32768;
                    data[i * 2] = (byte)(v & 0xFF);
                    data[i * 2 + 1] = (byte)((v >> 8) & 0xFF);
                }
            }
            else
            {
                gain = 1.0;
            }
        }

        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            BinaryWriter w = new BinaryWriter(fs);
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write((int)(36 + used));
            w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write((int)16);
            w.Write((short)1);
            w.Write((short)1);
            w.Write((int)rate);
            w.Write((int)(rate * 2));
            w.Write((short)2);
            w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write((int)used);
            w.Write(data);
            w.Flush();
            w.Close();
        }

        return "ok:" + used
            + " peak=" + peak
            + " dbfs=" + dbfs.ToString("F1", CultureInfo.InvariantCulture)
            + " gain=" + gain.ToString("F2", CultureInfo.InvariantCulture)
            + " amplified=" + (amplified ? "1" : "0");
    }

    private static void CopyBack(IntPtr hdrPtr, IntPtr buf, int bytes, out byte[] data, out int used)
    {
        WAVEHDR done = (WAVEHDR)Marshal.PtrToStructure(hdrPtr, typeof(WAVEHDR));
        used = (int)done.dwBytesRecorded;
        if (used <= 0 || used > bytes) used = bytes;
        data = new byte[used];
        Marshal.Copy(buf, data, 0, used);
    }

    // deviceIndex < 0 means WAVE_MAPPER (the Windows default input).
    public static string RecordWav(string path, int seconds, int rate, bool normalize, int deviceIndex)
    {
        WAVEFORMATEX fmt = MakeFormat(rate);
        IntPtr h = IntPtr.Zero;
        uint device = deviceIndex < 0 ? unchecked((uint)-1) : (uint)deviceIndex;
        int rc = waveInOpen(out h, device, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (rc != 0) return "open_failed_" + rc;

        int bytes = rate * 2 * seconds;
        IntPtr buf = Marshal.AllocHGlobal(bytes);
        int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
        IntPtr hdrPtr = Marshal.AllocHGlobal(hdrSize);
        Prepare(h, buf, bytes, hdrPtr, hdrSize);

        waveInStart(h);
        Thread.Sleep(seconds * 1000);
        waveInStop(h);
        waveInReset(h);

        byte[] data;
        int used;
        CopyBack(hdrPtr, buf, bytes, out data, out used);
        Release(h, hdrPtr, hdrSize, buf);

        return Finalize(path, data, used, rate, normalize);
    }

    // Record while the talk key is held. Returns "quit" on Q/Esc, "short:<ms>"
    // if the key was tapped, otherwise "ok:<bytes> ... dur_ms=<ms>".
    //
    // talkNeedsForeground: the talk key counts only while this console window is
    // focused (off by default: the bridge listens from any window).
    // quitNeedsForeground: Q/Esc quit only while this window is focused. It is on
    // by default because those are ordinary characters: a Russian "й" is the
    // physical Q, so an unfocused quit key would end the bridge mid-typing.
    public static string PushToTalk(string path, int rate, int maxSeconds, int minSeconds, int tailMs, bool normalize)
    {
        return PushToTalk(path, rate, maxSeconds, minSeconds, tailMs, normalize, VK_SPACE, false, true);
    }

    public static string PushToTalk(string path, int rate, int maxSeconds, int minSeconds, int tailMs, bool normalize, int talkKey, bool talkNeedsForeground, bool quitNeedsForeground)
    {
        // Wait for a clean edge: the talk key must be up before we accept a press.
        while (true)
        {
            if (!talkNeedsForeground || WindowActive())
            {
                if (!Down(talkKey)) break;
            }
            Thread.Sleep(20);
        }

        while (true)
        {
            if (!quitNeedsForeground || WindowActive())
            {
                if (Down(VK_Q) || Down(VK_ESCAPE)) return "quit";
            }
            if (!talkNeedsForeground || WindowActive())
            {
                if (Down(talkKey)) break;
            }
            Thread.Sleep(15);
        }

        WAVEFORMATEX fmt = MakeFormat(rate);
        IntPtr h = IntPtr.Zero;
        int rc = waveInOpen(out h, unchecked((uint)-1), ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (rc != 0) return "open_failed_" + rc;

        int bytes = rate * 2 * maxSeconds;
        IntPtr buf = Marshal.AllocHGlobal(bytes);
        int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
        IntPtr hdrPtr = Marshal.AllocHGlobal(hdrSize);
        Prepare(h, buf, bytes, hdrPtr, hdrSize);

        Beep(900, 70);
        waveInStart(h);

        int held = 0;
        while (Down(talkKey) && held < maxSeconds * 1000)
        {
            Thread.Sleep(15);
            held += 15;
        }
        // A short tail keeps the last syllable from being cut off.
        Thread.Sleep(tailMs);

        waveInStop(h);
        waveInReset(h);

        byte[] data;
        int used;
        CopyBack(hdrPtr, buf, bytes, out data, out used);
        Release(h, hdrPtr, hdrSize, buf);
        Beep(520, 110);

        int durationMs = (int)((long)used * 1000 / (rate * 2));
        if (durationMs < minSeconds * 1000) return "short:" + durationMs;

        return Finalize(path, data, used, rate, normalize) + " dur_ms=" + durationMs;
    }

    private static WAVEFORMATEX MakeFormat(int rate)
    {
        WAVEFORMATEX fmt = new WAVEFORMATEX();
        fmt.wFormatTag = 1;
        fmt.nChannels = 1;
        fmt.nSamplesPerSec = (uint)rate;
        fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = 2;
        fmt.nAvgBytesPerSec = (uint)(rate * 2);
        fmt.cbSize = 0;
        return fmt;
    }

    private static void Prepare(IntPtr h, IntPtr buf, int bytes, IntPtr hdrPtr, int hdrSize)
    {
        WAVEHDR hdr = new WAVEHDR();
        hdr.lpData = buf;
        hdr.dwBufferLength = (uint)bytes;
        hdr.dwFlags = 0;
        Marshal.StructureToPtr(hdr, hdrPtr, false);
        waveInPrepareHeader(h, hdrPtr, (uint)hdrSize);
        waveInAddBuffer(h, hdrPtr, (uint)hdrSize);
    }

    private static void Release(IntPtr h, IntPtr hdrPtr, int hdrSize, IntPtr buf)
    {
        waveInUnprepareHeader(h, hdrPtr, (uint)hdrSize);
        waveInClose(h);
        Marshal.FreeHGlobal(buf);
        Marshal.FreeHGlobal(hdrPtr);
    }
}
'@

if (-not ('DshRec' -as [type])) {
  Add-Type -TypeDefinition $script:RecorderCode -Language CSharp
}

function Get-RecorderDevices {
  return [DshRec]::Devices()
}

function Record-Wav {
  param(
    [string]$Path = '',
    [int]$Seconds = 8,
    [int]$Rate = 16000,
    [bool]$Normalize = $true,
    [int]$Device = -1
  )
  if ($Path -eq '') { $Path = Join-Path (Join-Path $script:RecorderRoot 'tmp') 'rec.wav' }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return [DshRec]::RecordWav($Path, $Seconds, $Rate, $Normalize, $Device)
}

function Get-TalkKeyVk {
  # Talk-key name to virtual-key code. Right Alt is the default: it is never
  # typed as a character, so holding it to talk cannot disturb typing.
  param([string]$Name = 'ralt')
  switch ($Name.ToLower()) {
    'space'     { return 0x20 }
    'ralt'      { return 0xA5 }
    'rightalt'  { return 0xA5 }
    'altgr'     { return 0xA5 }
    'rctrl'     { return 0xA3 }
    'rightctrl' { return 0xA3 }
    'f9'        { return 0x78 }
    default     { throw ('unknown talk key: ' + $Name + ' (ralt, space, rctrl, f9)') }
  }
}

function Record-PushToTalk {
  param(
    [string]$Path = '',
    [int]$Rate = 16000,
    [int]$MaxSeconds = 30,
    [int]$MinSeconds = 1,
    [int]$TailMs = 200,
    [bool]$Normalize = $true,
    [string]$TalkKey = 'ralt',
    [bool]$TalkNeedsConsole = $false,
    [bool]$QuitNeedsConsole = $true
  )
  if ($Path -eq '') { $Path = Join-Path (Join-Path $script:RecorderRoot 'tmp') 'rec.wav' }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $vk = Get-TalkKeyVk -Name $TalkKey
  return [DshRec]::PushToTalk($Path, $Rate, $MaxSeconds, $MinSeconds, $TailMs, $Normalize, $vk, $TalkNeedsConsole, $QuitNeedsConsole)
}
