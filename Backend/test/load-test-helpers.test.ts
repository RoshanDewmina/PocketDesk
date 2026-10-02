import { describe, expect, it } from "vitest";
import { clientFeatures, loadConcurrency, parseBoundedInteger, resolveEntitlementTokens, safeWebSocketUrl, validRoomRegistration } from "../scripts/load-test-helpers";

describe("load test safety helpers", () => {
  it("serializes paid room claims while preserving bounded free concurrency", () => {
    expect(loadConcurrency(12, 6, true)).toBe(1);
    expect(loadConcurrency(12, 6, false)).toBe(6);
    expect(loadConcurrency(3, 20, false)).toBe(3);
  });

  it("accepts only bounded integer input", () => {
    expect(parseBoundedInteger("20", 5, 1, 250)).toBe(20);
    expect(parseBoundedInteger(undefined, 5, 1, 250)).toBe(5);
    expect(() => parseBoundedInteger("0", 5, 1, 250)).toThrow("out of range");
    expect(() => parseBoundedInteger("1.5", 5, 1, 250)).toThrow("must be an integer");
  });

  it("never displays URL credentials, query parameters, or fragments", () => {
    expect(safeWebSocketUrl("wss://user:secret@signal.example/signal?token=abc#frag"))
      .toBe("wss://signal.example/signal");
  });

  it("selects distinct paid tokens per room and rejects incomplete lists", () => {
    expect(resolveEntitlementTokens(2, '["first-secret","second-secret"]', undefined))
      .toEqual(["first-secret", "second-secret"]);
    expect(resolveEntitlementTokens(2, undefined, "one-secret")).toEqual(["one-secret", "one-secret"]);
    expect(() => resolveEntitlementTokens(2, '["only-one"]', undefined)).toThrow("one distinct");
    expect(() => resolveEntitlementTokens(2, '["same","same"]', undefined)).toThrow("one distinct");
  });

  it("accepts local and paid message sequences and rejects a paid downgrade", () => {
    const roomMessages = (access: string, includeEntitlementNotice = false) => [
      ...(includeEntitlementNotice ? [{ type: "error", code: "entitlement_required" }] : []),
      { type: "registered", role: "client", access },
      { type: "ice", servers: [] },
      { type: "route", access },
      { type: "peer", online: true },
    ];
    const hostMessages = (access: string) => [
      { type: "route", access },
      { type: "peer", online: true },
    ];
    expect(validRoomRegistration(roomMessages("local", true), hostMessages("local"), false)).toBe(true);
    expect(validRoomRegistration(roomMessages("remote"), hostMessages("remote"), true)).toBe(true);
    expect(validRoomRegistration(roomMessages("local", true), hostMessages("local"), true)).toBe(false);
  });

  it("advertises remote.1 for free registration so local access is explicit", () => {
    expect(clientFeatures()).toEqual(["renew.1", "route.1", "remote.1"]);
    expect(validRoomRegistration([
      { type: "error", code: "entitlement_required" },
      { type: "registered", role: "client", access: "local" },
      { type: "ice", servers: [] },
      { type: "route", access: "local" },
      { type: "peer", online: true },
    ], [
      { type: "route", access: "local" },
      { type: "peer", online: true },
    ], false)).toBe(true);
  });
});
