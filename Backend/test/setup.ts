import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

type Migrations = Parameters<typeof applyD1Migrations>[1];
const testEnv = env as unknown as Env & { TEST_MIGRATIONS: Migrations };
await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
