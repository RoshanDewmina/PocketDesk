import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { RequestHandlerExtra } from '@modelcontextprotocol/sdk/shared/protocol.js';
import type { ServerRequest, ServerNotification, CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import type { HostBridge } from './bridge';
import type { FrameStore } from './frames';
import type { Scope } from './store';

const INTENT_TTL_MS = 10 * 60 * 1000;
const MAX_INSPECT_JPEG_BYTES = 4 * 1024 * 1024;

type Extra = RequestHandlerExtra<ServerRequest, ServerNotification>;

function grantContext(extra: Extra): { grantId: string; hostID: string } | undefined {
  const info = extra.authInfo;
  const grantId = info?.extra?.grantId;
  const hostID = info?.extra?.hostID;
  if (typeof grantId !== 'string' || typeof hostID !== 'string') return undefined;
  return { grantId, hostID };
}

function hasScope(extra: Extra, scope: Scope): boolean {
  return extra.authInfo?.scopes.includes(scope) ?? false;
}

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: 'text', text }], isError };
}

function jsonResult(value: Record<string, unknown>): CallToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value };
}

export function buildMcpServer(deps: { origin: string; host: HostBridge; frames: FrameStore; now?: () => number }): McpServer {
  const now = deps.now ?? Date.now;
  const server = new McpServer({ name: 'pocketdesk', version: '1.0.0' });

  server.registerTool(
    'request_desktop_access',
    {
      title: 'Request desktop access',
      description: 'Creates an access intent for viewing or controlling the paired Mac. Opening the returned link grants nothing by itself.',
      inputSchema: {},
    },
    async (_args, extra) => {
      const ctx = grantContext(extra);
      if (!ctx) return textResult('unauthorized', true);
      if (!hasScope(extra, 'desktop.access')) return textResult('insufficient_scope', true);
      const readiness = await deps.host.hostStatus(ctx.hostID);
      const intent = await deps.host.createIntent({ hostID: ctx.hostID, grantId: ctx.grantId, ttlMs: INTENT_TTL_MS });
      const viewerURL = `${deps.origin}/?intent=${intent.intentID}`;
      return jsonResult({ viewerURL, readiness, intentID: intent.intentID, expiresAt: intent.expiresAt });
    },
  );

  server.registerTool(
    'session_status',
    {
      title: 'Session status',
      description: "Reports status for one of the caller's own access intents.",
      inputSchema: { intentID: z.string().min(1).max(200) },
    },
    async (args, extra) => {
      const ctx = grantContext(extra);
      if (!ctx) return textResult('unauthorized', true);
      if (!hasScope(extra, 'desktop.access')) return textResult('insufficient_scope', true);
      const intent = await deps.host.lookupIntent(args.intentID);
      if (!intent || intent.grantId !== ctx.grantId) return textResult('intent_not_found', true);
      const status = await deps.host.sessionForIntent(args.intentID);
      if (!status) return textResult('intent_not_found', true);
      return jsonResult({ ...status });
    },
  );

  server.registerTool(
    'stop_session',
    {
      title: 'Stop session',
      description: "Ends a browser session admitted through one of the caller's own intents. Idempotent.",
      inputSchema: { intentID: z.string().min(1).max(200) },
    },
    async (args, extra) => {
      const ctx = grantContext(extra);
      if (!ctx) return textResult('unauthorized', true);
      if (!hasScope(extra, 'desktop.access')) return textResult('insufficient_scope', true);
      const intent = await deps.host.lookupIntent(args.intentID);
      if (!intent || intent.grantId !== ctx.grantId) return textResult('intent_not_found', true);
      const status = await deps.host.sessionForIntent(args.intentID);
      if (!status?.sessionID) return jsonResult({ stopped: false, alreadyEnded: true });
      const result = await deps.host.stopSession(intent.hostID, status.sessionID);
      return jsonResult({ stopped: result === 'stopped', alreadyEnded: result === 'already_ended' });
    },
  );

  server.registerTool(
    'inspect_screen',
    {
      title: 'Inspect screen',
      description:
        'Captures one fresh screenshot of the paired Mac. Requires a separate, active, Mac-created inspection grant. ' +
        'The returned frame enters this conversation as image content the model can see.',
      inputSchema: {},
    },
    async (_args, extra) => {
      const ctx = grantContext(extra);
      if (!ctx) return textResult('unauthorized', true);
      if (!hasScope(extra, 'screen.inspect')) return textResult('insufficient_scope', true);
      const grant = await deps.host.inspectionGrant(ctx.hostID);
      if (!grant) return textResult('inspection_not_granted', true);
      if (!grant.active || grant.expiresAt <= now()) return textResult('inspection_expired', true);
      const readiness = await deps.host.hostStatus(ctx.hostID);
      if (readiness === 'host_offline') return textResult('host_offline', true);
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 10_000);
      let frame: { jpeg: Uint8Array; capturedAt: number };
      try {
        frame = await deps.host.captureInspectionFrame(ctx.hostID, controller.signal);
      } catch {
        return textResult('host_offline', true);
      } finally {
        clearTimeout(timer);
      }
      if (frame.jpeg.byteLength > MAX_INSPECT_JPEG_BYTES) return textResult('inspection_expired', true);
      const frameId = deps.frames.put(frame.jpeg, ctx.grantId, now);
      const frameURL = `${deps.origin}/mcp-ui/frame/${frameId}`;
      return {
        content: [
          { type: 'image', data: Buffer.from(frame.jpeg).toString('base64'), mimeType: 'image/jpeg' },
          { type: 'text', text: `Captured at ${new Date(frame.capturedAt).toISOString()}` },
        ],
        structuredContent: { capturedAt: frame.capturedAt, frameURL },
      };
    },
  );

  server.registerResource(
    'pocketdesk-viewer',
    'ui://pocketdesk/viewer',
    {
      title: 'PocketDesk viewer',
      description: 'Embedded PocketDesk desktop viewer widget.',
      mimeType: 'text/html;profile=mcp-app',
      _meta: {
        ui: {
          csp: { connectDomains: [deps.origin], resourceDomains: [deps.origin] },
        },
      },
    },
    async uri => ({
      contents: [
        {
          uri: uri.href,
          mimeType: 'text/html;profile=mcp-app',
          text: viewerShellHtml(deps.origin),
        },
      ],
    }),
  );

  return server;
}

function viewerShellHtml(origin: string): string {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>PocketDesk</title>
<style>html,body{margin:0;height:100%;background:#000;color:#eee;font:14px system-ui}
.placeholder{display:flex;align-items:center;justify-content:center;height:100%}</style>
</head><body>
<div class="placeholder">PocketDesk viewer &mdash; connecting to ${origin}&hellip;</div>
</body></html>`;
}
