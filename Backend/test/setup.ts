import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

const testEnv = env as unknown as Env & { TEST_MIGRATIONS: D1Migration[] };
await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
