# Installation

Everything is file-based. Nothing is installed into Windows, no registry keys are written, no
Python, no git, no build tools are needed.

```
your-folder\
  start.cmd  voice.ps1  recorder.ps1  vosk.ps1  agentd.js  ...   (this repository)
  bin\                                                            (assets you download, ignored by git)
```

## 1. Assets under `bin\`

### 1.1 Speech recognition: libvosk + a model

Get the Windows x64 Vosk build from the Vosk project (releases of `alphacep/vosk-api`,
`vosk-win64-0.3.45.zip`) and the Russian small model from the Vosk models page
(`vosk-model-small-ru-0.22.zip`, ≈46 MB).

Unpack so that these two paths exist:

```
bin\vosk\vosk-win64-0.3.45\libvosk.dll          (+ libstdc++-6.dll, libgcc_s_seh-1.dll, libwinpthread-1.dll
                                                  and libstdc++'s siblings that came in the same archive)
bin\vosk-model-small-ru-0.22\am\... conf\... graph\... ivector\...
```

`vosk.ps1` looks for `bin\vosk\vosk-win64-0.3.45\libvosk.dll` and loads it by full path, so its
runtime DLLs must stay next to it.

> An English model (`vosk-model-small-en-us-0.22`) works through the same code:
> `start.cmd -ModelDir bin\vosk-model-small-en-us-0.22`. One model at a time.

### 1.2 Synthesis: RHVoice engine and voices

Download the RHVoice 1.18.2 Windows x64 build and one or more voice packages from the RHVoice
project (engine: `RHVoice/RHVoice` releases; voices are separate packages such as
`RHVoice-voice-Anna`, `-Elena`, `-Irina`, `-Aleksandr` for Russian, `-Alan`, `-Bdl`, `-Slp` for
English). The installers can be extracted with 7-Zip; only files are needed.

Required layout:

```
bin\rhvoice\engine\synthDrivers\RHVoice\lib\x64\RHVoice.dll
bin\rhvoice\engine\synthDrivers\RHVoice\__init__.py         (shipped in the engine package)
bin\rhvoice\<voice>\data\        voice.info, voice.params, 16000\, 24000\ ...
bin\rhvoice\<voice>\langdata\    g2p.fst, stress.fst, ...
bin\rhvoice\<voice>\manifest.ini
```

`<voice>` is the lowercase voice name: `anna`, `elena`, `irina`, `aleksandr`, `alan`, …

Select a voice at run time:

```bat
start.cmd -Voice Anna
start.cmd -Voice Alan
```

An English voice speaks English text with English phonemes; the engine picks the language from
the voice package (`langdata\language.info`), so nothing else has to change. Note that
**recognition** is still whichever Vosk model is loaded — Russian here.

`rhvoice_voices.ps1` (not shipped in the release tree) can synthesize a sample per voice if you
want to compare them by ear; any of the shipped scripts shows the same call pattern.

## 2. The DSH plugin (required)

The turn must be written by the DSH desktop app itself. That is what `plugin/dsh-voice-turn` is
for; without it the bridge reports `voice-turn plugin is not running`.

Install into the DSH profile that the desktop app uses (here: `%USERPROFILE%\.dsh\profiles\desktop`):

1. Copy the folder so that this file exists:

   ```
   %USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-voice-turn\index.js
   %USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-voice-turn\package.json
   %USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-voice-turn\cordis.patch.yml
   ```

2. Register it as a profile bundle — edit `%USERPROFILE%\.dsh\profiles\desktop\package.json`:

   ```json
   {
     "dsh": {
       "profile": {
         "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-voice-turn"]
       }
     }
   }
   ```

   Keep the existing bundle list of your profile and just append `dsh-voice-turn`.

3. The plugin's own `cordis.patch.yml` inserts its row and carries the defaults
   (`port: 43198`, `workspacePath` — set this to the folder your DSH workspace uses, e.g.
   `C:\Users\you\sandbox`, `logFile` — optional diagnostics file).

4. **Restart DSH Desktop once.** Profile bundles are read at startup.

Check that it came up:

```bat
powershell -ExecutionPolicy Bypass -File plugin-check.ps1
:: port : open
:: reply: {"ok":true,"pong":true,"gateway":true,"sessionId":null}
```

## 3. First run

```bat
start.cmd
```

Expected console output (ASCII by design — the host console is CP866):

```
  DSH voice bridge (push to talk)
  model : ...\bin\vosk-model-small-ru-0.22
  tts   : RHVoice 1.18.2, Anna, pitch 0.9, speed 1, vol 0.5, out 44100 Hz, lp 7500, peak 0.85
  agent : starting
  HOLD RIGHT ALT while speaking, release to send
  key works from ANY window; Q or Esc (this window only) = quit   max 30 s per turn
  session : (creating)
```

The first turn creates the DSH session (title comes from the first words of the question) and
takes a few seconds longer. After that each turn is: record → ~1.5 s recognition → model answer
→ ~0.5 s synthesis.

## 4. Settings worth knowing

| Switch | Default | Meaning |
| --- | --- | --- |
| `-Hotkey` | `ralt` | talk key: `ralt`, `space`, `rctrl`, `f9` |
| `-ConsoleOnly` | off | keys only while the bridge window is focused |
| `-MaxSeconds` / `-MinSeconds` | 30 / 1 | recording length, minimum hold |
| `-Pitch` | 0.90 | voice height (0.75 duller, 1.0 brighter) |
| `-Speed` | 1.0 | speaking rate |
| `-Volume` | 0.5 | output level (RHVoice gain, not player volume) |
| `-Lowpass` | 7500 | anti-buzz low-pass in Hz (`6000` duller, `9000` brighter) |
| `-Highpass` | 90 | removes rumble/DC |
| `-Gain` | 0.85 | peak ceiling with soft knee |
| `-OutRate` | 44100 | sample rate written to the WAV |
| `-NewSession` | off | start a new DSH session |
| `-StopAgent` | off | stop the bridge daemon |

Voice answers are spoken by RHVoice after a light DSP pass (high-pass → double low-pass →
resample → peak limit). The pass exists because cheap laptop speakers buzz on a hot 24 kHz
signal with real energy up to 12 kHz; on a proper amplifier `-Lowpass 9000 -Volume 1.0` is fine.

## 5. Replacement dictionary

`slovar.txt` is a plain list, `heard => wanted`, applied to the recognized text:

```
дипсик => DeepSeek
апи => API
```

* left side is always the **Cyrillic** spelling the recognizer produces;
* multi-word entries are matched as a phrase, longest first;
* the file is re-read when it changes, no restart needed;
* cost is ~10 ms per turn.

Helpers:

```bat
slovar.cmd -Add "дипсик => DeepSeek"
slovar.cmd -Check
slovar.cmd -Test      :: runs every entry through the real matcher and reports problems
```

`-Test` catches the classic mistakes: an inverted entry (`solidworks => солидворкс`), a Latin
left side (the recognizer never outputs Latin), duplicates, no-ops and format errors. Details go
to `tmp\slovar-test.txt`.

The voice assistant itself can edit the dictionary: the session prompt tells it that
"add to the dictionary X = Y" means appending one line to `slovar.txt`.

## 6. Word documents from voice

`word.cmd` reads and edits `.docx` without Word and without installs (ZIP + OOXML on the Node
runtime inside DSH):

```bat
word.cmd -Action info    -Path report.docx
word.cmd -Action read    -Path report.docx -OutFile tmp\report.txt
word.cmd -Action write   -Path report.docx -TextFile text.txt
word.cmd -Action append  -Path report.docx -TextFile more.txt
word.cmd -Action replace -Path report.docx -Find "old" -ReplaceWith "new"
```

Text is UTF-8 and one line becomes one paragraph; styles, images and headers are copied
untouched. Use `-OutFile` for reading: the console here is CP866 and would mangle Cyrillic.
Word COM automation is deliberately not used — an invisible Word 2007 blocks on a modal dialog
on this class of machine.

## 7. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `voice-turn plugin is not running: restart DSH Desktop` | plugin not installed or DSH not restarted; run `plugin-check.ps1` |
| `agent unavailable (...), turn skipped` | the daemon or the plugin failed; look at `tmp\agentd.log` |
| `Отсутствует ")" в вызове метода` / parse error on start | a script lost its UTF-8 BOM; `start.cmd` runs `ensure-bom.ps1` to repair it |
| `RECORD FAILED` / `no speech recognized` | wrong input device (`micdiag.ps1` in the source tree lists devices) or too quiet input |
| `tts : FAILED ...` | RHVoice DLL or voice data missing at the paths above |
| answers are silent, WAVs exist | no playback device; the WAVs are in `tmp\speech_N.wav` |
| HTTPS downloads fail from PowerShell | system TLS 1.2 is off on such hosts; use `fetch.js` (Node) instead |
| `Пробел/Alt` does nothing | wrong `-Hotkey`, or `-ConsoleOnly` is set while another window is focused |

Everything the bridge learns about a turn is in `tmp\agentd.log` (`session=`, `answered ms=`,
`prefix=1/0`), and `tmp\agentd-session.txt` holds the current DSH session id.
