import { CodexClient, type ServerRequestEnvelope } from './codexClient';
import type { SupervisorConfig } from './config';
import { coerceRestartState, readPersistedRecord, writePersistedRecord } from './persistence';
import { checkBackgroundTerminals, findNonTerminalItems, turnHasTerminalStatus } from './quiescence';
import {
  approvalRequestMethods,
  type ApprovalDecision,
  type PendingApproval,
  type Thread,
  type Turn,
} from './protocol';
import { SupervisorStateMachine, type SupervisorState } from './stateMachine';
import { loadWorkspaceAllowlist, validateWorkspace, type WorkspaceAllowlist } from './workspaceAllowlist';

export type StatusSnapshot = {
  state: SupervisorState;
  threadId: string | null;
  activeTurnId: string | null;
  pendingApprovals: Array<{ id: string; kind: string; summary: string }>;
  blockedReasons: string[];
  lastTransitionAt: string;
  workspace: string | null;
  humanInputMustRelease: boolean;
};

type DeferredApproval = PendingApproval & { resolve: (decision: ApprovalDecision) => void };

const pollIntervalMs = 20;

function summarizeApprovalParams(method: string, params: Record<string, unknown>): string {
  if (typeof params.command === 'string') return `${method}: ${params.command}`;
  if (typeof params.reason === 'string') return `${method}: ${params.reason}`;
  return method;
}

function byteLength(text: string): number {
  return new TextEncoder().encode(text).byteLength;
}

export class Supervisor {
  private machine: SupervisorStateMachine;
  private client: CodexClient | null = null;
  private allowlist: WorkspaceAllowlist;
  private threadId: string | null = null;
  private workspace: string | null = null;
  private activeTurnId: string | null = null;
  private lastTransitionAt: string;
  private blockedReasons: string[] = [];
  private humanInputMustRelease = false;
  private pendingApprovals = new Map<string, DeferredApproval>();
  private lastCompletedTurn: Turn | null = null;
  private turnCompletedWaiters: Array<(turn: Turn) => void> = [];
  private turnStartedWaiters: Array<(turn: Turn) => void> = [];
  private childHasEverBeenAlive = false;

  constructor(private readonly config: SupervisorConfig) {
    this.allowlist = loadWorkspaceAllowlist(config.workspaceAllowlist);
    const persisted = readPersistedRecord(config.persistencePath);
    const initialState = persisted ? coerceRestartState(persisted.state) : 'idle';
    this.threadId = initialState === 'human_control' ? persisted?.threadId ?? null : null;
    this.workspace = initialState === 'human_control' ? persisted?.workspace ?? null : null;
    this.lastTransitionAt = persisted?.lastTransitionAt ?? new Date().toISOString();
    this.machine = new SupervisorStateMachine(initialState);
    this.machine.onTransition((state, event) => this.onTransition(state, event));
  }

  private onTransition(state: SupervisorState, _event: string) {
    this.lastTransitionAt = new Date().toISOString();
    if (state === 'human_control') this.humanInputMustRelease = true;
    if (state === 'agent_working') this.humanInputMustRelease = false;
    this.persist();
  }

  private persist() {
    writePersistedRecord(this.config.persistencePath, {
      version: 1,
      state: this.machine.state,
      threadId: this.threadId,
      workspace: this.workspace,
      lastTransitionAt: this.lastTransitionAt,
    });
  }

  status(): StatusSnapshot {
    return {
      state: this.machine.state,
      threadId: this.threadId,
      activeTurnId: this.activeTurnId,
      pendingApprovals: [...this.pendingApprovals.values()].map((approval) => ({
        id: approval.id as string,
        kind: approval.kind,
        summary: approval.summary,
      })),
      blockedReasons: [...this.blockedReasons],
      lastTransitionAt: this.lastTransitionAt,
      workspace: this.workspace,
      humanInputMustRelease: this.humanInputMustRelease,
    };
  }

  async start(workspace: string, prompt: string): Promise<StatusSnapshot> {
    if (this.machine.state !== 'idle' && this.machine.state !== 'stopped') {
      throw new Error(`cannot start a new dispatch from state ${this.machine.state}`);
    }
    const resolvedWorkspace = validateWorkspace(this.allowlist, workspace);

    const client = new CodexClient({
      codexBin: this.config.codexBin,
      extraArgs: this.config.extraArgs,
      spawnArgsOverride: this.config.spawnArgsOverride,
    });
    client.onNotification((method, params) => this.handleNotification(method, params as Record<string, unknown>));
    client.onServerRequest((envelope) => this.handleServerRequest(envelope));
    client.onExit(({ expected }) => this.handleChildExit(expected));

    await client.spawnAndInitialize();
    this.client = client;
    this.childHasEverBeenAlive = true;

    const thread: Thread = await client.threadStart({
      cwd: resolvedWorkspace,
      approvalPolicy: 'on-request',
      sandbox: 'workspace-write',
    });
    this.threadId = thread.id;
    this.workspace = resolvedWorkspace;

    const turnStarted = this.waitForTurnStarted();
    await client.turnStart({ threadId: thread.id, input: [{ type: 'text', text: prompt }] });
    this.activeTurnId = (await turnStarted).id;
    this.machine.apply('START');
    return this.status();
  }

  /** Registered before the triggering turn/start call so a fast fake (or real) server can't race us. */
  private waitForTurnStarted(timeoutMs = 5000): Promise<Turn> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        const index = this.turnStartedWaiters.indexOf(waiter);
        if (index !== -1) this.turnStartedWaiters.splice(index, 1);
        reject(new Error('did not observe turn/started before timeout'));
      }, timeoutMs);
      const waiter = (turn: Turn) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(turn);
      };
      this.turnStartedWaiters.push(waiter);
    });
  }

  private handleNotification(method: string, params: Record<string, unknown>) {
    if (method === 'turn/started') {
      const turn = params.turn as Turn | undefined;
      if (turn) {
        this.activeTurnId = turn.id;
        for (const waiter of this.turnStartedWaiters.splice(0)) waiter(turn);
      }
      return;
    }
    if (method === 'turn/completed') {
      const turn = params.turn as Turn | undefined;
      if (!turn) return;
      this.lastCompletedTurn = turn;
      if (turn.id === this.activeTurnId) {
        for (const waiter of this.turnCompletedWaiters.splice(0)) waiter(turn);
      }
    }
  }

  private async handleServerRequest(envelope: ServerRequestEnvelope): Promise<unknown> {
    const kind = approvalRequestMethods[envelope.method] ?? 'unknown';
    const id = String(envelope.id);
    const decision = await new Promise<ApprovalDecision>((resolve) => {
      this.pendingApprovals.set(id, {
        id,
        kind: kind as PendingApproval['kind'],
        method: envelope.method,
        threadId: (envelope.params.threadId as string) ?? this.threadId ?? '',
        turnId: envelope.params.turnId as string | undefined,
        itemId: envelope.params.itemId as string | undefined,
        summary: summarizeApprovalParams(envelope.method, envelope.params),
        receivedAt: new Date().toISOString(),
        resolve,
      });
    });
    this.pendingApprovals.delete(id);
    return { decision };
  }

  async respondApproval(id: string, decision: ApprovalDecision): Promise<StatusSnapshot> {
    const approval = this.pendingApprovals.get(id);
    if (!approval) throw new Error(`no pending approval with id ${id}`);
    approval.resolve(decision);
    return this.status();
  }

  private handleChildExit(expected: boolean) {
    this.client = null;
    if (expected) return;
    if (this.machine.canApply('CHILD_EXIT_UNEXPECTED')) this.machine.apply('CHILD_EXIT_UNEXPECTED');
  }

  private waitForTurnCompleted(turnId: string, deadlineAt: number): Promise<Turn | null> {
    if (this.lastCompletedTurn?.id === turnId) return Promise.resolve(this.lastCompletedTurn);
    return new Promise((resolve) => {
      const waiter = (turn: Turn) => resolve(turn);
      this.turnCompletedWaiters.push(waiter);
      const remaining = deadlineAt - Date.now();
      if (remaining <= 0) {
        const index = this.turnCompletedWaiters.indexOf(waiter);
        if (index !== -1) this.turnCompletedWaiters.splice(index, 1);
        resolve(null);
        return;
      }
      setTimeout(() => {
        const index = this.turnCompletedWaiters.indexOf(waiter);
        if (index !== -1) {
          this.turnCompletedWaiters.splice(index, 1);
          resolve(null);
        }
      }, remaining);
    });
  }

  async requestTakeover(): Promise<StatusSnapshot> {
    if (this.machine.state !== 'agent_working') {
      throw new Error(`cannot request takeover from state ${this.machine.state}`);
    }
    const client = this.client;
    if (!client) throw new Error('no active codex process');
    const threadId = this.threadId;
    if (!threadId) throw new Error('no active thread');

    const turnId = this.activeTurnId;
    if (!turnId || this.lastCompletedTurn?.id === turnId) {
      const check = await this.runQuiescenceChecklist(client, threadId, this.lastCompletedTurn, Date.now() + this.config.quiesceDeadlineMs);
      if (check.clear) {
        this.machine.apply('TAKEOVER_NO_ACTIVE_TURN');
      } else {
        this.blockedReasons = check.reasons;
        this.machine.apply('IMMEDIATE_BLOCK');
      }
      return this.status();
    }

    this.machine.apply('REQUEST_TAKEOVER');
    void this.driveInterruptAndQuiesce(client, threadId, turnId);
    return this.status();
  }

  private async driveInterruptAndQuiesce(client: CodexClient, threadId: string, turnId: string) {
    try {
      await client.turnInterrupt(threadId, turnId);
    } catch (error) {
      this.blockedReasons = [`turn/interrupt failed: ${error instanceof Error ? error.message : String(error)}`];
      this.applyIfPossible('QUIESCENCE_ERROR');
      return;
    }
    if (!this.applyIfPossible('INTERRUPT_ACKED')) return;
    await this.runQuiesceLoop(client, threadId, turnId);
  }

  /** No-op (instead of throwing) when the supervisor already moved on, e.g. an operator called stop() mid-quiesce. */
  private applyIfPossible(event: Parameters<SupervisorStateMachine['apply']>[0]): boolean {
    if (!this.machine.canApply(event)) return false;
    this.machine.apply(event);
    return true;
  }

  private async runQuiesceLoop(client: CodexClient, threadId: string, turnId: string) {
    const deadlineAt = Date.now() + this.config.quiesceDeadlineMs;
    const completedTurn = await this.waitForTurnCompleted(turnId, deadlineAt);
    if (!completedTurn || !turnHasTerminalStatus(completedTurn)) {
      this.blockedReasons = [`turn ${turnId} did not reach a terminal status before the quiesce deadline`];
      this.applyIfPossible('QUIESCENCE_TIMEOUT');
      return;
    }

    for (;;) {
      if (this.machine.state !== 'quiescing') return;
      const check = await this.runQuiescenceChecklist(client, threadId, completedTurn, deadlineAt);
      if (check.clear) {
        this.blockedReasons = [];
        this.applyIfPossible('QUIESCENCE_CONFIRMED');
        return;
      }
      if (check.fatal) {
        this.blockedReasons = check.reasons;
        this.applyIfPossible('QUIESCENCE_ERROR');
        return;
      }
      if (Date.now() >= deadlineAt) {
        this.blockedReasons = check.reasons;
        this.applyIfPossible('QUIESCENCE_TIMEOUT');
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
    }
  }

  private async runQuiescenceChecklist(
    client: CodexClient,
    threadId: string,
    completedTurn: Turn | null,
    deadlineAt: number,
  ): Promise<{ clear: boolean; fatal: boolean; reasons: string[] }> {
    const reasons: string[] = [];

    if (this.pendingApprovals.size > 0) {
      reasons.push(`${this.pendingApprovals.size} pending approval(s) unresolved`);
    }

    let hasUnknownItemType = false;
    if (completedTurn) {
      const itemCheck = findNonTerminalItems(completedTurn.items);
      reasons.push(...itemCheck.reasons);
      hasUnknownItemType = itemCheck.hasUnknownType;
    }
    if (hasUnknownItemType) {
      return { clear: false, fatal: true, reasons };
    }

    let backgroundList: Array<Record<string, unknown>>;
    try {
      const response = await client.backgroundTerminalsList(threadId);
      backgroundList = response.items ?? [];
    } catch (error) {
      return { clear: false, fatal: true, reasons: [`backgroundTerminals/list failed: ${error instanceof Error ? error.message : String(error)}`] };
    }

    const check = checkBackgroundTerminals(backgroundList);
    if (check.unknownEntries.length > 0) {
      return { clear: false, fatal: true, reasons: [...reasons, ...check.unknownEntries] };
    }
    if (!check.clear) {
      if (Date.now() < deadlineAt) {
        await Promise.allSettled(
          check.aliveProcessIds.map((processId) => client.backgroundTerminalsTerminate(threadId, processId)),
        );
      }
      reasons.push(...check.aliveProcessIds.map((processId) => `background terminal still running: ${processId}`));
    }

    return { clear: reasons.length === 0, fatal: false, reasons };
  }

  async resume(summaryInput: string, screenContextRef?: string): Promise<StatusSnapshot> {
    if (this.machine.state !== 'human_control') {
      throw new Error(`cannot resume from state ${this.machine.state}`);
    }
    if (byteLength(summaryInput) > this.config.maxSummaryBytes) {
      throw new Error(`resume summary exceeds ${this.config.maxSummaryBytes} bytes`);
    }
    const client = this.client;
    if (!client || !client.isAlive()) {
      throw new Error('cannot resume: no live codex process for this thread (supervisor restart or crash requires start() with a fresh session)');
    }
    const threadId = this.threadId;
    if (!threadId) throw new Error('cannot resume: no threadId on record');
    if (!this.workspace) throw new Error('cannot resume: no workspace on record');
    validateWorkspace(this.allowlist, this.workspace);

    this.machine.apply('RESUME_REQUESTED');
    const input: Array<Record<string, unknown>> = [{ type: 'text', text: summaryInput }];
    if (screenContextRef) input.push({ type: 'text', text: `screen-context-ref:${screenContextRef}` });
    this.lastCompletedTurn = null;
    const turnStarted = this.waitForTurnStarted();
    await client.turnStart({ threadId, input });
    this.activeTurnId = (await turnStarted).id;
    this.blockedReasons = [];
    this.machine.apply('RESUME_STARTED');
    return this.status();
  }

  async stop(): Promise<StatusSnapshot> {
    if (this.machine.state === 'stopped') return this.status();
    const client = this.client;
    this.client = null;
    if (client) await client.stop(this.config.stopGraceMs);
    for (const approval of this.pendingApprovals.values()) approval.resolve('cancel');
    this.pendingApprovals.clear();
    this.turnCompletedWaiters.splice(0).forEach((waiter) => waiter({ id: '', items: [], status: 'interrupted', error: null, startedAt: null, completedAt: null, durationMs: null }));
    this.machine.apply('STOP');
    return this.status();
  }

  hasEverSpawnedChild(): boolean {
    return this.childHasEverBeenAlive;
  }
}
