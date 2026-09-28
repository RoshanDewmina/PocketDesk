import { chmodSync, closeSync, constants, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import type { Supervisor } from './supervisor';
import type { ApprovalDecision } from './protocol';

export type ControlServerHandle = {
  socketPath: string;
  tokenPath: string;
  token: string;
  stop(): void;
};

function ensurePrivateDir(path: string) {
  if (existsSync(path)) {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('control directory must be a real directory, not a symlink');
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) throw new Error('control directory must be owned by the current user');
  } else {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  }
  chmodSync(path, 0o700);
}

function loadOrCreateToken(tokenPath: string): string {
  if (existsSync(tokenPath)) {
    const stat = lstatSync(tokenPath);
    if (stat.isSymbolicLink() || !stat.isFile()) throw new Error('control token must be a regular file, not a symlink');
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) throw new Error('control token must be owned by the current user');
    if ((stat.mode & 0o777) !== 0o600) throw new Error('existing control token must have mode 0600');
    const existing = readFileSync(tokenPath, 'utf8').trim();
    if (!/^[a-f0-9]{64}$/.test(existing)) throw new Error('existing control token is malformed');
    return existing;
  }
  const token = crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');
  const descriptor = openSync(tokenPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    writeFileSync(descriptor, token, { encoding: 'utf8' });
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  return token;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

function errorResponse(message: string, status: number): Response {
  return jsonResponse({ error: message }, status);
}

const decisions: ApprovalDecision[] = ['accept', 'acceptForSession', 'decline', 'cancel'];

/**
 * Local-only control surface: a Unix domain socket (mode 600) in a private
 * directory, plus a bearer token (also mode 600) as defense in depth. No
 * public routes are ever bound.
 */
export function startControlServer(controlDir: string, supervisor: Supervisor): ControlServerHandle {
  if (!isAbsolute(controlDir)) throw new Error('control dir must be absolute');
  ensurePrivateDir(controlDir);
  const socketPath = join(controlDir, 'control.sock');
  const tokenPath = join(controlDir, 'control.token');
  const token = loadOrCreateToken(tokenPath);
  ensurePrivateDir(dirname(socketPath));

  const server = Bun.serve({
    unix: socketPath,
    async fetch(req) {
      const auth = req.headers.get('authorization');
      if (auth !== `Bearer ${token}`) return errorResponse('unauthorized', 401);

      const url = new URL(req.url);
      try {
        if (req.method === 'GET' && url.pathname === '/status') {
          return jsonResponse(supervisor.status());
        }
        if (req.method === 'POST' && url.pathname === '/start') {
          const body = (await req.json()) as { workspace?: string; prompt?: string };
          if (typeof body.workspace !== 'string' || typeof body.prompt !== 'string') {
            return errorResponse('workspace and prompt are required strings', 400);
          }
          return jsonResponse(await supervisor.start(body.workspace, body.prompt));
        }
        if (req.method === 'POST' && url.pathname === '/takeover') {
          return jsonResponse(await supervisor.requestTakeover());
        }
        if (req.method === 'POST' && url.pathname === '/resume') {
          const body = (await req.json()) as { summaryInput?: string; screenContextRef?: string };
          if (typeof body.summaryInput !== 'string') return errorResponse('summaryInput is a required string', 400);
          return jsonResponse(await supervisor.resume(body.summaryInput, body.screenContextRef));
        }
        if (req.method === 'POST' && url.pathname === '/stop') {
          return jsonResponse(await supervisor.stop());
        }
        if (req.method === 'POST' && url.pathname.startsWith('/approvals/')) {
          const id = decodeURIComponent(url.pathname.slice('/approvals/'.length));
          const body = (await req.json()) as { decision?: string };
          if (!body.decision || !decisions.includes(body.decision as ApprovalDecision)) {
            return errorResponse('decision must be one of accept, acceptForSession, decline, cancel', 400);
          }
          return jsonResponse(await supervisor.respondApproval(id, body.decision as ApprovalDecision));
        }
        return errorResponse('not found', 404);
      } catch (error) {
        return errorResponse(error instanceof Error ? error.message : 'internal error', 400);
      }
    },
  });
  chmodSync(socketPath, 0o600);
  const socketStat = lstatSync(socketPath);
  if (!socketStat.isSocket()) {
    server.stop(true);
    throw new Error('control socket path is not a Unix socket');
  }
  if (typeof process.getuid === 'function' && socketStat.uid !== process.getuid()) {
    server.stop(true);
    throw new Error('control socket must be owned by the current user');
  }

  return {
    socketPath,
    tokenPath,
    token,
    stop() {
      server.stop(true);
    },
  };
}
