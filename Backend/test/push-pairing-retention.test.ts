import { describe, expect, it } from "vitest";
import { PUSH_PAIRING_RETENTION_MS, shouldExpirePushPairing } from "../src/push-pairing-retention";

describe("push pairing retention", () => {
  it("expires only inactive pairings at the retention boundary", () => {
    const now = 2_000_000_000_000;
    expect(shouldExpirePushPairing(now - PUSH_PAIRING_RETENTION_MS, now, false)).toBe(true);
    expect(shouldExpirePushPairing(now - PUSH_PAIRING_RETENTION_MS + 1, now, false)).toBe(false);
    expect(shouldExpirePushPairing(now - PUSH_PAIRING_RETENTION_MS * 2, now, true)).toBe(false);
  });
});
