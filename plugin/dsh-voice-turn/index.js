// dsh-voice-turn — a localhost endpoint that admits a SPOKEN question into a
// live DSH session.
//
// Why it exists: a second DSH process cannot write into a session the desktop
// app holds — DSH keeps one host per live session, so a foreign `session/resume`
// fails and a foreign append would corrupt the log. This plugin runs INSIDE the
// desktop host, so the turn it admits is an ordinary turn: the app writes it and
// the open conversation updates immediately.
//
// The turn is submitted through the SAME Remote gateway the GUI uses
// (`ctx.get('typertGateway').dispatchRpc('session/prompt', …)`) instead of
// calling the controller methods directly: the gateway resolves argument names,
// supplies the cancellation signal every query in that path expects, and maps
// failures to the same error objects the app shows.
//
// Protocol (one JSON line in, one JSON line out, 127.0.0.1:43198):
//   {"text": "...", "sessionId": "..."}  -> {"ok": true, "answer": "...", "sessionId": "..."}
//   {"text": "...", "new": true}         -> creates a session in the configured
//                                          workspace first, then answers
//   {"text": "..."}                      -> asks the app for the last session
//   failure                              -> {"ok": false, "error": "..."}
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export const name = 'voice-turn';

const DEFAULT_PORT = 43198;
const DEFAULT_TIMEOUT_MS = 180000;
const DEFAULT_WORKSPACE_PATH = '';
const DEFAULT_LOG_FILE = '';
const MAX_ANSWER_BYTES = 8000;

/** Collect the human-visible text blocks of one assistant message event. */
function assistantTextOf(event) {
  const content = event && event.data && event.data.message && event.data.message.content;
  if (!Array.isArray(content)) return '';
  let text = '';
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string') text += block.text;
  }
  return text;
}

/** First lines of a thrown value, for a log file that has no stack viewer. */
function brief(error) {
  const stack = String((error && error.stack) || (error && error.message) || error);
  return stack.split('\n').slice(0, 4).join(' | ').slice(0, 600);
}

export function apply(ctx, config) {
  const options = { ...(config || {}) };
  const port = Number(options.port) || DEFAULT_PORT;
  const timeoutMs = Number(options.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const workspacePath = String(options.workspacePath || DEFAULT_WORKSPACE_PATH);
  const logFile =
    String(options.logFile || DEFAULT_LOG_FILE) ||
    path.join(os.tmpdir(), 'dsh-voice-plugin.log');

  // The host has no console, so the plugin reports into a file: whether it was
  // loaded, whether the port opened, and how each turn ended.
  const log = (line) => {
    const text = '[' + new Date().toISOString() + '] ' + line + '\r\n';
    try {
      fs.appendFileSync(logFile, text);
    } catch (e) {
      /* logging must never break a turn */
    }
  };

  log('apply called: port=' + String(port) + ' workspace=' + workspacePath);

  /** One unary Remote call through the in-process gateway. */
  const rpc = async (endpoint, args) => {
    const gateway = ctx.get('typertGateway');
    if (gateway === undefined) throw new Error('typertGateway is not available in this host');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error('rpc timeout')), timeoutMs);
    let result;
    try {
      result = await gateway.dispatchRpc(endpoint, { args }, controller.signal);
    } finally {
      clearTimeout(timer);
    }
    if (result === undefined || result === null) throw new Error(endpoint + ': no result');
    if (result.ok !== true) {
      const failure = result.error || {};
      throw new Error(endpoint + ' failed: ' + String(failure.code) + ' ' + String(failure.message));
    }
    return result.value;
  };

  /** Resolve the configured workspace id (the app owns the registry). */
  const workspaceId = () => {
    const registry = ctx.get('workspaceRegistry');
    if (registry === undefined || typeof registry.list !== 'function') return undefined;
    const match = registry
      .list()
      .find((item) => String(item.path || '').toLowerCase() === workspacePath.toLowerCase());
    return match === undefined ? undefined : match.id;
  };

  /** Create a session in the configured workspace, exactly as the GUI would. */
  const createSession = async () => {
    if (workspacePath === '') {
      throw new Error('workspacePath is not configured in cordis.patch.yml');
    }
    const id = workspaceId();
    const request = id === undefined ? { cwd: workspacePath } : { workspaceId: id };
    const created = await rpc('session/create', { request });
    const sessionId = String((created && created.sessionId) || '');
    if (sessionId === '') throw new Error('session/create returned no sessionId');
    return sessionId;
  };

  /** Admit one prompt and wait for its turn to end, collecting the answer text. */
  const ask = (sessionId, text) =>
    new Promise((resolve) => {
      const requestId = 'voice-' + randomUUID();
      let started = false;
      let answer = '';
      let settled = false;
      let unbind = () => {};

      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try {
          unbind();
        } catch (e) {
          /* ignore */
        }
        resolve(result);
      };

      const onEvent = (session, event) => {
        if (settled) return;
        if (session === undefined || session.id !== sessionId) return;
        if (event === undefined) return;

        if (!started) {
          // Our own question proves the turn this request started has begun.
          const source = event.data && event.data.source;
          if (event.type === 'user/message' && source !== undefined && source.rpcId === requestId) {
            started = true;
          }
          return;
        }

        if (event.type === 'assistant/message') {
          const chunk = assistantTextOf(event);
          if (chunk !== '') answer += chunk;
          if (answer.length > MAX_ANSWER_BYTES) answer = answer.slice(0, MAX_ANSWER_BYTES);
          return;
        }

        if (event.type === 'turn/end') finish({ ok: true, answer: answer.trim() });
      };

      const timer = setTimeout(
        () => finish({ ok: false, error: 'timeout after ' + String(timeoutMs) + ' ms' }),
        timeoutMs,
      );

      const bound = ctx.on('session/event', onEvent);
      unbind = typeof bound === 'function' ? bound : () => {};

      // The Remote descriptor is `prompt(request, signal)`: the gateway resolves
      // arguments BY PARAMETER NAME and appends the cancellation signal itself,
      // so the payload is exactly one `request` field.
      rpc('session/prompt', {
        request: {
          sessionId,
          requestId,
          mode: 'queue',
          content: [{ type: 'text', text }],
        },
      }).then(
        () => {
          /* admitted: the answer arrives through session events */
        },
        (error) => {
          log('prompt rejected: ' + brief(error));
          finish({ ok: false, error: brief(error) });
        },
      );
    });

  let queue = Promise.resolve();

  const handle = async (raw) => {
    let request;
    try {
      request = JSON.parse(raw);
    } catch (e) {
      return { ok: false, error: 'request is not JSON' };
    }

    // Health check: proves the plugin is loaded and the gateway is reachable
    // without spending a model turn.
    if (request && request.ping === true) {
      const gateway = ctx.get('typertGateway');
      return { ok: true, pong: true, gateway: gateway !== undefined, sessionId: workspaceId() };
    }

    const text = String((request && request.text) || '');
    if (text.trim() === '') return { ok: false, error: 'text is required' };

    let sessionId = String((request && request.sessionId) || '');
    if (request && request.new === true) sessionId = await createSession();
    if (sessionId === '') return { ok: false, error: 'sessionId is required (or new: true)' };

    const result = await ask(sessionId, text);
    return { ...result, sessionId };
  };

  const server = net.createServer((socket) => {
    socket.setEncoding('utf8');
    let buffer = '';
    let replied = false;
    const reply = (payload) => {
      if (replied) return;
      replied = true;
      try {
        socket.end(JSON.stringify(payload) + '\n');
      } catch (e) {
        /* ignore */
      }
    };

    socket.on('data', (chunk) => {
      buffer += chunk;
      const index = buffer.indexOf('\n');
      if (index < 0) return;
      const raw = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);

      queue = queue.then(async () => {
        let payload;
        try {
          payload = await handle(raw);
        } catch (error) {
          log('turn crashed: ' + brief(error));
          payload = { ok: false, error: brief(error) };
        }
        if (payload.ok === true) {
          log('turn answered chars=' + String(payload.answer.length) + ' session=' + String(payload.sessionId));
        } else {
          log('turn failed: ' + String(payload.error));
        }
        reply(payload);
      });
    });
    socket.on('error', () => {
      /* client vanished */
    });
  });

  server.on('error', (error) => log('server error ' + brief(error)));

  ctx.effect(() => {
    server.listen(port, '127.0.0.1', () => log('listening on ' + String(port)));
    return () => {
      try {
        server.close();
      } catch (e) {
        /* ignore */
      }
    };
  }, 'voice-turn loopback server');
}
