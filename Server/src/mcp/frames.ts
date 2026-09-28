import { randomBytes } from 'node:crypto';

const FRAME_TTL_MS = 60_000;
const MAX_FRAME_BYTES = 4 * 1024 * 1024;
const MAX_STORED_FRAMES = 64;

type StoredFrame = { jpeg: Uint8Array; grantId: string; expiresAt: number };

/**
 * Single-use, short-lived JPEG frames handed out by `inspect_screen`. The frame
 * itself is fetched via GET /mcp-ui/frame/<id> and requires the caller's bearer
 * access token (checked by the caller of `take`, which passes the verified
 * grantId) — see app.ts for the justification of bearer-over-nonce.
 */
export class FrameStore {
  private readonly frames = new Map<string, StoredFrame>();

  put(jpeg: Uint8Array, grantId: string, now: () => number = Date.now): string {
    if (jpeg.byteLength > MAX_FRAME_BYTES) throw new Error('frame_too_large');
    this.sweep(now());
    if (this.frames.size >= MAX_STORED_FRAMES) {
      const oldest = this.frames.keys().next().value as string | undefined;
      if (oldest) this.frames.delete(oldest);
    }
    const id = randomBytes(16).toString('hex');
    this.frames.set(id, { jpeg, grantId, expiresAt: now() + FRAME_TTL_MS });
    return id;
  }

  /** Consumes (deletes) the frame on first successful read, regardless of grant match, to stay single-use. */
  take(id: string, grantId: string, now: () => number = Date.now): Uint8Array | undefined {
    const frame = this.frames.get(id);
    if (!frame) return undefined;
    this.frames.delete(id);
    if (frame.expiresAt <= now() || frame.grantId !== grantId) return undefined;
    return frame.jpeg;
  }

  private sweep(now: number) {
    for (const [id, frame] of this.frames) if (frame.expiresAt <= now) this.frames.delete(id);
  }
}
