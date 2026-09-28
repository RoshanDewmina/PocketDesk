import { afterEach, describe, expect, test } from 'bun:test';
import { chmodSync, lstatSync, mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { startControlServer, type ControlServerHandle } from '../src/controlServer';
import { loadWorkspaceAllowlist } from '../src/workspaceAllowlist';
import { freshDir } from './helpers';

const controls: ControlServerHandle[] = [];
afterEach(() => controls.splice(0).forEach((control) => control.stop()));

const supervisorStub = {
  status: () => ({ state: 'idle' }),
  start: async () => ({ state: 'agent_working' }),
  requestTakeover: async () => ({ state: 'pause_requested' }),
  resume: async () => ({ state: 'agent_working' }),
  stop: async () => ({ state: 'stopped' }),
  respondApproval: async () => ({ state: 'idle' }),
};

describe('control credential hardening', () => {
  test('creates a regular owner-only token and owner-only socket', () => {
    const root = freshDir('pd-control-safe-');
    const control = startControlServer(join(root, 'control'), supervisorStub as never);
    controls.push(control);
    expect(lstatSync(control.tokenPath).isFile()).toBe(true);
    expect(lstatSync(control.tokenPath).mode & 0o777).toBe(0o600);
    expect(lstatSync(control.socketPath).isSocket()).toBe(true);
    expect(lstatSync(control.socketPath).mode & 0o777).toBe(0o600);
  });

  test('rejects a symlink token instead of following or chmodding its target', () => {
    const root = freshDir('pd-control-link-');
    const controlDir = join(root, 'control');
    mkdirSync(controlDir, { mode: 0o700 });
    const target = join(root, 'target');
    writeFileSync(target, 'do-not-touch');
    chmodSync(target, 0o644);
    symlinkSync(target, join(controlDir, 'control.token'));
    expect(() => startControlServer(controlDir, supervisorStub as never)).toThrow(/symlink|regular file/);
    expect(lstatSync(target).mode & 0o777).toBe(0o644);
  });

  test('rejects an existing token with unsafe permissions', () => {
    const root = freshDir('pd-control-mode-');
    const controlDir = join(root, 'control');
    mkdirSync(controlDir, { mode: 0o700 });
    writeFileSync(join(controlDir, 'control.token'), 'a'.repeat(64), { mode: 0o644 });
    expect(() => startControlServer(controlDir, supervisorStub as never)).toThrow(/0600/);
  });
});

describe('workspace allowlist breadth', () => {
  test('rejects filesystem, home, temp, and ancestor roots', () => {
    expect(() => loadWorkspaceAllowlist(['/'])).toThrow(/too broad/);
    expect(() => loadWorkspaceAllowlist([homedir()])).toThrow(/too broad/);
    expect(() => loadWorkspaceAllowlist([tmpdir()])).toThrow(/too broad/);
  });

  test('accepts a narrow existing project root', () => {
    const root = freshDir('pd-allow-narrow-');
    expect(loadWorkspaceAllowlist([root]).roots).toHaveLength(1);
  });
});
