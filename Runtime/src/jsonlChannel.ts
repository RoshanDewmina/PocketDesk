import type { JsonRpcInbound } from './protocol';

export type JsonlChannel = {
  send(message: unknown): void;
  onMessage(handler: (message: JsonRpcInbound) => void): void;
  onClose(handler: (info: { code: number | null }) => void): void;
  close(): void;
};

/**
 * Wraps a writable sink (child stdin) and a readable stream (child stdout) as
 * newline-delimited JSON-RPC framing. No Content-Length headers per the
 * research doc (codex-app-server.md section 2).
 */
export function createJsonlChannel(
  writable: WritableStream<Uint8Array>,
  readable: ReadableStream<Uint8Array>,
): JsonlChannel {
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const messageHandlers: Array<(message: JsonRpcInbound) => void> = [];
  const closeHandlers: Array<(info: { code: number | null }) => void> = [];
  let buffer = '';
  let closed = false;

  (async () => {
    const reader = readable.getReader();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newlineIndex: number;
        while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
          const line = buffer.slice(0, newlineIndex).trim();
          buffer = buffer.slice(newlineIndex + 1);
          if (!line) continue;
          let parsed: JsonRpcInbound;
          try {
            parsed = JSON.parse(line);
          } catch {
            continue;
          }
          for (const handler of messageHandlers) handler(parsed);
        }
      }
    } catch {
      // stream errored; treat like close below
    } finally {
      closed = true;
      for (const handler of closeHandlers) handler({ code: null });
    }
  })();

  return {
    send(message: unknown) {
      if (closed) throw new Error('cannot send on a closed channel');
      void writer.write(encoder.encode(`${JSON.stringify(message)}\n`));
    },
    onMessage(handler) {
      messageHandlers.push(handler);
    },
    onClose(handler) {
      closeHandlers.push(handler);
    },
    close() {
      closed = true;
      try {
        writer.close();
      } catch {
        // already closed
      }
    },
  };
}
