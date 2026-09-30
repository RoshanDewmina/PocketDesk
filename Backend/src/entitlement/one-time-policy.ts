/** Build/deployment-owned exact catalog. It recognizes rights, not permission to advertise a sale. */
export type EntitlementKind = "subscription" | "lifetime" | "founder";
export type OneTimeCatalog = ReadonlyMap<string, "lifetime" | "founder">;
export const ONE_TIME_VERIFICATION_MS = 24 * 60 * 60 * 1000;
export function oneTimeCatalog(values: { lifetime?: string; founder?: string }, subscriptions: Set<string>): OneTimeCatalog {
  const result = new Map<string, "lifetime" | "founder">();
  for (const kind of ["lifetime", "founder"] as const) {
    const id = values[kind]?.trim();
    if (!id) continue; // Both absent by default: no invented production product.
    if (id.length > 128 || !/^[A-Za-z0-9._-]+$/.test(id) || subscriptions.has(id) || result.has(id)) {
      throw new Error("one-time product catalog invalid");
    }
    result.set(id, kind);
  }
  return result;
}
