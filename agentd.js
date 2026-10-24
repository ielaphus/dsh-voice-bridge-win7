// agentd.js — the voice bridge's text half.
//
// Why this file is small now: writing a turn into a DSH session must be done BY
// THE APP. A second DSH process (the ACP profile) cannot resume or append to a
// session the desktop host has open — the host owns that session, and a foreign
// append would corrupt the log. So DSH carries the `voice-turn` plugin
// (profiles\desktop\node_modules\dsh-voice-turn, port 127.0.0.1:43198): this
// daemon only forwards the recognized question there and returns the answer
// text. The turn is written by the app itself, which is why it shows up in the
// open conversation immediately.
//
// Line protocol on 127.0.0.1:AGENTD_PORT (voice.ps1 is the only client):
//   client -> daemon : one UTF-8 line (the question)
//   daemon -> client : "ok <llm_ms> <chars>" | "err <message>"
//   answer text      : tmp\agentd-answer.txt
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');

const HERE = __dirname;
const TMP = path.join(HERE, 'tmp');

// The session the bridge writes into. The desktop app creates it once (through
// the plugin) and the id stays here, so every spoken turn lands in ONE session.
const WORKDIR = process.env.AGENTD_WORKDIR || path.resolve(HERE, '..');
const PORT = Number(process.env.AGENTD_PORT || '43199');
const PLUGIN_PORT = Number(process.env.AGENTD_PLUGIN_PORT || '43198');
const PLUGIN_TIMEOUT_MS = Number(process.env.AGENTD_PLUGIN_TIMEOUT || '200000');

const ANSWER_FILE = path.join(TMP, 'agentd-answer.txt');
const LOG_FILE = path.join(TMP, 'agentd.log');
const PID_FILE = path.join(TMP, 'agentd.pid');
const SESSION_FILE = path.join(TMP, 'agentd-session.txt');

// The ACP profile's persona is "a coding agent", and a voice caller has no
// system message of its own, so every question states how the answer is used.
//
// The first words of the first question also become the session title in the
// DSH sidebar (the app derives it from the first human message), so the prompt
// opens with a short readable name before it gives any instruction.
//
// The stress instruction is why RHVoice was chosen: it understands "+" placed
// before a stressed vowel, and only a context-aware model can decide where the
// stress belongs in homographs (замок/замок, мука/мука) and names.
//
// The last sentences give the caller two local tools: the .docx editor
// (voice-dsh\word.cmd) and the replacement dictionary (voice-dsh\slovar.txt).
// They are named here because the voice session has no other place to learn them.
const WORD_HELPER = path.join(HERE, 'word.cmd');
const SLOVAR_FILE = path.join(HERE, 'slovar.txt');

const VOICE_PREFIX =
  'Голосовой ассистент. Отвечай коротко: одно-три предложения, ' +
  'без списков, без markdown, без кода, обычным текстом. ' +
  'Если в слове ударение можно понять неверно (омографы, редкие слова, имена), ' +
  'поставь знак + непосредственно перед ударной гласной. ' +
  'Смысл решает: за+мок (крепость) и зам+ок (устройство), ' +
  'му+ка (страдание) и мук+а (продукт). ' +
  'В обычных словах знак не ставь. ' +
  'Документы Word (.docx) читай и правь через ' + WORD_HELPER + ': ' +
  '-Action info|read|write|append|replace, справка -Help; текст читай с -OutFile ' +
  'и открывай файл инструментом read (консоль портит кириллицу). ' +
  'Словарь замен распознавания — файл ' + SLOVAR_FILE + '. ' +
  'Если я скажу "в словарь <как слышится> равно <как надо>" или ' +
  '"добавь в словарь ...", допиши туда ОДНУ строку вида ' +
  '"как слышится => как надо" (UTF-8, остальной файл не трогай, ' +
  'существующую строку с той же левой частью заменяй) и подтверди одной фразой. ' +
  'Вопрос: ';

function log(line) {
  try {
    fs.appendFileSync(LOG_FILE, '[' + new Date().toISOString() + '] ' + line + '\r\n');
  } catch (e) {
    /* ignore */
  }
}

if (!fs.existsSync(TMP)) fs.mkdirSync(TMP, { recursive: true });
fs.writeFileSync(PID_FILE, String(process.pid), 'utf8');

// Build signature: the launcher reuses a running daemon only when this file has
// not changed since it started (see agentd.ps1).
const BUILD_FILE = path.join(TMP, 'agentd.build');
try {
  fs.writeFileSync(BUILD_FILE, String(Math.floor(fs.statSync(__filename).mtimeMs)), 'utf8');
} catch (e) {
  /* ignore */
}

function readSessionId() {
  try {
    if (!fs.existsSync(SESSION_FILE)) return '';
    return fs.readFileSync(SESSION_FILE, 'utf8').trim();
  } catch (e) {
    return '';
  }
}

function writeSessionId(id) {
  try {
    fs.writeFileSync(SESSION_FILE, String(id) + '\r\n', 'utf8');
  } catch (e) {
    log('session id write failed: ' + String(e && e.message));
  }
}

// The instruction block is long, and it would show up in the transcript before
// every question. It is sent ONCE per session (the turn that opens it); after
// that the app's log holds clean questions, and the rules stay in context for
// the whole conversation.
const PREFIXED_FILE = path.join(TMP, 'agentd-prefixed.txt');

function prefixSentFor(sessionId) {
  try {
    if (!fs.existsSync(PREFIXED_FILE)) return false;
    return fs.readFileSync(PREFIXED_FILE, 'utf8').trim() === String(sessionId);
  } catch (e) {
    return false;
  }
}

function markPrefixSent(sessionId) {
  try {
    fs.writeFileSync(PREFIXED_FILE, String(sessionId) + '\r\n', 'utf8');
  } catch (e) {
    /* ignore */
  }
}

/** Send one JSON line to the in-app plugin and return its parsed reply. */
function askPlugin(request) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(PLUGIN_PORT, '127.0.0.1');
    let buffer = '';
    let settled = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket.destroy();
      } catch (e) {
        /* ignore */
      }
      if (error !== null) reject(error);
      else resolve(value);
    };

    const timer = setTimeout(
      () =>
        finish(
          new Error('voice-turn plugin did not answer in ' + String(PLUGIN_TIMEOUT_MS) + ' ms'),
        ),
      PLUGIN_TIMEOUT_MS,
    );

    socket.setEncoding('utf8');
    socket.on('connect', () => {
      socket.write(JSON.stringify(request) + '\n');
    });
    socket.on('data', (chunk) => {
      buffer += chunk;
      const index = buffer.indexOf('\n');
      if (index < 0) return;
      const line = buffer.slice(0, index).trim();
      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch (e) {
        finish(new Error('voice-turn plugin sent an unparsable reply'));
        return;
      }
      finish(null, parsed);
    });
    socket.on('error', (error) => {
      const code = String((error && error.code) || '');
      if (code === 'ECONNREFUSED') {
        finish(new Error('voice-turn plugin is not running: restart DSH Desktop'));
        return;
      }
      finish(new Error('voice-turn plugin: ' + String((error && error.message) || error)));
    });
    socket.on('close', () => finish(new Error('voice-turn plugin closed the connection')));
  });
}

let queue = Promise.resolve();

const server = net.createServer((socket) => {
  socket.setEncoding('utf8');
  let buffer = '';
  let replied = false;

  const reply = (line) => {
    if (replied) return;
    replied = true;
    try {
      socket.end(line + '\n');
    } catch (e) {
      /* ignore */
    }
  };

  socket.on('data', (chunk) => {
    buffer += chunk;
    const index = buffer.indexOf('\n');
    if (index < 0) return;
    const question = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);

    queue = queue.then(async () => {
      if (question === '') {
        reply('err empty question');
        return;
      }

      const started = Date.now();
      let sessionId = readSessionId();
      const fresh = sessionId === '';

      // Clean transcript: the instruction block rides only the first turn of a
      // session. Every later question is sent exactly as it was spoken.
      const needsPrefix = fresh || !prefixSentFor(sessionId);
      const request = { text: needsPrefix ? VOICE_PREFIX + question : question };
      if (fresh) request.new = true;
      else request.sessionId = sessionId;

      let result;
      try {
        result = await askPlugin(request);
      } catch (error) {
        const message = String((error && error.message) || error);
        log('plugin failed: ' + message);
        reply('err ' + message.replace(/\s+/g, ' '));
        return;
      }

      if (result.sessionId !== undefined && String(result.sessionId) !== sessionId) {
        sessionId = String(result.sessionId);
        writeSessionId(sessionId);
        log('session ready id=' + sessionId);
      }

      if (result.ok !== true) {
        const message = String(result.error || 'turn failed');
        log('turn failed: ' + message);
        reply('err ' + message.replace(/\s+/g, ' '));
        return;
      }

      if (needsPrefix) markPrefixSent(sessionId);

      const answer = String(result.answer || '').trim();
      const ms = Date.now() - started;
      fs.writeFileSync(ANSWER_FILE, answer, 'utf8');
      log(
        'answered ms=' + String(ms) +
          ' chars=' + String(answer.length) +
          ' session=' + sessionId +
          (needsPrefix ? ' prefix=1' : ' prefix=0'),
      );
      reply('ok ' + String(ms) + ' ' + String(answer.length));
    });
  });

  socket.on('error', () => {
    /* client vanished */
  });
});

server.on('error', (error) => {
  log('server error ' + String((error && error.message) || error));
  process.exit(3);
});

server.listen(PORT, '127.0.0.1', () => {
  log(
    'daemon start pid=' + String(process.pid) +
      ' port=' + String(PORT) +
      ' plugin=' + String(PLUGIN_PORT) +
      ' session=' + (readSessionId() || '(none yet)'),
  );
});
