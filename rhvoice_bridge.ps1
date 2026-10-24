# rhvoice_bridge.ps1 — definitions for calling RHVoice.dll from PowerShell.
# Dot-source this: it compiles the C# shim and exposes Load/New/Speak/Dispose.
# No installation is involved: the engine and voice data are plain files.

$script:RhvCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class Rhv
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int SetSampleRateFn(int sampleRate, IntPtr userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int PlaySpeechFn(IntPtr samples, uint count, IntPtr userData);

    [StructLayout(LayoutKind.Sequential)]
    public struct Callbacks
    {
        public IntPtr set_sample_rate;
        public IntPtr play_speech;
        public IntPtr process_mark;
        public IntPtr word_starts;
        public IntPtr word_ends;
        public IntPtr sentence_starts;
        public IntPtr sentence_ends;
        public IntPtr play_audio;
        public IntPtr done;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct InitParams
    {
        public IntPtr data_path;
        public IntPtr config_path;
        public IntPtr resource_paths;
        public Callbacks callbacks;
        public uint options;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SynthParams
    {
        public IntPtr voice_profile;
        public double absolute_rate;
        public double absolute_pitch;
        public double absolute_volume;
        public double relative_rate;
        public double relative_pitch;
        public double relative_volume;
        public int punctuation_mode;
        public IntPtr punctuation_list;
        public int capitals_mode;
        public int flags;
    }

    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr RHVoice_get_version();
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr RHVoice_new_tts_engine(ref InitParams p);
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void RHVoice_delete_tts_engine(IntPtr engine);
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint RHVoice_get_number_of_voices(IntPtr engine);
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr RHVoice_new_message(IntPtr engine, byte[] text, uint length, int type, IntPtr synthParams, IntPtr userData);
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int RHVoice_speak(IntPtr message);
    [DllImport("RHVoice.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void RHVoice_delete_message(IntPtr message);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);

    private static List<short> samples = new List<short>();
    private static int rate = 24000;
    private static SetSampleRateFn rateFn = OnRate;
    private static PlaySpeechFn playFn = OnPlay;

    // Post-processing knobs, set by Configure() through tts.ps1/voice.ps1.
    // Cheap laptop speakers buzz when fed a hot 24 kHz signal that still has real
    // energy up to 12 kHz, so the chain is: high-pass (DC and rumble) ->
    // low-pass twice (hiss) -> resample to the device rate -> peak with headroom.
    public static int ConfigOutRate = 0;
    public static double ConfigHighpassHz = 0;
    public static double ConfigLowpassHz = 0;
    public static double ConfigPeak = 0;

    public static void Configure(int outRate, double highpassHz, double lowpassHz, double peak)
    {
        ConfigOutRate = outRate;
        ConfigHighpassHz = highpassHz;
        ConfigLowpassHz = lowpassHz;
        ConfigPeak = peak;
    }

    public static string DescribeFilters()
    {
        return "outRate=" + ConfigOutRate + " hp=" + ConfigHighpassHz + " lp=" + ConfigLowpassHz + " peak=" + ConfigPeak;
    }

    private static double[] Process(double[] x, int inRate)
    {
        int i;
        if (x.Length == 0) return x;

        if (ConfigHighpassHz > 0)
        {
            double rc = 1.0 / (2.0 * Math.PI * ConfigHighpassHz);
            double dt = 1.0 / inRate;
            double a = rc / (rc + dt);
            double prevX = 0;
            double prevY = 0;
            for (i = 0; i < x.Length; i++)
            {
                double y = a * (prevY + x[i] - prevX);
                prevX = x[i];
                prevY = y;
                x[i] = y;
            }
        }

        if (ConfigLowpassHz > 0)
        {
            double rc = 1.0 / (2.0 * Math.PI * ConfigLowpassHz);
            double dt = 1.0 / inRate;
            double a = dt / (rc + dt);
            for (int pass = 0; pass < 2; pass++)
            {
                double prev = 0;
                for (i = 0; i < x.Length; i++)
                {
                    prev = prev + a * (x[i] - prev);
                    x[i] = prev;
                }
            }
        }

        if (ConfigOutRate > 0 && ConfigOutRate != inRate)
        {
            // step is how far the read head moves in the SOURCE for one output
            // sample: inRate/outRate keeps the duration identical in both
            // directions (dividing by outRate/inRate would shorten audio when
            // upsampling, which is what the first version did).
            double step = (double)inRate / (double)ConfigOutRate;
            int outCount = (int)Math.Floor((x.Length - 1) / step) + 1;
            double[] resampled = new double[outCount];
            for (i = 0; i < outCount; i++)
            {
                double pos = i * step;
                int i0 = (int)Math.Floor(pos);
                if (i0 < 0) i0 = 0;
                if (i0 > x.Length - 1) i0 = x.Length - 1;
                int i1 = i0 + 1 < x.Length ? i0 + 1 : i0;
                double t = pos - i0;
                resampled[i] = x[i0] * (1.0 - t) + x[i1] * t;
            }
            x = resampled;
        }

        if (ConfigPeak > 0)
        {
            double peak = 0;
            for (i = 0; i < x.Length; i++)
            {
                double v = Math.Abs(x[i]);
                if (v > peak) peak = v;
            }
            if (peak > ConfigPeak)
            {
                double scale = ConfigPeak / peak;
                for (i = 0; i < x.Length; i++) x[i] = x[i] * scale;
            }
            // Soft knee above the ceiling: a hard clip is what a cheap speaker
            // turns into a crackle.
            double limit = 0.98;
            for (i = 0; i < x.Length; i++)
            {
                double v = x[i];
                if (v > limit) v = limit + (1.0 - limit) * Math.Tanh((v - limit) / (1.0 - limit));
                if (v < -limit) v = -limit - (1.0 - limit) * Math.Tanh((-v - limit) / (1.0 - limit));
                x[i] = v;
            }
        }

        return x;
    }

    private static int OnRate(int sampleRate, IntPtr userData)
    {
        rate = sampleRate;
        return 1;
    }

    private static int OnPlay(IntPtr data, uint count, IntPtr userData)
    {
        short[] buffer = new short[count];
        Marshal.Copy(data, buffer, 0, (int)count);
        samples.AddRange(buffer);
        return 1;
    }

    public static string Version()
    {
        IntPtr p = RHVoice_get_version();
        return p == IntPtr.Zero ? "?" : Marshal.PtrToStringAnsi(p);
    }

    public static bool Load(string dllPath)
    {
        return LoadLibraryExW(dllPath, IntPtr.Zero, 0x00000008) != IntPtr.Zero;
    }

    public static IntPtr Create(string[] paths)
    {
        IntPtr[] arr = new IntPtr[paths.Length + 1];
        for (int i = 0; i < paths.Length; i++) arr[i] = Marshal.StringToHGlobalAnsi(paths[i]);
        arr[paths.Length] = IntPtr.Zero;
        IntPtr resPtr = Marshal.AllocHGlobal(IntPtr.Size * arr.Length);
        Marshal.Copy(arr, 0, resPtr, arr.Length);

        Callbacks cb = new Callbacks();
        cb.set_sample_rate = Marshal.GetFunctionPointerForDelegate(rateFn);
        cb.play_speech = Marshal.GetFunctionPointerForDelegate(playFn);

        InitParams p = new InitParams();
        p.data_path = IntPtr.Zero;
        p.config_path = IntPtr.Zero;
        p.resource_paths = resPtr;
        p.callbacks = cb;
        p.options = 0;

        IntPtr engine = RHVoice_new_tts_engine(ref p);
        GC.KeepAlive(rateFn);
        GC.KeepAlive(playFn);
        return engine;
    }

    public static void Dispose(IntPtr engine)
    {
        if (engine != IntPtr.Zero) RHVoice_delete_tts_engine(engine);
    }

    public static uint VoiceCount(IntPtr engine)
    {
        return RHVoice_get_number_of_voices(engine);
    }

    public static string Speak(IntPtr engine, string voice, string text, string outPath, double speed, double pitch, double volume)
    {
        samples.Clear();
        rate = 24000;

        byte[] utf8 = Encoding.UTF8.GetBytes(text);
        byte[] voiceBytes = Encoding.UTF8.GetBytes(voice + "\0");

        SynthParams sp = new SynthParams();
        sp.relative_rate = speed > 0 ? speed : 1.0;
        sp.relative_pitch = pitch > 0 ? pitch : 1.0;
        sp.relative_volume = volume > 0 ? volume : 1.0;
        sp.punctuation_mode = 0;
        sp.capitals_mode = 0;

        IntPtr voicePtr = Marshal.AllocHGlobal(voiceBytes.Length);
        Marshal.Copy(voiceBytes, 0, voicePtr, voiceBytes.Length);
        sp.voice_profile = voicePtr;

        IntPtr spPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SynthParams)));
        Marshal.StructureToPtr(sp, spPtr, false);

        IntPtr msg = RHVoice_new_message(engine, utf8, (uint)utf8.Length, 0, spPtr, IntPtr.Zero);
        if (msg == IntPtr.Zero)
        {
            Marshal.FreeHGlobal(spPtr);
            Marshal.FreeHGlobal(voicePtr);
            return "message=null";
        }

        int rc = RHVoice_speak(msg);
        RHVoice_delete_message(msg);
        Marshal.FreeHGlobal(spPtr);
        Marshal.FreeHGlobal(voicePtr);

        int count = samples.Count;
        if (count == 0) return "no_audio rc=" + rc;

        int inRate = rate;
        double[] buffer = new double[count];
        for (int i = 0; i < count; i++) buffer[i] = samples[i] / 32768.0;
        buffer = Process(buffer, inRate);
        int outRate = ConfigOutRate > 0 ? ConfigOutRate : inRate;
        int outCount = buffer.Length;

        using (FileStream fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
        {
            BinaryWriter w = new BinaryWriter(fs);
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(36 + outCount * 2);
            w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write(16);
            w.Write((short)1);
            w.Write((short)1);
            w.Write(outRate);
            w.Write(outRate * 2);
            w.Write((short)2);
            w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(outCount * 2);
            for (int i = 0; i < outCount; i++)
            {
                double v = buffer[i];
                if (v > 1.0) v = 1.0;
                if (v < -1.0) v = -1.0;
                w.Write((short)Math.Round(v * 32767.0));
            }
            w.Flush();
            w.Close();
        }

        return "ok rc=" + rc + " in=" + inRate + " rate=" + outRate + " seconds=" + ((double)outCount / outRate).ToString("F3") + " " + DescribeFilters();
    }
}
'@

if (-not ('Rhv' -as [type])) { Add-Type -TypeDefinition $script:RhvCode -Language CSharp }

$script:RhvRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'bin\rhvoice'

function Start-RhvEngine {
  param(
    [string]$Root = $script:RhvRoot,
    [string]$VoiceDir = '',
    [string]$Voice = 'Aleksandr'
  )
  $dll = Join-Path $Root 'engine\synthDrivers\RHVoice\lib\x64\RHVoice.dll'
  if ($VoiceDir -eq '') { $VoiceDir = Join-Path $Root 'aleksandr' }
  $voiceData = Join-Path $VoiceDir 'data'
  $langData = Join-Path $VoiceDir 'langdata'
  if (-not (Test-Path $dll)) { throw "RHVoice.dll not found: $dll" }
  if (-not (Test-Path $voiceData)) { throw "voice data not found: $voiceData" }
  if (-not (Test-Path $dll)) { throw "RHVoice.dll not found: $dll" }
  if (-not [Rhv]::Load($dll)) { throw "LoadLibrary failed for $dll" }
  $engine = [Rhv]::Create(@($voiceData, $langData))
  if ($engine -eq [IntPtr]::Zero) { throw "engine creation failed (data paths rejected)" }
  return @{ engine = $engine; voice = $Voice; version = [Rhv]::Version(); voices = [Rhv]::VoiceCount($engine) }
}

function Invoke-RhvSpeak {
  param(
    [hashtable]$Engine,
    [string]$Text,
    [string]$OutPath,
    [double]$Speed = 1.0,
    [double]$Pitch = 1.0,
    [double]$Volume = 1.0,
    [int]$OutRate = 44100,
    [double]$Highpass = 90,
    [double]$Lowpass = 7500,
    [double]$Peak = 0.85
  )
  [Rhv]::Configure($OutRate, $Highpass, $Lowpass, $Peak)
  return [Rhv]::Speak($Engine.engine, $Engine.voice, $Text, $OutPath, $Speed, $Pitch, $Volume)
}

function Stop-RhvEngine {
  param([hashtable]$Engine)
  if ($Engine -ne $null) { [Rhv]::Dispose($Engine.engine) }
}
