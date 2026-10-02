import { oneTimeCatalog, type OneTimeCatalog } from "./entitlement/one-time-policy";
import { parseRootPins } from "./apple/jws";
import { flagVar, listVar, parseIntegerVar } from "./util";

export type Config = {
  environmentName: string;
  isProduction: boolean;
  bundleId: string;
  appAppleId: number | undefined;
  allowedProductIds: Set<string>;
  oneTimeProducts?: OneTimeCatalog;
  acceptSandbox: boolean;
  allowXcode: boolean;
  stunUrls: string[];
  turnTtlSeconds: number;
  leaseMs: number;
  maxDevices: number;
  testForceRelay: boolean;
  /** Local dev/test migration switch: legacy peers may receive STUN and TURN. Refused on public deployments. */
  allowUnentitledRelay: boolean;
  /** Staging or explicit local dev pass: these exact rooms are treated as entitled without a purchase. */
  devRelayRooms: Set<string>;
  /** 0 disables; otherwise each peer's last `ice` message is re-sent unchanged every N seconds so quiet sockets stay open. */
  keepaliveMs: number;
  /** 0 refuses every duplicate registration; otherwise a peer silent this long yields to one proving the same credentials. */
  replaceQuietMs: number;
  roots: Uint8Array[];
  relayConfigured: boolean;
};

const cache = new WeakMap<object, Config>();

export const isPublicEnvironment = (name: string): boolean => name !== "dev" && name !== "test";

export function loadConfig(env: Env): Config {
  const cached = cache.get(env);
  if (cached) return cached;
  const environmentName: string = env.ENVIRONMENT_NAME || "dev";
  const isProduction = environmentName === "production";
  const allowXcode = flagVar(env.ALLOW_XCODE_TRANSACTIONS);
  const testForceRelay = flagVar(env.TEST_FORCE_RELAY);
  // Unsigned Xcode transactions are for a developer's own machine only, never a shared deployment.
  if (allowXcode && environmentName !== "dev" && environmentName !== "test") throw new Error("ALLOW_XCODE_TRANSACTIONS is allowed only in dev or test");
  if (isProduction && testForceRelay) throw new Error("TEST_FORCE_RELAY is refused in production");
  const allowUnentitledRelay = flagVar(env.ALLOW_UNENTITLED_RELAY);
  if (isPublicEnvironment(environmentName) && allowUnentitledRelay) {
    throw new Error("ALLOW_UNENTITLED_RELAY is refused on public deployments");
  }
  const devRelayRooms = new Set(listVar((env as { DEV_RELAY_ROOMS?: string }).DEV_RELAY_ROOMS));
  if (devRelayRooms.size > 0) {
    if (isProduction) throw new Error("DEV_RELAY_ROOMS is refused in production");
    if (environmentName !== "staging" && env.ENVIRONMENT_NAME !== "dev") throw new Error("DEV_RELAY_ROOMS is allowed only in staging or explicit dev");
    if (devRelayRooms.size > 4 || [...devRelayRooms].some(room => !/^[a-f0-9]{64}$/.test(room))) throw new Error("DEV_RELAY_ROOMS invalid");
  }
  const keepaliveSeconds = parseIntegerVar(env.KEEPALIVE_SECONDS, 0, 0, 600);
  if (keepaliveSeconds !== 0 && keepaliveSeconds < 15) throw new Error("KEEPALIVE_SECONDS must be 0 or at least 15");
  const replaceQuietSeconds = parseIntegerVar((env as { REPLACE_QUIET_SECONDS?: string }).REPLACE_QUIET_SECONDS, 0, 0, 600);
  if (replaceQuietSeconds !== 0 && replaceQuietSeconds < 5) throw new Error("REPLACE_QUIET_SECONDS must be 0 or at least 5");
  const stunUrls = listVar(env.STUN_URLS);
  if (stunUrls.length > 8 || stunUrls.some(url => !/^(?:stun|stuns):[^\s]{1,500}$/.test(url))) throw new Error("STUN_URLS invalid");
  const turnTtlSeconds = parseIntegerVar(env.TURN_CREDENTIAL_TTL_SECONDS, 3600, 60, 86_400);
  const leaseSeconds = parseIntegerVar(env.ROOM_LEASE_SECONDS, 1800, 60, 86_400);
  if (leaseSeconds >= turnTtlSeconds) throw new Error("ROOM_LEASE_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS");
  const appAppleId = env.APP_APPLE_ID ? Number(env.APP_APPLE_ID) : undefined;
  if (appAppleId !== undefined && !Number.isSafeInteger(appAppleId)) throw new Error("APP_APPLE_ID must be an integer");
  const relayConfigured = Boolean(env.CLOUDFLARE_TURN_KEY_ID && env.CLOUDFLARE_TURN_KEY_API_TOKEN);
  if (testForceRelay && !relayConfigured) throw new Error("TEST_FORCE_RELAY requires TURN credentials");
  const allowedProductIds = new Set(listVar(env.ALLOWED_PRODUCT_IDS));
  const oneTimeIDs = env as Env & { LIFETIME_PRODUCT_ID?: string; FOUNDER_PRODUCT_ID?: string };
  const oneTimeProducts = oneTimeCatalog({ lifetime: oneTimeIDs.LIFETIME_PRODUCT_ID, founder: oneTimeIDs.FOUNDER_PRODUCT_ID }, allowedProductIds);
  const config: Config = {
    environmentName,
    isProduction,
    bundleId: env.APP_BUNDLE_ID || "com.roshan.PocketDesk.Remote",
    appAppleId,
    allowedProductIds,
    oneTimeProducts,
    acceptSandbox: flagVar(env.ACCEPT_SANDBOX),
    allowXcode,
    stunUrls,
    turnTtlSeconds,
    leaseMs: leaseSeconds * 1000,
    maxDevices: parseIntegerVar(env.MAX_DEVICES_PER_ENTITLEMENT, 3, 1, 10),
    testForceRelay,
    allowUnentitledRelay,
    devRelayRooms,
    keepaliveMs: keepaliveSeconds * 1000,
    replaceQuietMs: replaceQuietSeconds * 1000,
    roots: parseRootPins(env.APPLE_ROOT_CERTS),
    relayConfigured,
  };
  cache.set(env, config);
  return config;
}
