import { parseRootPins } from "./apple/jws";
import { flagVar, listVar, parseIntegerVar } from "./util";

export type Config = {
  environmentName: string;
  isProduction: boolean;
  bundleId: string;
  appAppleId: number | undefined;
  allowedProductIds: Set<string>;
  acceptSandbox: boolean;
  allowXcode: boolean;
  stunUrls: string[];
  turnTtlSeconds: number;
  leaseMs: number;
  maxDevices: number;
  testForceRelay: boolean;
  roots: Uint8Array[];
  relayConfigured: boolean;
};

const cache = new WeakMap<object, Config>();

export function loadConfig(env: Env): Config {
  const cached = cache.get(env);
  if (cached) return cached;
  const environmentName = env.ENVIRONMENT_NAME || "dev";
  const isProduction = environmentName === "production";
  const allowXcode = flagVar(env.ALLOW_XCODE_TRANSACTIONS);
  const testForceRelay = flagVar(env.TEST_FORCE_RELAY);
  if (isProduction && allowXcode) throw new Error("ALLOW_XCODE_TRANSACTIONS is refused in production");
  if (isProduction && testForceRelay) throw new Error("TEST_FORCE_RELAY is refused in production");
  const stunUrls = listVar(env.STUN_URLS);
  if (stunUrls.length > 8 || stunUrls.some(url => !/^(?:stun|stuns):[^\s]{1,500}$/.test(url))) throw new Error("STUN_URLS invalid");
  const turnTtlSeconds = parseIntegerVar(env.TURN_CREDENTIAL_TTL_SECONDS, 3600, 60, 86_400);
  const leaseSeconds = parseIntegerVar(env.ROOM_LEASE_SECONDS, 1800, 60, 86_400);
  if (leaseSeconds >= turnTtlSeconds) throw new Error("ROOM_LEASE_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS");
  const appAppleId = env.APP_APPLE_ID ? Number(env.APP_APPLE_ID) : undefined;
  if (appAppleId !== undefined && !Number.isSafeInteger(appAppleId)) throw new Error("APP_APPLE_ID must be an integer");
  const relayConfigured = Boolean(env.CLOUDFLARE_TURN_KEY_ID && env.CLOUDFLARE_TURN_KEY_API_TOKEN);
  if (testForceRelay && !relayConfigured) throw new Error("TEST_FORCE_RELAY requires TURN credentials");
  const config: Config = {
    environmentName,
    isProduction,
    bundleId: env.APP_BUNDLE_ID || "com.roshan.PocketDesk.Remote",
    appAppleId,
    allowedProductIds: new Set(listVar(env.ALLOWED_PRODUCT_IDS)),
    acceptSandbox: flagVar(env.ACCEPT_SANDBOX),
    allowXcode,
    stunUrls,
    turnTtlSeconds,
    leaseMs: leaseSeconds * 1000,
    maxDevices: parseIntegerVar(env.MAX_DEVICES_PER_ENTITLEMENT, 3, 1, 10),
    testForceRelay,
    roots: parseRootPins(env.APPLE_ROOT_CERTS),
    relayConfigured,
  };
  cache.set(env, config);
  return config;
}
