import { log } from "./log";
import { AUTH_TIMEOUT_MS, MAX_FRAME_BYTES, parseJsonFrame, parseRegister } from "./protocol";
import { allow } from "./ratelimit";
import type { RoomDO } from "./room";

// The apps send the room only inside the first `register` frame, so the Worker accepts the socket,
// reads that one frame, then pipes the connection to the room's Durable Object. See DESIGN.md §1.

const CLOSE_CODES_ALLOWED = new Set([1000, 1001, 1008, 1009, 1011, 1013]);

function safeClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(CLOSE_CODES_ALLOWED.has(code) ? code : 1000, reason.slice(0, 120));
  } catch {
    try { ws.close(1000, reason.slice(0, 120)); } catch { /* already closed */ }
  }
}

function sendErrorAndClose(ws: WebSocket, code: string): void {
  try { ws.send(JSON.stringify({ type: "error", code })); } catch { /* closed */ }
  safeClose(ws, 1008, code);
}

type Frame = string | ArrayBuffer;

/** Buffers client frames until the room socket exists, then forwards in order. Nothing is dropped between the two phases. */
class ClientRelay {
  private upstream: WebSocket | undefined;
  private readonly backlog: Frame[] = [];
  private firstFrameResolve: ((frame: Frame | undefined) => void) | undefined;
  private failed = false;

  constructor(private readonly client: WebSocket) {
    client.addEventListener("message", event => this.onMessage(event.data as Frame));
    client.addEventListener("close", event => {
      this.firstFrameResolve?.(undefined);
      if (this.upstream) safeClose(this.upstream, event.code, event.reason);
    });
    client.addEventListener("error", () => {
      this.firstFrameResolve?.(undefined);
      if (this.upstream) safeClose(this.upstream, 1011, "error");
    });
  }

  private onMessage(frame: Frame): void {
    if (this.failed) return;
    if (typeof frame !== "string" || frame.length > MAX_FRAME_BYTES) {
      this.failed = true;
      sendErrorAndClose(this.client, "invalid_message");
      if (this.upstream) safeClose(this.upstream, 1008, "invalid_message");
      this.firstFrameResolve?.(undefined);
      return;
    }
    if (this.firstFrameResolve) {
      const resolve = this.firstFrameResolve;
      this.firstFrameResolve = undefined;
      resolve(frame);
      return;
    }
    if (this.upstream) this.forward(frame);
    else this.backlog.push(frame);
  }

  private forward(frame: string): void {
    try {
      this.upstream!.send(frame);
    } catch {
      safeClose(this.client, 1011, "peer_gone");
    }
  }

  firstFrame(timeoutMs: number): Promise<Frame | undefined> {
    return new Promise(resolve => {
      const timer = setTimeout(() => { this.firstFrameResolve = undefined; resolve(undefined); }, timeoutMs);
      this.firstFrameResolve = frame => { clearTimeout(timer); resolve(frame); };
    });
  }

  attach(upstream: WebSocket, firstFrame: string): void {
    this.upstream = upstream;
    upstream.addEventListener("message", event => {
      const data = event.data;
      try {
        this.client.send(typeof data === "string" ? data : new Uint8Array(data as ArrayBuffer));
      } catch {
        safeClose(upstream, 1011, "client_gone");
      }
    });
    upstream.addEventListener("close", event => safeClose(this.client, event.code, event.reason));
    upstream.addEventListener("error", () => safeClose(this.client, 1011, "error"));
    this.forward(firstFrame);
    for (const frame of this.backlog.splice(0)) this.forward(frame as string);
  }
}

export async function handleSignalUpgrade(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "GET" || url.search) return new Response("Not found", { status: 404 });
  if (request.headers.has("origin")) return new Response("Native clients only", { status: 403 });
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("Upgrade required", { status: 426 });
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  if (!(await allow(env.RL_SIGNAL, ip, "RL_SIGNAL"))) return new Response("Try later", { status: 429, headers: { "retry-after": "60" } });

  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
  server.accept();
  const relay = new ClientRelay(server);
  const rooms = env.ROOM as unknown as DurableObjectNamespace<RoomDO>;

  void (async () => {
    const raw = await relay.firstFrame(AUTH_TIMEOUT_MS);
    if (raw === undefined) {
      if (server.readyState === WebSocket.OPEN) sendErrorAndClose(server, "authentication_timeout");
      return;
    }
    const msg = parseJsonFrame(raw);
    if (!msg) { sendErrorAndClose(server, "invalid_message"); return; }
    const register = parseRegister(msg);
    if (!register) { sendErrorAndClose(server, "invalid_registration"); return; }
    if (register.role === "host" && !(await allow(env.RL_ROOM_CREATE, ip, "RL_ROOM_CREATE"))) {
      sendErrorAndClose(server, "room_not_approved");
      return;
    }
    let upstream: WebSocket | null = null;
    try {
      const response = await rooms.get(rooms.idFromName(register.room)).fetch("https://room.internal/connect", { headers: { upgrade: "websocket" } });
      upstream = response.webSocket;
    } catch (error) {
      log("room_connect_failed", { error: error instanceof Error ? error.message : String(error) });
    }
    if (!upstream) { sendErrorAndClose(server, "busy"); return; }
    upstream.accept();
    if (server.readyState !== WebSocket.OPEN) { safeClose(upstream, 1001, "client_gone"); return; }
    relay.attach(upstream, raw as string);
  })().catch(error => {
    log("gateway_failed", { error: error instanceof Error ? error.message : String(error) });
    sendErrorAndClose(server, "busy");
  });

  return new Response(null, { status: 101, webSocket: client });
}
