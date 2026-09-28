import { existsSync, lstatSync, realpathSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { isAbsolute, resolve, sep } from 'node:path';

export type WorkspaceAllowlist = {
  roots: string[];
};

function isSameOrAncestor(candidate: string, path: string): boolean {
  return candidate === path || path.startsWith(candidate.endsWith(sep) ? candidate : `${candidate}${sep}`);
}

function rejectBroadRoot(root: string) {
  const home = realpathSync(homedir());
  const temp = realpathSync(tmpdir());
  const explicitBroadRoots = new Set([
    sep,
    '/Applications',
    '/Library',
    '/System',
    '/Users',
    '/Volumes',
    '/private',
    '/private/tmp',
    '/tmp',
    '/var',
    '/etc',
    '/usr',
    '/opt',
  ]);
  if (explicitBroadRoots.has(root) || root === temp || isSameOrAncestor(root, home)) {
    throw new Error(`workspace allowlist root is too broad: ${root}`);
  }
}

export function loadWorkspaceAllowlist(roots: string[]): WorkspaceAllowlist {
  if (roots.length === 0) throw new Error('workspace allowlist must not be empty');
  const resolvedRoots: string[] = [];
  for (const root of roots) {
    if (!isAbsolute(root)) throw new Error(`workspace allowlist entry must be absolute: ${root}`);
    if (!existsSync(root) || !lstatSync(root).isDirectory()) {
      throw new Error(`workspace allowlist entry does not exist or is not a directory: ${root}`);
    }
    const resolved = realpathSync(root);
    rejectBroadRoot(resolved);
    resolvedRoots.push(resolved);
  }
  return { roots: resolvedRoots };
}

function isUnder(candidate: string, root: string): boolean {
  if (candidate === root) return true;
  return candidate.startsWith(root.endsWith(sep) ? root : `${root}${sep}`);
}

/** Throws with a specific reason on rejection; returns the resolved real path on success. */
export function validateWorkspace(allowlist: WorkspaceAllowlist, workspace: string): string {
  if (!isAbsolute(workspace)) throw new Error('workspace must be an absolute path');
  if (!existsSync(workspace) || !lstatSync(workspace).isDirectory()) {
    throw new Error('workspace must be an existing directory');
  }
  const resolved = realpathSync(resolve(workspace));
  if (resolved === sep || resolved === '/') throw new Error('workspace must not be the filesystem root');
  const home = realpathSync(homedir());
  if (resolved === home) throw new Error('workspace must not be the home directory root');
  if (!allowlist.roots.some((root) => isUnder(resolved, root))) {
    throw new Error('workspace is outside the configured allowlist');
  }
  return resolved;
}
