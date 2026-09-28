import { createHash, timingSafeEqual } from 'node:crypto';
import type { ServerWebSocket } from 'bun';
import type { IceServer, PeerRole, TurnCredentialProvider } from './turn';
import type { RoomApproval } from './rooms';

type PeerData = {
  role?: PeerRole;
  room?: string;
  authenticated: boolean;
  registrationPending: boolean;
  timer?: Timer;
  messages: number;
  window: number;
  iceServers?: IceServer[];
  revocationStarted?: boolean;
};
type Peer = ServerWebSocket<PeerData>;
type Room = { host: Peer; client?: Peer; clientHash: string; expires: Timer };

export type ServiceConfig = {
  port?: number;
  hostname?: string;
  stunURLs?: string[];
  allowedRooms?: string[];
  roomApproval?: RoomApproval;
  turnProvider?: TurnCredentialProvider;
  relayTimeoutMs?: number;
  authTimeoutMs?: number;
  maxPeers?: number;
  connectionAttemptsPerMinute?: number;
  messagesPerSecond?: number;
  credentialIssuesPerMinute?: number;
  maxRoomLifetimeMs?: number;
  approvalAuditMs?: number;
  testForceRelay?: boolean;
};

const token = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
export const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const matches = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));

export function createService(config: ServiceConfig = {}) {
  const rooms = new Map<string, Room>();
  const peers = new Set<Peer>();
  const limits = new Map<string, { count: number; since: number }>();
  const authTimeoutMs = config.authTimeoutMs ?? 5000;
  const relayTimeoutMs = config.relayTimeoutMs ?? Math.max(1, Math.min(3000, authTimeoutMs - 1));
  const maxPeers = config.maxPeers ?? 256;
  const connectionAttemptsPerMinute = config.connectionAttemptsPerMinute ?? 30;
  const messagesPerSecond = config.messagesPerSecond ?? 100;
  const credentialIssuesPerMinute = config.credentialIssuesPerMinute ?? 12;
  const maxRoomLifetimeMs = config.maxRoomLifetimeMs ?? 30 * 60 * 1000;
  const approvalAuditMs = config.approvalAuditMs ?? 1000;
  if (!Number.isSafeInteger(approvalAuditMs) || approvalAuditMs < 100 || approvalAuditMs > 5000) {
    throw new Error('approval audit interval must be an integer from 100 to 5000 milliseconds');
  }
  if (config.testForceRelay && !config.turnProvider) throw new Error('testForceRelay requires a relay provider');
  const relayPolicy = config.testForceRelay ? { policy: 'relay' as const } : {};
  const startedAt = Date.now();
  const providerHealth = { lastOutcome: 'none' as 'none' | 'ok' | 'failed', consecutiveFailures: 0, rateLimited: 0 };
  const pendingIssuances = new Set<Promise<IceServer[]>>();
  const pendingRevocations = new Set<Promise<void>>();
  const pendingRegistrations = new Set<Promise<void>>();
  let credentialWindow = Date.now();
  let credentialIssues = 0;
  let stopping: Promise<void> | undefined;
  let approvalAudit: Timer | undefined;

  const scheduleRevocation = (servers: IceServer[]) => {
    if (!config.turnProvider?.revoke || servers.length === 0) return;
    const task = Promise.resolve().then(() => config.turnProvider!.revoke!(servers));
    pendingRevocations.add(task);
    void task.then(
      () => pendingRevocations.delete(task),
      () => pendingRevocations.delete(task),
    );
  };
  const revokePeer = (ws: Peer) => {
    if (ws.data.revocationStarted) return;
    ws.data.revocationStarted = true;
    if (ws.data.iceServers) scheduleRevocation(ws.data.iceServers);
  };

  const isRoomApproved = (room: string) => {
    if (!config.allowedRooms && !config.roomApproval) return true;
    return Boolean(config.allowedRooms?.includes(room) || config.roomApproval?.isApproved(room));
  };

  const terminateRoom = (roomID: string, room: Room, reason: string) => {
    if (rooms.get(roomID) !== room) return;
    clearTimeout(room.expires);
    rooms.delete(roomID);
    revokePeer(room.host);
    room.host.close(1008, reason);
    if (room.client) {
      revokePeer(room.client);
      room.client.close(1008, reason);
    }
  };

  const send = (ws: Peer, value: unknown) => {
    if (ws.send(JSON.stringify(value)) === -1) ws.close(1013, 'busy');
  };
  const error = (ws: Peer, code: string, close = true) => {
    send(ws, { type: 'error', code });
    if (close) ws.close(1008, code);
  };
  const issueIceServers = async (room: string, role: PeerRole): Promise<IceServer[]> => {
    const servers: IceServer[] = [];
    if (config.stunURLs?.length) servers.push({ urls: [...config.stunURLs] });
    if (config.turnProvider) {
      const now = Date.now();
      if (now - credentialWindow >= 60_000) { credentialWindow = now; credentialIssues = 0; }
      if (credentialIssues >= credentialIssuesPerMinute) {
        providerHealth.rateLimited += 1;
        throw new Error('relay issuance rate exceeded');
      }
      credentialIssues += 1;
      let timer: Timer | undefined;
      let timedOut = false;
      let issuedByProvider: IceServer[] | undefined;
      try {
        const issuance = config.turnProvider.issue({ room, role });
        pendingIssuances.add(issuance);
        void issuance.then(
          issued => { pendingIssuances.delete(issuance); if (timedOut) scheduleRevocation(issued); },
          () => pendingIssuances.delete(issuance),
        );
        const issued = await Promise.race([
          issuance,
          new Promise<never>((_resolve, reject) => {
            timer = setTimeout(() => { timedOut = true; reject(new Error('relay timeout')); }, relayTimeoutMs);
          }),
        ]);
        issuedByProvider = issued;
        providerHealth.lastOutcome = 'ok';
        providerHealth.consecutiveFailures = 0;
        servers.push(...issued);
      } catch (failure) {
        providerHealth.lastOutcome = 'failed';
        providerHealth.consecutiveFailures += 1;
        throw failure;
      } finally {
        clearTimeout(timer);
      }
      if (servers.length > 8 || servers.some(server => server.urls.length > 8)) {
        if (issuedByProvider) scheduleRevocation(issuedByProvider);
        throw new Error('relay configuration exceeds client limits');
      }
    }
    if (servers.length > 8 || servers.some(server => server.urls.length > 8)) {
      throw new Error('relay configuration exceeds client limits');
    }
    return servers;
  };

  const register = async (ws: Peer, msg: Record<string, unknown>) => {
    if (ws.data.registrationPending) { error(ws, 'registration_pending'); return; }
    if (msg.type !== 'register' || msg.version !== 1 || !token(msg.room) || !token(msg.token) ||
        !['host', 'client'].includes(String(msg.role))) {
      error(ws, 'invalid_registration');
      return;
    }
    const role = msg.role as PeerRole;
    const initialRoom = rooms.get(msg.room);
    if (role === 'host') {
      if (!matches(digest(msg.token), msg.room) || !token(msg.clientTokenHash)) { error(ws, 'unauthorized'); return; }
      if (!isRoomApproved(msg.room)) {
        let fingerprint: string | undefined;
        try { fingerprint = config.roomApproval?.notePending(msg.room); }
        catch { error(ws, 'room_approval_unavailable'); return; }
        error(ws, fingerprint ? `room_pending_${fingerprint}` : 'room_not_approved');
        return;
      }
      if (initialRoom) { error(ws, 'already_connected'); return; }
    } else {
      if (!initialRoom || !matches(digest(msg.token), initialRoom.clientHash)) { error(ws, 'host_unavailable_or_unauthorized'); return; }
      if (initialRoom.client) { error(ws, 'already_connected'); return; }
    }

    ws.data.registrationPending = true;
    let servers: IceServer[];
    try {
      servers = await issueIceServers(msg.room, role);
    } catch {
      ws.data.registrationPending = false;
      if (ws.readyState === WebSocket.OPEN) error(ws, 'relay_unavailable');
      return;
    }
    if (ws.readyState !== WebSocket.OPEN) { scheduleRevocation(servers); return; }
    if (role === 'host' && !isRoomApproved(msg.room)) {
      ws.data.registrationPending = false;
      scheduleRevocation(servers);
      error(ws, 'room_not_approved');
      return;
    }
    ws.data.iceServers = servers;

    let room = rooms.get(msg.room);
    if (role === 'host') {
      if (room) { error(ws, 'already_connected'); return; }
      const expires = setTimeout(() => ws.close(1001, 'room_lifetime_reached'), maxRoomLifetimeMs);
      room = { host: ws, clientHash: msg.clientTokenHash as string, expires };
      rooms.set(msg.room, room);
    } else {
      if (room !== initialRoom || !room || room.client || !matches(digest(msg.token), room.clientHash)) {
        error(ws, 'host_unavailable_or_unauthorized');
        return;
      }
      room.client = ws;
    }

    ws.data.authenticated = true;
    ws.data.registrationPending = false;
    ws.data.role = role;
    ws.data.room = msg.room;
    clearTimeout(ws.data.timer);
    send(ws, { type: 'registered', role });
    send(ws, { type: 'ice', servers, ...relayPolicy });
    if (room.client) {
      send(room.host, { type: 'peer', online: true });
      send(room.client, { type: 'peer', online: true });
    }
  };

  const readiness = () => {
    const reasons: string[] = [];
    if (!config.turnProvider) reasons.push('relay_not_configured');
    if (providerHealth.consecutiveFailures >= 3) reasons.push('relay_provider_failing');
    if (stopping) reasons.push('stopping');
    const ready = reasons.length === 0;
    return Response.json({
      status: ready ? 'ready' : 'not_ready',
      protocol: 1,
      reasons,
      relay: {
        provider: config.turnProvider?.kind ?? 'none',
        policy: config.testForceRelay ? 'relay' : 'all',
        lastIssue: providerHealth.lastOutcome,
        consecutiveFailures: providerHealth.consecutiveFailures,
        issuanceRateLimited: providerHealth.rateLimited,
      },
      approval: config.roomApproval ? 'file' : config.allowedRooms ? 'static' : 'open',
      peers: peers.size,
      rooms: rooms.size,
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
    }, { status: ready ? 200 : 503, headers: { 'cache-control': 'no-store' } });
  };

  const server = Bun.serve<PeerData>({
    hostname: config.hostname ?? '127.0.0.1',
    port: config.port ?? 8787,
    fetch(req, bunServer) {
      const url = new URL(req.url);
      if (url.pathname === '/health') return Response.json({ status: 'ok', protocol: 1 });
      if (url.pathname === '/ready' && req.method === 'GET') return readiness();
      if (url.pathname !== '/signal' || url.search || req.method !== 'GET') return new Response('Not found', { status: 404 });
      if (req.headers.has('origin')) return new Response('Native clients only', { status: 403 });
      if (peers.size >= maxPeers) return new Response('Busy', { status: 503 });
      const ip = bunServer.requestIP(req)?.address ?? 'unknown';
      const now = Date.now();
      for (const [key, item] of limits) if (now - item.since >= 60_000) limits.delete(key);
      if (limits.size > 2048) return new Response('Busy', { status: 503 });
      const item = limits.get(ip) ?? { count: 0, since: now };
      item.count += 1;
      limits.set(ip, item);
      if (item.count > connectionAttemptsPerMinute) return new Response('Try later', { status: 429 });
      if (bunServer.upgrade(req, { data: { authenticated: false, registrationPending: false, messages: 0, window: now } })) return;
      return new Response('Upgrade required', { status: 426 });
    },
    websocket: {
      maxPayloadLength: 256 * 1024,
      perMessageDeflate: false,
      idleTimeout: 60,
      backpressureLimit: 512 * 1024,
      closeOnBackpressureLimit: true,
      sendPings: true,
      open(ws) {
        peers.add(ws);
        ws.data.timer = setTimeout(() => {
          if (!ws.data.authenticated) error(ws, 'authentication_timeout');
        }, authTimeoutMs);
      },
      message(ws, raw) {
        if (typeof raw !== 'string' || raw.length > 200 * 1024) { error(ws, 'invalid_message'); return; }
        const now = Date.now();
        if (now - ws.data.window >= 1000) { ws.data.window = now; ws.data.messages = 0; }
        ws.data.messages += 1;
        if (ws.data.messages > messagesPerSecond) { error(ws, 'rate_limit'); return; }
        let msg: Record<string, unknown>;
        try {
          const parsed = JSON.parse(raw);
          if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid');
          msg = parsed;
        } catch {
          error(ws, 'invalid_message');
          return;
        }
        if (!ws.data.authenticated) {
          const task = register(ws, msg);
          pendingRegistrations.add(task);
          void task.then(
            () => pendingRegistrations.delete(task),
            () => pendingRegistrations.delete(task),
          );
          return;
        }
        if (msg.type !== 'signal' || typeof msg.payload !== 'string' || msg.payload.length > 180 * 1024 ||
            msg.payload.length < 40 || !/^[A-Za-z0-9+/]+={0,2}$/.test(msg.payload)) {
          error(ws, 'invalid_message');
          return;
        }
        const room = rooms.get(ws.data.room!);
        const other = ws.data.role === 'host' ? room?.client : room?.host;
        if (!other) { error(ws, 'peer_unavailable', false); return; }
        send(other, { type: 'signal', payload: msg.payload });
      },
      close(ws) {
        clearTimeout(ws.data.timer);
        peers.delete(ws);
        revokePeer(ws);
        if (!ws.data.authenticated || !ws.data.room) return;
        const room = rooms.get(ws.data.room);
        if (!room) return;
        if (room.host === ws) {
          clearTimeout(room.expires);
          rooms.delete(ws.data.room);
          room.client?.close(1001, 'host_disconnected');
        } else if (room.client === ws) {
          room.client = undefined;
          send(room.host, { type: 'peer', online: false });
        }
      },
    },
  });

  if (config.roomApproval) {
    approvalAudit = setInterval(() => {
      for (const [roomID, room] of rooms) {
        if (!isRoomApproved(roomID)) terminateRoom(roomID, room, 'room_approval_revoked');
      }
    }, approvalAuditMs);
  }

  return {
    server,
    stop(cleanupTimeoutMs = 5000) {
      if (stopping) return stopping;
      stopping = (async () => {
        clearInterval(approvalAudit);
        approvalAudit = undefined;
        const timeout = Math.max(0, Math.min(cleanupTimeoutMs, 10_000));
        const deadline = Date.now() + timeout;
        for (const peer of peers) { revokePeer(peer); peer.close(); }
        for (const room of rooms.values()) clearTimeout(room.expires);
        rooms.clear();
        server.stop(true);
        while (Date.now() < deadline) {
          const active = [...pendingRegistrations, ...pendingIssuances, ...pendingRevocations];
          if (active.length === 0) break;
          const remaining = deadline - Date.now();
          await Promise.race([
            Promise.allSettled(active),
            new Promise(resolve => setTimeout(resolve, remaining)),
          ]);
        }
      })();
      return stopping;
    },
    roomCount: () => rooms.size,
  };
}
