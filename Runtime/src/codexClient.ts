import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { Readable, Writable } from 'node:stream';
import { createJsonlChannel, type JsonlChannel } from './jsonlChannel';
import {
  approvalRequestMethods,
  isNotification,
  isRequest,
  isResponse,
  type JsonRpcInbound,
  type RequestId,
  type Thread,
} from './protocol';
import { BoundedTail } from './boundedTail';

export type CodexClientConfig = {
  codexBin: string;
  extraArgs?: string[];
  /** Overrides the default `["app-server", ...extraArgs]` spawn args entirely. Test-only escape hatch for driving a fake process. */
  spawnArgsOverride?: string[];
  cwdForSpawn?: string;
  env?: Record<string, string | undefined>;
};

export type ServerRequestEnvelope = {
  id: RequestId;
  method: string;
  params: Record<string, unknown>;
};

type PendingCall = { resolve: (value: unknown) => void; reject: (error: Error) => void };

export class CodexProtocolError extends Error {
  constructor(message: string, public readonly data?: unknown) {
    super(message);
  }
}

/**
 * Owns exactly one `codex app-server` child process over stdio JSON-RPC.
 * Never calls thread/list or thread/resume with an ID it did not itself
 * receive from thread/start — see codex-app-server.md section 4's isolation
 * finding.
 */
export class CodexClient {
  private child: ChildProcessWithoutNullStreams | null = null;
  private channel: JsonlChannel | null = null;
  private nextId = 1;
  private pending = new Map<RequestId, PendingCall>();
  private notificationHandlers: Array<(method: string, params: unknown) => void> = [];
  private serverRequestHandler: ((envelope: ServerRequestEnvelope) => Promise<unknown>) | null = null;
  private exitHandlers: Array<(info: { code: number | null; signal: NodeJS.Signals | null; expected: boolean }) => void> = [];
  private expectingExit = false;
  readonly stderrTail = new BoundedTail(200);

  constructor(private readonly config: CodexClientConfig) {}

  get pid(): number | null {
    return this.child?.pid ?? null;
  }

  isAlive(): boolean {
    return this.child !== null && this.child.exitCode === null && this.child.signalCode === null;
  }

  onNotification(handler: (method: string, params: unknown) => void) {
    this.notificationHandlers.push(handler);
  }

  onServerRequest(handler: (envelope: ServerRequestEnvelope) => Promise<unknown>) {
    this.serverRequestHandler = handler;
  }

  onExit(handler: (info: { code: number | null; signal: NodeJS.Signals | null; expected: boolean }) => void) {
    this.exitHandlers.push(handler);
  }

  /** Spawns the child in its own process group so `stop()` can kill descendants too. */
  async spawnAndInitialize(): Promise<{ userAgent: string; codexHome: string }> {
    if (this.child) throw new Error('codex client already spawned');
    const args = this.config.spawnArgsOverride ?? ['app-server', ...(this.config.extraArgs ?? [])];
    const child = spawn(this.config.codexBin, args, {
      cwd: this.config.cwdForSpawn,
      env: { ...process.env, ...this.config.env },
      stdio: ['pipe', 'pipe', 'pipe'],
      detached: true,
    });
    this.child = child;

    child.stderr.on('data', (chunk: Buffer) => this.stderrTail.push(chunk.toString('utf8')));
    child.on('exit', (code, signal) => {
      const expected = this.expectingExit;
      this.channel?.close();
      for (const [, call] of this.pending) call.reject(new Error('codex app-server exited'));
      this.pending.clear();
      for (const handler of this.exitHandlers) handler({ code, signal, expected });
    });

    this.channel = createJsonlChannel(Writable.toWeb(child.stdin) as WritableStream<Uint8Array>, Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>);
    this.channel.onMessage((message) => this.handleInbound(message));

    const result = (await this.call('initialize', {
      clientInfo: { name: 'pocketdesk', title: 'PocketDesk', version: '0.0.1' },
      capabilities: { experimentalApi: true, requestAttestation: false },
    })) as { userAgent: string; codexHome: string };
    this.notify('initialized', {});
    return result;
  }

  private handleInbound(message: JsonRpcInbound) {
    if (isResponse(message)) {
      const call = this.pending.get(message.id);
      if (!call) return;
      this.pending.delete(message.id);
      if ('error' in message) call.reject(new CodexProtocolError(message.error.message, message.error.data));
      else call.resolve(message.result);
      return;
    }
    if (isNotification(message)) {
      for (const handler of this.notificationHandlers) handler(message.method, message.params);
      return;
    }
    if (isRequest(message)) {
      void this.handleServerRequest(message);
    }
  }

  private async handleServerRequest(message: { id: RequestId; method: string; params?: unknown }) {
    if (!this.serverRequestHandler) {
      this.respondError(message.id, -32000, 'no server-request handler registered');
      return;
    }
    try {
      const result = await this.serverRequestHandler({
        id: message.id,
        method: message.method,
        params: (message.params ?? {}) as Record<string, unknown>,
      });
      this.channel?.send({ id: message.id, result });
    } catch (error) {
      this.respondError(message.id, -32001, error instanceof Error ? error.message : 'server request handler failed');
    }
  }

  private respondError(id: RequestId, code: number, message: string) {
    this.channel?.send({ id, error: { code, message } });
  }

  private call(method: string, params?: unknown): Promise<unknown> {
    if (!this.channel) throw new Error('codex client not spawned');
    const id = this.nextId++;
    const promise = new Promise<unknown>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.channel.send({ id, method, params });
    return promise;
  }

  private notify(method: string, params?: unknown) {
    this.channel?.send({ method, params });
  }

  threadStart(params: Record<string, unknown>): Promise<Thread> {
    return this.call('thread/start', params) as Promise<Thread>;
  }

  turnStart(params: Record<string, unknown>): Promise<unknown> {
    return this.call('turn/start', params);
  }

  turnInterrupt(threadId: string, turnId: string): Promise<unknown> {
    return this.call('turn/interrupt', { threadId, turnId });
  }

  backgroundTerminalsList(threadId: string): Promise<{ items: Array<Record<string, unknown>> }> {
    return this.call('thread/backgroundTerminals/list', { threadId }) as Promise<{ items: Array<Record<string, unknown>> }>;
  }

  backgroundTerminalsTerminate(threadId: string, processId: string): Promise<unknown> {
    return this.call('thread/backgroundTerminals/terminate', { threadId, processId });
  }

  backgroundTerminalsClean(threadId: string): Promise<unknown> {
    return this.call('thread/backgroundTerminals/clean', { threadId });
  }

  /** Kills the child's whole process group. Resolves once the exit event has fired. */
  async stop(graceMs = 3000): Promise<void> {
    const child = this.child;
    if (!child || !this.isAlive()) return;
    this.expectingExit = true;
    const exited = new Promise<void>((resolve) => {
      child.once('exit', () => resolve());
    });
    this.killGroup('SIGTERM');
    const timeout = new Promise<void>((resolve) => setTimeout(resolve, graceMs));
    await Promise.race([exited, timeout]);
    if (this.isAlive()) {
      this.killGroup('SIGKILL');
      await exited;
    }
  }

  private killGroup(signal: NodeJS.Signals) {
    const pid = this.child?.pid;
    if (!pid) return;
    try {
      process.kill(-pid, signal);
    } catch {
      try {
        this.child?.kill(signal);
      } catch {
        // process already gone
      }
    }
  }
}

export function isApprovalMethod(method: string): boolean {
  return method in approvalRequestMethods;
}
