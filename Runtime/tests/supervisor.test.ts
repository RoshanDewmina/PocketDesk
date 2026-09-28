import { describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Supervisor } from '../src/supervisor';
import { writePersistedRecord } from '../src/persistence';
import { buildConfig, freshDir } from './helpers';

function makeWorkspace(scratchDir: string): string {
  const workspace = join(scratchDir, 'workspace');
  mkdirSync(workspace, { recursive: true });
  return workspace;
}

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for condition');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe('Supervisor: happy takeover', () => {
  test('interrupt -> turn/completed -> human_control', async () => {
    const scratchDir = freshDir('pd-happy-');
    const config = buildConfig({ scenario: 'happy', scratchDir });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    const started = await supervisor.start(workspace, 'do the thing');
    expect(started.state).toBe('agent_working');

    const took = await supervisor.requestTakeover();
    expect(took.state).toBe('pause_requested');

    await waitFor(() => supervisor.status().state === 'human_control');
    const finalStatus = supervisor.status();
    expect(finalStatus.state).toBe('human_control');
    expect(finalStatus.blockedReasons).toEqual([]);
    expect(finalStatus.humanInputMustRelease).toBe(true);

    await supervisor.stop();
  });
});

describe('Supervisor: interrupt ack without completion', () => {
  test('blocks after the quiesce deadline', async () => {
    const scratchDir = freshDir('pd-noack-');
    const config = buildConfig({ scenario: 'interrupt-no-completion', scratchDir, quiesceDeadlineMs: 150 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().state === 'takeover_blocked', 2000);
    expect(supervisor.status().blockedReasons.length).toBeGreaterThan(0);

    await supervisor.stop();
  });
});

describe('Supervisor: item still in progress', () => {
  test('blocks because the completed turn still lists an in-progress item', async () => {
    const scratchDir = freshDir('pd-itemprog-');
    const config = buildConfig({ scenario: 'item-in-progress', scratchDir, quiesceDeadlineMs: 150 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().state === 'takeover_blocked', 2000);
    expect(supervisor.status().blockedReasons.some((reason) => reason.includes('item-1'))).toBe(true);

    await supervisor.stop();
  });
});

describe('Supervisor: pending approval', () => {
  test('surfaces the approval, then declining it lets quiescence complete', async () => {
    const scratchDir = freshDir('pd-approval-');
    const config = buildConfig({ scenario: 'approval-then-quiescent', scratchDir, quiesceDeadlineMs: 2000 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().pendingApprovals.length === 1);
    const approval = supervisor.status().pendingApprovals[0]!;
    expect(approval.kind).toBe('commandExecution');
    expect(approval.summary).toContain('rm -rf');

    await supervisor.respondApproval(approval.id, 'decline');

    await waitFor(() => supervisor.status().state === 'human_control');
    expect(supervisor.status().pendingApprovals).toEqual([]);

    await supervisor.stop();
  });
});

describe('Supervisor: background terminals', () => {
  test('an alive terminal is terminated and re-listed clear', async () => {
    const scratchDir = freshDir('pd-term-ok-');
    const config = buildConfig({ scenario: 'terminal-alive-then-terminated', scratchDir, quiesceDeadlineMs: 2000 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().state === 'human_control', 2000);
    expect(supervisor.status().blockedReasons).toEqual([]);

    await supervisor.stop();
  });

  test('a terminal that stays alive blocks takeover', async () => {
    const scratchDir = freshDir('pd-term-stuck-');
    const config = buildConfig({ scenario: 'terminal-stays-alive', scratchDir, quiesceDeadlineMs: 150 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().state === 'takeover_blocked', 2000);
    expect(supervisor.status().blockedReasons.some((reason) => reason.includes('proc-1'))).toBe(true);

    await supervisor.stop();
  });
});

describe('Supervisor: unknown item type', () => {
  test('blocks rather than guessing it is safe', async () => {
    const scratchDir = freshDir('pd-unknown-');
    const config = buildConfig({ scenario: 'unknown-item-type', scratchDir, quiesceDeadlineMs: 500 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();

    await waitFor(() => supervisor.status().state === 'takeover_blocked', 2000);
    expect(supervisor.status().blockedReasons.some((reason) => reason.includes('unknown item type'))).toBe(true);

    await supervisor.stop();
  });
});

describe('Supervisor: dispatch guarding', () => {
  test('refuses a new start() while pause_requested/quiescing/human_control', async () => {
    const scratchDir = freshDir('pd-guard-');
    const config = buildConfig({ scenario: 'interrupt-no-completion', scratchDir, quiesceDeadlineMs: 5000 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();
    expect(supervisor.status().state).toBe('pause_requested');
    await expect(supervisor.start(workspace, 'again')).rejects.toThrow();

    await waitFor(() => supervisor.status().state === 'quiescing');
    await expect(supervisor.start(workspace, 'again')).rejects.toThrow();

    await supervisor.stop();
    expect(supervisor.status().state).toBe('stopped');
  });
});

describe('Supervisor: resume', () => {
  test('only works from human_control, sends a bounded summary, and rejects an oversized one', async () => {
    const scratchDir = freshDir('pd-resume-');
    const config = buildConfig({ scenario: 'happy', scratchDir, quiesceDeadlineMs: 2000, maxSummaryBytes: 32 });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await expect(supervisor.resume('too early')).rejects.toThrow();

    await supervisor.start(workspace, 'go');
    await supervisor.requestTakeover();
    await waitFor(() => supervisor.status().state === 'human_control', 2000);

    await expect(supervisor.resume('x'.repeat(64))).rejects.toThrow();
    expect(supervisor.status().state).toBe('human_control');

    const resumed = await supervisor.resume('short summary');
    expect(resumed.state).toBe('agent_working');
    expect(resumed.humanInputMustRelease).toBe(false);

    await supervisor.stop();
  });
});

describe('Supervisor: child crash', () => {
  test('an unexpected exit goes to error, never auto-resumes', async () => {
    const scratchDir = freshDir('pd-crash-');
    const config = buildConfig({ scenario: 'crash-after-start', scratchDir });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await waitFor(() => supervisor.status().state === 'error', 2000);

    await expect(supervisor.resume('anything')).rejects.toThrow();
    await supervisor.stop();
    expect(supervisor.status().state).toBe('stopped');
  });
});

describe('Supervisor: restart semantics', () => {
  test('a persisted agent_working state comes back as stopped, never agent_working', () => {
    const scratchDir = freshDir('pd-restart-working-');
    mkdirSync(scratchDir, { recursive: true });
    const persistencePath = join(scratchDir, 'state.json');
    writePersistedRecord(persistencePath, {
      version: 1,
      state: 'agent_working',
      threadId: 'thread-x',
      workspace: scratchDir,
      lastTransitionAt: new Date().toISOString(),
    });
    const config = buildConfig({ scenario: 'happy', scratchDir, persistencePath });
    const supervisor = new Supervisor(config);
    expect(supervisor.status().state).toBe('stopped');
  });

  test('a persisted human_control state stays human_control but cannot resume without a live child', async () => {
    const scratchDir = freshDir('pd-restart-human-');
    mkdirSync(scratchDir, { recursive: true });
    const persistencePath = join(scratchDir, 'state.json');
    writePersistedRecord(persistencePath, {
      version: 1,
      state: 'human_control',
      threadId: 'thread-x',
      workspace: scratchDir,
      lastTransitionAt: new Date().toISOString(),
    });
    const config = buildConfig({ scenario: 'happy', scratchDir, persistencePath });
    const supervisor = new Supervisor(config);
    expect(supervisor.status().state).toBe('human_control');
    await expect(supervisor.resume('hello')).rejects.toThrow(/no live codex process/);
  });
});

describe('Supervisor: stop', () => {
  test('kills the whole process group, including a grandchild', async () => {
    const scratchDir = freshDir('pd-group-');
    const pidFile = join(scratchDir, 'child.pid');
    mkdirSync(scratchDir, { recursive: true });
    const config = buildConfig({ scenario: 'process-group', scratchDir, substitutions: { __PID_FILE__: pidFile } });
    const supervisor = new Supervisor(config);
    const workspace = makeWorkspace(scratchDir);

    await supervisor.start(workspace, 'go');
    await waitFor(() => existsSync(pidFile), 2000);
    const grandchildPid = Number(readFileSync(pidFile, 'utf8').trim());
    expect(Number.isInteger(grandchildPid)).toBe(true);
    expect(processAlive(grandchildPid)).toBe(true);

    await supervisor.stop();
    await waitFor(() => !processAlive(grandchildPid), 2000);
    expect(processAlive(grandchildPid)).toBe(false);
  });
});

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH';
  }
}
