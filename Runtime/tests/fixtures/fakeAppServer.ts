/**
 * Scriptable fake `codex app-server`. Reads a scenario JSON file (path in
 * argv[2]) and speaks the same newline-delimited JSON-RPC framing as the
 * real binary. Used only from tests so Runtime code never has to guess at
 * unverified protocol behavior (see codex-app-server.md's "unresolved"
 * section) beyond what a scenario explicitly scripts.
 *
 * Scenario shape:
 * {
 *   "threadId": "uuid",
 *   "handlers": {
 *     "<method>": {
 *       "resultSequence": [any, ...],   // cycles, last value sticks
 *       "notifications": [{ "method": "...", "params": {...}, "delayMs": 0 }]
 *     }
 *   },
 *   "serverRequests": [
 *     {
 *       "afterMethod": "turn/interrupt",
 *       "delayMs": 10,
 *       "id": 9001,
 *       "method": "item/commandExecution/requestApproval",
 *       "params": {...},
 *       "onResponse": { "notifications": [...] }
 *     }
 *   ]
 * }
 */

type Notification = { method: string; params?: unknown; delayMs?: number };
type Handler = { resultSequence?: unknown[]; error?: { code: number; message: string }; notifications?: Notification[]; delayMs?: number };
type ServerRequestSpec = {
  afterMethod: string;
  delayMs?: number;
  id: number;
  method: string;
  params?: unknown;
  onResponse?: { notifications?: Notification[] };
  once?: boolean;
};
type ExitAfterMethod = { method: string; delayMs?: number; code?: number };
type Scenario = {
  handlers?: Record<string, Handler>;
  serverRequests?: ServerRequestSpec[];
  exitAfterMethod?: ExitAfterMethod;
  spawnChildProcessPidFile?: string;
  responseLogFile?: string;
  requestLogFile?: string;
};

const scenarioPath = process.argv[2];
if (!scenarioPath) {
  console.error('usage: fakeAppServer.ts <scenario.json>');
  process.exit(1);
}
const scenario: Scenario = JSON.parse(await Bun.file(scenarioPath).text());
const handlerCallCounts = new Map<string, number>();
const firedServerRequests = new Set<number>();
const outstandingResponseHandlers = new Map<number, ServerRequestSpec>();

function send(message: unknown) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function emitNotifications(notifications?: Notification[]) {
  if (!notifications) return;
  for (const notification of notifications) {
    if (notification.delayMs) await new Promise((resolve) => setTimeout(resolve, notification.delayMs));
    send({ method: notification.method, params: notification.params ?? {} });
  }
}

function maybeFireServerRequests(afterMethod: string) {
  for (const spec of scenario.serverRequests ?? []) {
    if (spec.afterMethod !== afterMethod) continue;
    if (spec.once !== false && firedServerRequests.has(spec.id)) continue;
    firedServerRequests.add(spec.id);
    outstandingResponseHandlers.set(spec.id, spec);
    setTimeout(() => {
      send({ id: spec.id, method: spec.method, params: spec.params ?? {} });
    }, spec.delayMs ?? 0);
  }
}

async function handleRequest(id: number | string, method: string, _params: unknown) {
  if (scenario.requestLogFile) {
    await Bun.write(scenario.requestLogFile, `${await safeExistingText(scenario.requestLogFile)}${JSON.stringify({ method, params: _params })}\n`);
  }
  if (method === 'initialize') {
    send({ id, result: { userAgent: 'fake-codex/0.0.0', codexHome: '/tmp/fake-codex-home', platformFamily: 'unix', platformOs: 'macos' } });
    return;
  }
  if (method === 'thread/start' && scenario.spawnChildProcessPidFile) {
    const child = Bun.spawn(['sleep', '60'], { stdio: ['ignore', 'ignore', 'ignore'] });
    await Bun.write(scenario.spawnChildProcessPidFile, String(child.pid));
  }
  const handler = scenario.handlers?.[method];
  if (!handler) {
    send({ id, error: { code: -32601, message: `fake app-server has no handler for ${method}` } });
    return;
  }
  if (handler.error) {
    if (handler.delayMs) await new Promise((resolve) => setTimeout(resolve, handler.delayMs));
    send({ id, error: handler.error });
    maybeFireServerRequests(method);
    return;
  }
  const count = handlerCallCounts.get(method) ?? 0;
  handlerCallCounts.set(method, count + 1);
  const sequence = handler.resultSequence ?? [{}];
  const result = sequence[Math.min(count, sequence.length - 1)];
  if (handler.delayMs) await new Promise((resolve) => setTimeout(resolve, handler.delayMs));
  send({ id, result });
  await emitNotifications(handler.notifications);
  maybeFireServerRequests(method);
  if (scenario.exitAfterMethod?.method === method) {
    const { delayMs, code } = scenario.exitAfterMethod;
    setTimeout(() => process.exit(code ?? 1), delayMs ?? 0);
  }
}

async function safeExistingText(path: string): Promise<string> {
  try {
    return await Bun.file(path).text();
  } catch {
    return '';
  }
}

const decoder = new TextDecoder();
let buffer = '';

for await (const chunk of Bun.stdin.stream()) {
  buffer += decoder.decode(chunk, { stream: true });
  let newlineIndex: number;
  while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newlineIndex).trim();
    buffer = buffer.slice(newlineIndex + 1);
    if (!line) continue;
    let message: { id?: number | string; method?: string; params?: unknown; result?: unknown; error?: unknown };
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message.method === 'initialized') continue;
    if (message.method && message.id !== undefined) {
      void handleRequest(message.id, message.method, message.params);
      continue;
    }
    if (message.id !== undefined && (message.result !== undefined || message.error !== undefined)) {
      if (scenario.responseLogFile) {
        const existing = await safeExistingText(scenario.responseLogFile);
        await Bun.write(scenario.responseLogFile, `${existing}${JSON.stringify(message)}\n`);
      }
      const spec = outstandingResponseHandlers.get(Number(message.id));
      if (spec) {
        outstandingResponseHandlers.delete(Number(message.id));
        void emitNotifications(spec.onResponse?.notifications);
      }
    }
  }
}
