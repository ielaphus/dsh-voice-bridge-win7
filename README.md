# DSH voice bridge

Push-to-talk voice front end for [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) on
Windows 7: hold a key, speak, and the recognized question is written into a **normal DSH
session** by DSH itself — so the dialogue appears in the app as text, and the answer is spoken
back through a local speech engine.

Everything runs offline: local speech recognition (Vosk), local synthesis (RHVoice), no cloud
STT/TTS, nothing installed into the system.

```
hold RIGHT ALT → speak → release
   ↓  winmm (waveIn)          recorder.ps1
   ↓  Vosk, 16 kHz mono       vosk.ps1      → text (+ slovar.txt replacements)
   ↓  DSH desktop app         agentd.js     → session/prompt via the in-app plugin
   ↓  RHVoice                 tts.ps1       → speech, sentence by sentence
```

## What makes it different

* **The app writes the turn.** A second DSH process cannot append to a session the desktop app
  holds, so this project ships a tiny DSH plugin (`plugin/dsh-voice-turn`) that accepts the
  recognized question over `127.0.0.1:43198` and submits it through the same gateway the GUI
  uses. The result is an ordinary turn in an ordinary session: visible immediately, stored
  normally, remembered by the model.
* **One session for everything.** The session id lives in `tmp\agentd-session.txt`; every later
  utterance goes there, also after restarts. `-NewSession` starts a fresh one.
* **Answer cleanup for speech.** Markdown is stripped, numbers are read out, and a replacement
  dictionary (`slovar.txt`) fixes predictable recognition errors, e.g. `дипсик => DeepSeek`.

## Requirements

| Component | Version / notes |
| --- | --- |
| Windows | 7 SP1 x64 (developed on it), Windows PowerShell 2.0 — .NET 2.0 CLR, no Python, no git |
| DSH desktop app | any recent build; the plugin is a plain ESM file, no build step |
| Vosk | `libvosk` 0.3.45 x64 + a model (`vosk-model-small-ru-0.22`, 46 MB) |
| RHVoice | 1.18.2 x64 engine + at least one voice (Russian ones used here) |

Assets are **not** in this repository: they are large and carry their own licenses. See
[INSTALL.md](INSTALL.md) for where to get each one and where it goes.

## Quick start

```bat
:: 1. put the assets under bin\ (see INSTALL.md)
:: 2. install the plugin into the DSH desktop profile and restart DSH once
:: 3. run
start.cmd
```

Then hold **RIGHT ALT**, speak, release. `Q` or `Esc` (with the bridge window focused) quits.

Useful switches:

```bat
start.cmd -Voice Elena            :: another installed RHVoice voice
start.cmd -Hotkey space           :: talk key: ralt (default), space, rctrl, f9
start.cmd -NewSession             :: start a new DSH session
start.cmd -Pitch 0.90 -Volume 0.5 :: voice height / level
start.cmd -Lowpass 6000           :: duller, less speaker buzz
```

## Layout

```
start.cmd              launcher (BOM guard + voice.ps1)
voice.ps1              main loop: key, record, transcribe, answer, speak
recorder.ps1           microphone capture (winmm waveIn), push-to-talk
vosk.ps1               speech recognition (P/Invoke libvosk) + slovar.txt replacement map
agentd.js              bridge daemon: question -> DSH plugin, answer -> text
agentd.ps1             start/stop that daemon, ask a question over TCP
tts.ps1                synthesis wrapper, sentence splitting
rhvoice_bridge.ps1     direct RHVoice.dll C API call + audio post-processing
slovar.txt / .js / .cmd  replacement dictionary and its helper
word.js / .cmd         .docx reader/editor (ZIP + OOXML, no Word, no installs)
plugin/dsh-voice-turn/ the DSH plugin that writes the turn
ensure-bom.ps1         keeps PowerShell 2.0 able to read the Russian scripts
fetch.js               HTTPS downloader (system TLS is unusable on such hosts)
```

## Limitations

* Speech recognition is **Russian** with the bundled model. An English model can be plugged in
  with `-ModelDir`, but the pipeline uses one model at a time.
* Synthesis quality is formant-based (RHVoice), not neural. Stress marks (`+` before the
  stressed vowel) are honoured by the engine, and the answering model is instructed to emit them.
* Windows PowerShell 2.0 needs a UTF-8 BOM for any file containing Cyrillic; `start.cmd` repairs
  it automatically (`ensure-bom.ps1`).
* No service, no autostart, no registry changes.

## License

MIT for this code. Third-party components keep their own licenses — see [NOTICE](NOTICE).
RHVoice is **GPL-3.0** and is **not** distributed here; install it yourself from its authors.
