import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { realpathSync, statSync } from 'node:fs';
import { resolve, sep } from 'node:path';
import type { ServerWebSocket } from 'bun';
import { createMcpApp, type McpApp } from '../mcp/app';
import type { IceServer, TurnCredentialProvider } from '../turn';
import {
  createBrowserMcpHostBridge,
  type BrowserMcpHostBridge,
  type HostRpcReply,
} from './mcp-host-bridge';
import { createBrowserRelay } from './relay';

const MAX_RECORD_BYTES = 256 * 1024;
const MAX_PENDING_HOST_SIGNAL_BYTES = 512 * 1024;
const MAX_HTTP_BODY_BYTES = 64 * 1024;
const MAX_STATIC_BYTES = 4 * 1024 * 1024;
const MAX_DIAGNOSTICS_BYTES = 512 * 1024;
const MAX_TICKET_TTL_MS = 15_000;
const MAX_ENROLLMENT_TIMEOUT_MS = 120_000;
const HEX_32 = /^[a-f0-9]{64}$/;
const ERROR_CODE = /^[a-z0-9_]{1,64}$/;
const MCP_INTENT_COOKIE = '__Host-pocketdesk_intent';

type RouteKind = 'host' | 'browser';

type PeerData = {
  route: RouteKind;
  authenticated: boolean;
  registrationPending?: boolean;
  hostID?: string;
  session?: string;
  intentID?: string;
  timer?: Timer;
  messages: number;
  messageWindow: number;
  iceServers?: IceServer[];
  iceRevoked?: boolean;
};

type Peer = ServerWebSocket<PeerData>;

type Ticket = {
  digest: string;
  hostID: string;
  host: Peer;
  session: string;
  peerID: string;
  expires: number;
  timer: Timer;
};

type BrowserSession = {
  hostID: string;
  host: Peer;
  browser: Peer;
  session: string;
  scope: 'view' | 'control';
  browserIceDelivered: boolean;
  pendingHostSignals: Record<string, unknown>[];
  pendingHostSignalBytes: number;
};

type PendingRequest = {
  host: Peer;
  timer: Timer;
  finish: (reply: HostRpcReply) => void;
  signal: AbortSignal;
  abort: () => void;
};

export type BrowserServiceConfig = {
  port?: number;
  hostname?: string;
  origin?: string;
  mcpPrivateDir?: string;
  staticRoot?: string;
  authTimeoutMs?: number;
  ticketTTLms?: number;
  enrollmentTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxPeers?: number;
  maxPendingRequests?: number;
  messagesPerSecond?: number;
  diagnosticsDir?: string;
  devRoutes?: boolean;
  turnProvider?: TurnCredentialProvider;
  stunURLs?: string[];
  relayTimeoutMs?: number;
  relayIssuesPerMinute?: number;
  testForceRelay?: boolean;
};

const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const isHex32 = (value: unknown): value is string => typeof value === 'string' && HEX_32.test(value);
const exactKeys = (value: Record<string, unknown>, keys: string[]) => {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
};
const equalHex = (a: string, b: string) =>
  a.length === b.length && timingSafeEqual(Buffer.from(a, 'ascii'), Buffer.from(b, 'ascii'));

function canonicalBase64(value: unknown, minimumBytes: number, maximumBytes = minimumBytes, firstByte?: number): value is string {
  if (typeof value !== 'string' || value.length > Math.ceil(maximumBytes / 3) * 4 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  let decoded: Buffer;
  try { decoded = Buffer.from(value, 'base64'); } catch { return false; }
  return decoded.length >= minimumBytes && decoded.length <= maximumBytes && decoded.toString('base64') === value &&
    (firstByte === undefined || decoded[0] === firstByte);
}

function canonicalTime(value: unknown): number | undefined {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,15})$/.test(value)) return;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) return;
  return parsed;
}

function validOperationBody(operation: string, body: unknown): body is Record<string, unknown> {
  if (!isObject(body)) return false;
  if (operation === 'enroll') {
    return exactKeys(body, ['nonce', 'payload']) && canonicalBase64(body.nonce, 12) &&
      canonicalBase64(body.payload, 16, 1024);
  }
  if (operation === 'challenge') {
    return exactKeys(body, ['peerID', 'nonce', 'mode']) && isHex32(body.peerID) && isHex32(body.nonce) &&
      (body.mode === 'view' || body.mode === 'interactive');
  }
  if (operation === 'proof') {
    return exactKeys(body, ['session', 'publicKey', 'signature']) && isHex32(body.session) &&
      canonicalBase64(body.publicKey, 65, 65, 4) && canonicalBase64(body.signature, 64);
  }
  return false;
}

function checkedOrigin(value: string | undefined) {
  if (value === undefined) return;
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash ||
      value !== url.origin) {
    throw new Error('origin must be an exact HTTPS origin');
  }
  return url.origin;
}

function integerOption(name: string, value: number, minimum: number, maximum: number) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
}

const VIEWER_QUERY_KEYS = new Set(['diag', 'marker', 'bench', 'tile', 'intent']);

function validViewerQuery(url: URL): boolean {
  if (!url.search) return true;
  const seen = new Set<string>();
  for (const key of url.searchParams.keys()) {
    if (!VIEWER_QUERY_KEYS.has(key) || seen.has(key)) return false;
    seen.add(key);
  }
  const diag = url.searchParams.get('diag');
  if (diag !== null && diag !== '1') return false;
  const marker = url.searchParams.get('marker');
  if (marker !== null && marker !== 'full' && marker !== 'crop') return false;
  const bench = url.searchParams.get('bench');
  if (bench !== null) {
    if (!/^[1-9][0-9]{0,3}$/.test(bench) || Number(bench) > 1000) return false;
  }
  const tile = url.searchParams.get('tile');
  if (tile !== null) {
    const parts = tile.split(',');
    if (parts.length !== 4 || !parts.every(part => /^(0|[1-9][0-9]{0,5})$/.test(part))) return false;
  }
  const intent = url.searchParams.get('intent');
  if (intent !== null && !isHex32(intent)) return false;
  return true;
}

function intentCookie(request: Request): string | undefined {
  const cookie = request.headers.get('cookie');
  if (!cookie || cookie.length > 4096) return;
  const matches = cookie.split(';').map(value => value.trim()).filter(value => value.startsWith(`${MCP_INTENT_COOKIE}=`));
  if (matches.length !== 1) return;
  const value = matches[0].slice(MCP_INTENT_COOKIE.length + 1);
  return isHex32(value) ? value : undefined;
}

export class BodyTooLarge extends Error {}

export async function readBodyCapped(request: Request, cap: number): Promise<Uint8Array> {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value || value.byteLength === 0) continue;
    total += value.byteLength;
    if (total > cap) {
      try { await reader.cancel(); } catch { /* best effort: the connection may already be gone */ }
      throw new BodyTooLarge();
    }
    chunks.push(value);
  }
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { combined.set(chunk, offset); offset += chunk.byteLength; }
  return combined;
}

const RAW_IPV4 = /\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/;

// A conservative IPv6-literal heuristic: colon-and-hex runs are only flagged when they carry real
// IPv6 shape (a "::" compression, a hex letter, or enough groups) so plain HH:MM:SS timestamps
// embedded in a report (e.g. inside an ISO date) are never mistaken for an address.
function containsRawIPv6(text: string): boolean {
  const candidates = text.match(/\b[0-9a-fA-F:]{2,}\b/g) ?? [];
  return candidates.some(candidate => {
    const colons = (candidate.match(/:/g) ?? []).length;
    if (colons < 2) return false;
    if (candidate.includes('::')) return true;
    if (colons >= 5) return true;
    return /[a-fA-F]/.test(candidate);
  });
}

export function createBrowserService(config: BrowserServiceConfig = {}) {
  const hostname = config.hostname ?? '127.0.0.1';
  const configuredOrigin = checkedOrigin(config.origin);
  const mcpPrivateDir = config.mcpPrivateDir ? resolve(config.mcpPrivateDir) : undefined;
  if (mcpPrivateDir && !configuredOrigin) throw new Error('MCP requires an exact HTTPS origin with mcpPrivateDir');
  const authTimeoutMs = integerOption('authTimeoutMs', config.authTimeoutMs ?? 5_000, 10, 30_000);
  const ticketTTLms = integerOption('ticketTTLms', config.ticketTTLms ?? MAX_TICKET_TTL_MS, 1, MAX_TICKET_TTL_MS);
  const enrollmentTimeoutMs = integerOption(
    'enrollmentTimeoutMs', config.enrollmentTimeoutMs ?? MAX_ENROLLMENT_TIMEOUT_MS, 10, MAX_ENROLLMENT_TIMEOUT_MS,
  );
  const requestTimeoutMs = integerOption('requestTimeoutMs', config.requestTimeoutMs ?? 5_000, 10, 30_000);
  const maxPeers = integerOption('maxPeers', config.maxPeers ?? 64, 1, 256);
  const maxPendingRequests = integerOption('maxPendingRequests', config.maxPendingRequests ?? 64, 1, 256);
  const messagesPerSecond = integerOption('messagesPerSecond', config.messagesPerSecond ?? 100, 1, 1_000);
  const staticRoot = resolve(config.staticRoot ?? resolve(import.meta.dir, '../../..'));
  const diagnosticsDir = config.diagnosticsDir ? resolve(config.diagnosticsDir) : undefined;
  const devRoutes = config.devRoutes ?? true;
  const relay = createBrowserRelay({
    provider: config.turnProvider,
    stunURLs: config.stunURLs,
    timeoutMs: config.relayTimeoutMs,
    issuesPerMinute: config.relayIssuesPerMinute,
    testForceRelay: config.testForceRelay,
  });

  const hosts = new Map<string, Peer>();
  const peers = new Set<Peer>();
  const tickets = new Map<string, Ticket>();
  const sessions = new Map<string, BrowserSession>();
  const requests = new Map<string, PendingRequest>();
  const sessionScopes = new Map<string, 'view' | 'control'>();
  const pendingRegistrations = new Set<Promise<void>>();
  let stopped = false;
  let mcpBridge: BrowserMcpHostBridge | undefined;
  let mcpApp: McpApp | undefined;

  const expectedHost = (port: number) => configuredOrigin ? new URL(configuredOrigin).host :
    `${hostname.includes(':') && !hostname.startsWith('[') ? `[${hostname}]` : hostname}:${port}`;
  const expectedOrigin = (port: number) => configuredOrigin ?? `http://${expectedHost(port)}`;

  const securityHeaders = (port: number) => {
    const origin = expectedOrigin(port);
    const signalOrigin = origin.replace(/^http:/, 'ws:').replace(/^https:/, 'wss:');
    return {
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
      'Content-Security-Policy': `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self' ${signalOrigin}; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
    };
  };

  const send = (ws: Peer, value: unknown) => {
    if (ws.readyState !== WebSocket.OPEN) return false;
    const payload = JSON.stringify(value);
    if (Buffer.byteLength(payload) > MAX_RECORD_BYTES || ws.send(payload) === -1) {
      ws.close(1013, 'busy');
      return false;
    }
    return true;
  };

  const fail = (ws: Peer, code: string, close = true) => {
    send(ws, { type: 'error', code });
    if (close) ws.close(1008, code);
  };

  const finishRequest = (id: string, reply: HostRpcReply) => {
    const pending = requests.get(id);
    if (!pending) return false;
    clearTimeout(pending.timer);
    requests.delete(id);
    pending.signal.removeEventListener('abort', pending.abort);
    pending.finish(reply);
    return true;
  };

  const cancelRequest = (id: string, reply: HostRpcReply) => {
    const pending = requests.get(id);
    if (!pending) return;
    send(pending.host, { type: 'cancel', id });
    finishRequest(id, reply);
  };

  const cancelHostRequests = (host: Peer, code = 'host_unavailable') => {
    for (const [id, pending] of requests) {
      if (pending.host === host) finishRequest(id, { kind: 'offline', code });
    }
  };

  const requestHost = (
    hostID: string,
    operation: string,
    body: Record<string, unknown>,
    signal: AbortSignal,
    timeoutMs: number,
  ): Promise<HostRpcReply> => {
    const host = hosts.get(hostID);
    if (stopped || !host || host.readyState !== WebSocket.OPEN) return Promise.resolve({ kind: 'offline' });
    if (requests.size >= maxPendingRequests) return Promise.resolve({ kind: 'error', code: 'busy' });
    const id = randomBytes(32).toString('hex');
    return new Promise(finish => {
      const timer = setTimeout(() => cancelRequest(id, { kind: 'timeout' }), timeoutMs);
      const abort = () => cancelRequest(id, { kind: 'aborted' });
      requests.set(id, { host, timer, finish, signal, abort });
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) abort();
      if (requests.has(id) && !send(host, { type: 'request', id, operation, body })) {
        finishRequest(id, { kind: 'offline' });
      }
    });
  };

  const removeTicket = (key: string) => {
    const ticket = tickets.get(key);
    if (!ticket) return;
    clearTimeout(ticket.timer);
    tickets.delete(key);
  };

  const clearHostTickets = (host: Peer) => {
    for (const [key, ticket] of tickets) if (ticket.host === host) removeTicket(key);
  };

  const revokePeer = (peer: Peer) => {
    if (peer.data.iceRevoked || !peer.data.iceServers) return;
    peer.data.iceRevoked = true;
    relay.revoke(peer.data.iceServers);
  };

  const endSession = (record: BrowserSession, initiator?: Peer, reason = 'session_ended') => {
    if (sessions.get(record.session) !== record) return;
    sessions.delete(record.session);
    sessionScopes.delete(record.session);
    revokePeer(record.host);
    revokePeer(record.browser);
    if (initiator !== record.host) send(record.host, { type: 'end', session: record.session });
    if (initiator !== record.browser) send(record.browser, { type: 'end', session: record.session });
    if (record.browser.readyState === WebSocket.OPEN) record.browser.close(1000, reason);
  };

  const clearHostSessions = (host: Peer, reason: string) => {
    for (const record of [...sessions.values()]) if (record.host === host) endSession(record, host, reason);
  };

  const stopHostAuthority = (host: Peer, reason: string) => {
    clearHostTickets(host);
    clearHostSessions(host, reason);
    cancelHostRequests(host, reason);
  };

  const abortAdmission = (record: BrowserSession) => {
    const stillActive = sessions.get(record.session) === record;
    if (stillActive) sessions.delete(record.session);
    revokePeer(record.host);
    revokePeer(record.browser);
    if (stillActive) {
      send(record.host, { type: 'end', session: record.session });
      fail(record.browser, 'relay_unavailable');
    }
  };

  if (configuredOrigin && mcpPrivateDir) {
    mcpBridge = createBrowserMcpHostBridge({
      authorizationHostID() {
        const connected = [...hosts.entries()].filter(([, host]) => host.readyState === WebSocket.OPEN);
        return connected.length === 1 ? connected[0][0] : undefined;
      },
      hostConnected(hostID) {
        return hosts.get(hostID)?.readyState === WebSocket.OPEN;
      },
      request(hostID, operation, body, signal) {
        return requestHost(
          hostID,
          operation,
          body,
          signal,
          operation === 'mcp_authorize' ? enrollmentTimeoutMs : requestTimeoutMs,
        );
      },
      session(hostID, sessionID) {
        const record = sessions.get(sessionID);
        return record?.hostID === hostID && record.browserIceDelivered ? { scope: record.scope } : undefined;
      },
      stopSession(hostID, sessionID) {
        const record = sessions.get(sessionID);
        if (!record || record.hostID !== hostID) return false;
        endSession(record, undefined, 'mcp_stopped');
        return true;
      },
    });
    mcpApp = createMcpApp({ origin: configuredOrigin, privateDir: mcpPrivateDir, host: mcpBridge });
  }

  const validHostHeader = (request: Request, port: number) => request.headers.get('host') === expectedHost(port);
  const validBrowserOrigin = (request: Request, port: number) => request.headers.get('origin') === expectedOrigin(port);

  const staticTarget = (pathname: string): { root: string; relative: string } | undefined => {
    if (pathname === '/') return { root: resolve(staticRoot, 'BrowserClient'), relative: 'index.html' };
    if (pathname === '/app.js') return { root: resolve(staticRoot, 'BrowserClient'), relative: 'app.js' };
    if (pathname === '/style.css') return { root: resolve(staticRoot, 'BrowserClient'), relative: 'style.css' };
    if (!devRoutes && (pathname === '/probe/' || pathname === '/probe/probe.js' || pathname === '/probe/probe.css' ||
        pathname === '/fixtures/code-scene.js')) return;
    if (pathname === '/probe/') return { root: resolve(staticRoot, 'BrowserProbe'), relative: 'index.html' };
    if (pathname === '/probe/probe.js') return { root: resolve(staticRoot, 'BrowserProbe'), relative: 'probe.js' };
    if (pathname === '/probe/probe.css') return { root: resolve(staticRoot, 'BrowserProbe'), relative: 'probe.css' };
    if (pathname === '/fixtures/code-scene.js') return { root: resolve(staticRoot, 'BrowserFixtures'), relative: 'code-scene.js' };
    if (!pathname.startsWith('/src/')) return;
    let relative: string;
    try { relative = decodeURIComponent(pathname.slice('/src/'.length)); } catch { return; }
    const segments = relative.split('/');
    if (!relative || relative.includes('\\') || relative.includes('\0') ||
        segments.some(segment => !segment || segment === '.' || segment === '..' || segment.startsWith('.'))) return;
    return { root: resolve(staticRoot, 'BrowserClient', 'src'), relative };
  };

  const serveStatic = (pathname: string, method: string, port: number) => {
    const target = staticTarget(pathname);
    if (!target) return new Response('Not found', { status: 404, headers: securityHeaders(port) });
    try {
      const base = realpathSync(staticRoot);
      const root = realpathSync(target.root);
      if (root !== base && !root.startsWith(base + sep)) throw new Error('outside static root');
      const file = realpathSync(resolve(root, target.relative));
      if (file !== root && !file.startsWith(root + sep)) throw new Error('outside root');
      const info = statSync(file);
      if (!info.isFile() || info.size > MAX_STATIC_BYTES) throw new Error('not a bounded file');
      const extension = file.slice(file.lastIndexOf('.'));
      const type = extension === '.html' ? 'text/html; charset=utf-8' : extension === '.css' ? 'text/css; charset=utf-8' :
        extension === '.js' ? 'text/javascript; charset=utf-8' : 'application/octet-stream';
      const headers = { ...securityHeaders(port), 'Content-Type': type, 'Content-Length': String(info.size) };
      return new Response(method === 'HEAD' ? null : Bun.file(file), { status: 200, headers });
    } catch {
      return new Response('Not found', { status: 404, headers: securityHeaders(port) });
    }
  };

  const handleAPI = async (request: Request, port: number, hostID: string, operation: string) => {
    const headers = securityHeaders(port);
    if (!validBrowserOrigin(request, port)) return Response.json({ error: 'origin_rejected' }, { status: 403, headers });
    if (request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
      return Response.json({ error: 'invalid_content_type' }, { status: 415, headers });
    }
    const declaredLength = Number(request.headers.get('content-length') ?? '0');
    if (!Number.isSafeInteger(declaredLength) || declaredLength < 0 || declaredLength > MAX_HTTP_BODY_BYTES) {
      return Response.json({ error: 'invalid_request' }, { status: 413, headers });
    }
    let bytes: Uint8Array;
    try { bytes = new Uint8Array(await request.arrayBuffer()); } catch {
      return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    }
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_HTTP_BODY_BYTES) {
      return Response.json({ error: 'invalid_request' }, { status: bytes.byteLength ? 413 : 400, headers });
    }
    let body: unknown;
    try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch {
      return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    }
    if (!validOperationBody(operation, body)) return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    const reply = await requestHost(
      hostID,
      operation,
      body,
      request.signal,
      operation === 'enroll' ? enrollmentTimeoutMs : requestTimeoutMs,
    );
    if (reply.kind === 'response') {
      if (operation === 'challenge' && isObject(reply.body) && exactKeys(reply.body, ['fields', 'signature']) &&
          Array.isArray(reply.body.fields) && reply.body.fields.length === 12 && reply.body.fields[0] === 'challenge' &&
          reply.body.fields[1] === hostID && reply.body.fields[4] === body.mode && isHex32(reply.body.fields[7])) {
        sessionScopes.set(reply.body.fields[7], body.mode === 'interactive' ? 'control' : 'view');
      }
      return Response.json(reply.body, { headers });
    }
    if (reply.kind === 'error') {
      const status = reply.code === 'busy' ? 503 : 400;
      return Response.json({ error: reply.code }, { status, headers });
    }
    if (reply.kind === 'timeout') return Response.json({ error: 'request_timeout' }, { status: 504, headers });
    if (reply.kind === 'aborted') return Response.json({ error: reply.code ?? 'request_cancelled' }, { status: 499, headers });
    return Response.json({ error: reply.code ?? 'host_unavailable' }, { status: 503, headers });
  };

  const handleDiagnostics = async (request: Request, port: number) => {
    const headers = securityHeaders(port);
    if (!devRoutes || !diagnosticsDir) return new Response('Not found', { status: 404, headers });
    if (!validBrowserOrigin(request, port)) return Response.json({ error: 'origin_rejected' }, { status: 403, headers });
    if (request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
      return Response.json({ error: 'invalid_content_type' }, { status: 415, headers });
    }
    // The cap is enforced while streaming the body, not from a (possibly missing or lying)
    // Content-Length header: a client can under- or over-declare that header freely.
    let bytes: Uint8Array;
    try { bytes = await readBodyCapped(request, MAX_DIAGNOSTICS_BYTES); } catch (error) {
      if (error instanceof BodyTooLarge) return Response.json({ error: 'invalid_request' }, { status: 413, headers });
      return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    }
    if (bytes.byteLength === 0) return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    let text: string;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch {
      return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    }
    let body: unknown;
    try { body = JSON.parse(text); } catch {
      return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    }
    if (!isObject(body)) return Response.json({ error: 'invalid_request' }, { status: 400, headers });
    // Diagnostics must never carry a raw address; the client only ever reports an address class.
    if (RAW_IPV4.test(text) || containsRawIPv6(text)) return Response.json({ error: 'raw_address_rejected' }, { status: 400, headers });
    try {
      await mkdir(diagnosticsDir, { recursive: true });
      const name = `diag-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomBytes(4).toString('hex')}.json`;
      await Bun.write(resolve(diagnosticsDir, name), text);
    } catch {
      return Response.json({ error: 'write_failed' }, { status: 500, headers });
    }
    return new Response(null, { status: 204, headers });
  };

  const installTicket = (ws: Peer, message: Record<string, unknown>) => {
    if (!exactKeys(message, ['type', 'ticket', 'session', 'expires', 'peerID']) || !isHex32(message.ticket) ||
        !isHex32(message.session) || !isHex32(message.peerID)) {
      fail(ws, 'invalid_ticket', false);
      return;
    }
    const expires = canonicalTime(message.expires);
    const now = Date.now();
    if (expires === undefined || expires <= now || expires > now + ticketTTLms) {
      fail(ws, 'invalid_ticket', false);
      return;
    }
    for (const [key, ticket] of tickets) if (ticket.expires <= now) removeTicket(key);
    if ([...tickets.values()].some(ticket => ticket.host === ws) ||
        [...sessions.values()].some(record => record.host === ws) || sessions.has(message.session)) {
      fail(ws, 'busy', false);
      return;
    }
    const key = digest(message.ticket);
    if (tickets.has(key)) { fail(ws, 'invalid_ticket', false); return; }
    const ticket: Ticket = {
      digest: key,
      hostID: ws.data.hostID!,
      host: ws,
      session: message.session,
      peerID: message.peerID,
      expires,
      timer: setTimeout(() => removeTicket(key), expires - now),
    };
    tickets.set(key, ticket);
  };

  const handleHostMessage = (ws: Peer, message: Record<string, unknown>) => {
    if (message.type === 'ticket') { installTicket(ws, message); return; }
    if (message.type === 'response') {
      const responseShape = exactKeys(message, ['type', 'id', 'body']) || exactKeys(message, ['type', 'id', 'error']);
      const hasError = Object.hasOwn(message, 'error');
      if (!responseShape || typeof message.id !== 'string' || !isHex32(message.id) ||
          (hasError && (typeof message.error !== 'string' || !ERROR_CODE.test(message.error)))) {
        fail(ws, 'invalid_message'); return;
      }
      const pending = requests.get(message.id);
      if (!pending) return;
      if (pending.host !== ws) { fail(ws, 'invalid_message'); return; }
      if (hasError) {
        finishRequest(message.id, { kind: 'error', code: message.error as string });
      } else {
        finishRequest(message.id, { kind: 'response', body: message.body });
      }
      return;
    }
    if (message.type === 'stop') {
      if (!exactKeys(message, ['type'])) { fail(ws, 'invalid_message'); return; }
      stopHostAuthority(ws, 'host_stopped');
      return;
    }
    if (message.type === 'end') {
      if (!exactKeys(message, ['type', 'session']) || !isHex32(message.session)) { fail(ws, 'invalid_message'); return; }
      const record = sessions.get(message.session);
      if (!record || record.host !== ws) { fail(ws, 'invalid_session', false); return; }
      endSession(record, ws);
      return;
    }
    if (message.type === 'signal') {
      if (!exactKeys(message, ['type', 'session', 'envelope']) || !isHex32(message.session) || !isObject(message.envelope)) {
        fail(ws, 'invalid_message'); return;
      }
      const record = sessions.get(message.session);
      if (!record || record.host !== ws) { fail(ws, 'invalid_session', false); return; }
      if (!record.browserIceDelivered) {
        const bytes = Buffer.byteLength(JSON.stringify(message));
        if (record.pendingHostSignals.length >= 32 || record.pendingHostSignalBytes + bytes > MAX_PENDING_HOST_SIGNAL_BYTES) {
          fail(ws, 'ice_not_ready', false);
          abortAdmission(record);
          return;
        }
        record.pendingHostSignals.push(message);
        record.pendingHostSignalBytes += bytes;
        return;
      }
      send(record.browser, message);
      return;
    }
    fail(ws, 'invalid_message');
  };

  const registerHost = (ws: Peer, message: Record<string, unknown>) => {
    if (!exactKeys(message, ['type', 'hostID', 'token']) || message.type !== 'host' ||
        !isHex32(message.hostID) || !isHex32(message.token) || !equalHex(digest(message.token), message.hostID)) {
      fail(ws, 'unauthorized'); return;
    }
    if (hosts.has(message.hostID)) { fail(ws, 'already_connected'); return; }
    clearTimeout(ws.data.timer);
    ws.data.authenticated = true;
    ws.data.hostID = message.hostID;
    hosts.set(message.hostID, ws);
    send(ws, { type: 'registered', hostID: message.hostID });
  };

  const registerBrowser = async (ws: Peer, message: Record<string, unknown>) => {
    if (ws.data.registrationPending) { fail(ws, 'registration_pending'); return; }
    if (!exactKeys(message, ['type', 'hostID', 'session', 'ticket']) || message.type !== 'browser' ||
        !isHex32(message.hostID) || !isHex32(message.session) || !isHex32(message.ticket)) {
      fail(ws, 'invalid_registration'); return;
    }
    const key = digest(message.ticket);
    const ticket = tickets.get(key);
    if (!ticket || !equalHex(ticket.digest, key)) { fail(ws, 'unauthorized'); return; }

    // A recognized ticket is one-use even when the caller supplies the wrong
    // host/session. Consume before checking the remaining bindings.
    removeTicket(key);
    const now = Date.now();
    if (ticket.expires <= now) { fail(ws, 'ticket_expired'); return; }
    if (ticket.hostID !== message.hostID || ticket.session !== message.session ||
        hosts.get(ticket.hostID) !== ticket.host || ticket.host.readyState !== WebSocket.OPEN || sessions.has(ticket.session)) {
      fail(ws, 'unauthorized'); return;
    }

    const record: BrowserSession = {
      hostID: ticket.hostID,
      host: ticket.host,
      browser: ws,
      session: ticket.session,
      scope: sessionScopes.get(ticket.session) ?? 'view',
      browserIceDelivered: false,
      pendingHostSignals: [],
      pendingHostSignalBytes: 0,
    };
    sessions.set(record.session, record);
    ws.data.registrationPending = true;
    ws.data.hostID = record.hostID;
    ws.data.session = record.session;
    clearTimeout(ws.data.timer);

    let hostRelay;
    try {
      hostRelay = await relay.issue(record.session, 'host');
    } catch {
      ws.data.registrationPending = false;
      abortAdmission(record);
      return;
    }
    if (sessions.get(record.session) !== record) {
      // Session already ended (host/browser closed, stop, or shutdown) while this issuance
      // was in flight: these credentials never armed teardown bookkeeping, so revoke now.
      relay.revoke(hostRelay.servers);
      return;
    }
    record.host.data.iceServers = hostRelay.servers;
    record.host.data.iceRevoked = false;
    if (!send(record.host, { type: 'ice', session: record.session, servers: hostRelay.servers, policy: hostRelay.policy }) ||
        !send(record.host, { type: 'joined', session: record.session })) {
      ws.data.registrationPending = false;
      abortAdmission(record);
      return;
    }

    let browserRelay;
    try {
      browserRelay = await relay.issue(record.session, 'browser');
    } catch {
      ws.data.registrationPending = false;
      abortAdmission(record);
      return;
    }
    if (sessions.get(record.session) !== record) {
      relay.revoke(browserRelay.servers);
      return;
    }
    ws.data.iceServers = browserRelay.servers;
    ws.data.iceRevoked = false;
    ws.data.authenticated = true;
    ws.data.registrationPending = false;
    if (!send(ws, { type: 'registered', session: record.session }) ||
        !send(ws, { type: 'ice', servers: browserRelay.servers, policy: browserRelay.policy })) {
      abortAdmission(record);
      return;
    }
    record.browserIceDelivered = true;
    for (const signal of record.pendingHostSignals.splice(0)) {
      if (!send(ws, signal)) {
        abortAdmission(record);
        return;
      }
    }
    record.pendingHostSignalBytes = 0;
    if (ws.data.intentID) {
      mcpBridge?.associateSession({
        intentID: ws.data.intentID,
        hostID: record.hostID,
        sessionID: record.session,
        scope: record.scope,
      });
    }
  };

  const handleBrowserMessage = (ws: Peer, message: Record<string, unknown>) => {
    const session = ws.data.session;
    const record = session ? sessions.get(session) : undefined;
    if (!record || record.browser !== ws) { fail(ws, 'invalid_session'); return; }
    if (message.type === 'end') {
      if (!exactKeys(message, ['type', 'session']) || message.session !== session) { fail(ws, 'invalid_message'); return; }
      endSession(record, ws);
      return;
    }
    if (message.type === 'signal') {
      if (!exactKeys(message, ['type', 'session', 'envelope']) || message.session !== session || !isObject(message.envelope)) {
        fail(ws, 'invalid_message'); return;
      }
      send(record.host, message);
      return;
    }
    fail(ws, 'invalid_message');
  };

  const server = Bun.serve<PeerData>({
    hostname,
    port: config.port ?? 0,
    async fetch(request, bunServer) {
      const port = bunServer.port;
      if (!validHostHeader(request, port)) return new Response('Misdirected request', { status: 421, headers: securityHeaders(port) });
      const url = new URL(request.url);
      const isViewerDocument = url.pathname === '/' && (request.method === 'GET' || request.method === 'HEAD');

      if (url.pathname === '/browser-host' || url.pathname === '/browser-signal') {
        if (url.search) return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        if (request.method !== 'GET') return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        const route: RouteKind = url.pathname === '/browser-host' ? 'host' : 'browser';
        if (route === 'host' ? request.headers.has('origin') : !validBrowserOrigin(request, port)) {
          return new Response('Origin rejected', { status: 403, headers: securityHeaders(port) });
        }
        if (peers.size >= maxPeers) return new Response('Busy', { status: 503, headers: securityHeaders(port) });
        const now = Date.now();
        const intentID = route === 'browser' ? intentCookie(request) : undefined;
        if (bunServer.upgrade(request, {
          data: { route, authenticated: false, messages: 0, messageWindow: now, ...(intentID ? { intentID } : {}) },
        })) return;
        return new Response('Upgrade required', { status: 426, headers: securityHeaders(port) });
      }

      const api = /^\/browser-api\/([a-f0-9]{64})\/(enroll|challenge|proof)$/.exec(url.pathname);
      if (api) {
        if (url.search) return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        if (request.method !== 'POST') return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        return handleAPI(request, port, api[1], api[2]);
      }

      if (url.pathname === '/api/diagnostics') {
        if (url.search) return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        if (!devRoutes || !diagnosticsDir || request.method !== 'POST') {
          return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        }
        return handleDiagnostics(request, port);
      }

      const mcpResponse = await mcpApp?.handle(request);
      if (mcpResponse) return mcpResponse;

      if ((request.method === 'GET' || request.method === 'HEAD') && staticTarget(url.pathname)) {
        if (url.search && !(isViewerDocument && validViewerQuery(url))) {
          return new Response('Not found', { status: 404, headers: securityHeaders(port) });
        }
        const response = serveStatic(url.pathname, request.method, port);
        const intentID = isViewerDocument ? url.searchParams.get('intent') : null;
        if (intentID && mcpBridge && response.status === 200 && await mcpBridge.lookupIntent(intentID)) {
          response.headers.set(
            'Set-Cookie',
            `${MCP_INTENT_COOKIE}=${intentID}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=600`,
          );
        }
        return response;
      }
      return new Response('Not found', { status: 404, headers: securityHeaders(port) });
    },
    websocket: {
      maxPayloadLength: MAX_RECORD_BYTES,
      perMessageDeflate: false,
      idleTimeout: 60,
      backpressureLimit: 512 * 1024,
      closeOnBackpressureLimit: true,
      sendPings: true,
      open(ws) {
        peers.add(ws);
        ws.data.timer = setTimeout(() => {
          if (!ws.data.authenticated) fail(ws, 'authentication_timeout');
        }, authTimeoutMs);
      },
      message(ws, raw) {
        if (typeof raw !== 'string' || Buffer.byteLength(raw) > MAX_RECORD_BYTES) { fail(ws, 'invalid_message'); return; }
        const now = Date.now();
        if (now - ws.data.messageWindow >= 1_000) { ws.data.messageWindow = now; ws.data.messages = 0; }
        ws.data.messages += 1;
        if (ws.data.messages > messagesPerSecond) { fail(ws, 'rate_limit'); return; }
        let message: Record<string, unknown>;
        try {
          const parsed = JSON.parse(raw);
          if (!isObject(parsed)) throw new Error('not an object');
          message = parsed;
        } catch { fail(ws, 'invalid_message'); return; }

        if (!ws.data.authenticated) {
          if (ws.data.route === 'host') { registerHost(ws, message); return; }
          const task = registerBrowser(ws, message);
          pendingRegistrations.add(task);
          void task.then(() => pendingRegistrations.delete(task), () => pendingRegistrations.delete(task));
          return;
        }
        if (ws.data.route === 'host') handleHostMessage(ws, message);
        else handleBrowserMessage(ws, message);
      },
      close(ws) {
        clearTimeout(ws.data.timer);
        peers.delete(ws);
        if (ws.data.route === 'host' && ws.data.hostID && hosts.get(ws.data.hostID) === ws) {
          hosts.delete(ws.data.hostID);
          stopHostAuthority(ws, 'host_disconnected');
        } else if (ws.data.route === 'browser' && ws.data.session) {
          const record = sessions.get(ws.data.session);
          if (record?.browser === ws) endSession(record, ws, 'browser_disconnected');
        }
      },
    },
  });

  return {
    port: server.port,
    async stop() {
      if (stopped) return;
      stopped = true;
      for (const pending of requests.values()) clearTimeout(pending.timer);
      for (const [id, pending] of [...requests]) {
        requests.delete(id);
        pending.signal.removeEventListener('abort', pending.abort);
        pending.finish({ kind: 'offline', code: 'service_stopped' });
      }
      await mcpApp?.stop();
      mcpBridge?.stop();
      for (const key of [...tickets.keys()]) removeTicket(key);
      for (const record of [...sessions.values()]) endSession(record, undefined, 'service_stopped');
      hosts.clear();
      for (const peer of peers) {
        clearTimeout(peer.data.timer);
        revokePeer(peer);
        if (peer.readyState === WebSocket.OPEN) peer.close(1001, 'service_stopped');
      }
      peers.clear();
      server.stop(true);
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline) {
        const active = [...pendingRegistrations];
        if (active.length === 0) break;
        const remaining = deadline - Date.now();
        await Promise.race([Promise.allSettled(active), new Promise(resolve => setTimeout(resolve, remaining))]);
      }
      await relay.drain(Math.max(0, deadline - Date.now()));
    },
  };
}
