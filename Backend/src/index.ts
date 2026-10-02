import { adminRoom, adminTestNotification, forgetRoom, health, isAdmin, ready } from "./admin";
import { handleActivityRegister, handleActivityRemove, purgeActivityRetention, retryPendingActivityEnds } from "./activity";
import { loadConfig } from "./config";
import { handleNotification } from "./entitlement/notifications";
import { recoverSubscriptions } from "./entitlement/recovery";
import { purgeRetention } from "./entitlement/store";
import { handleForget, handleVerify } from "./entitlement/verify";
import { handleGuestUpgrade, handleSignalUpgrade } from "./gateway";
import { guestPage } from "./guest-page";
import { log, logError } from "./log";
import { handlePushEvent, handlePushPreferences, handlePushRegister, handlePushRemove, handlePushReport, purgePushRetention } from "./push";
import { json } from "./util";

export { RoomDO } from "./room";

const securityHeaders = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "cache-control": "no-store",
};

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const config = loadConfig(env);

  if ((path === "/guest" || path === "/guest.js") && ["GET", "HEAD"].includes(request.method) && !url.search) return guestPage(request);
  if (path === "/guest-signal") return handleGuestUpgrade(request, env);
  if (path === "/signal") return handleSignalUpgrade(request, env);
  if (path === "/health" && request.method === "GET") return health();

  if (request.method === "POST") {
    if (path === "/v1/entitlements/verify") return handleVerify(request, env, ctx, config);
    if (path === "/v1/entitlements/forget") return handleForget(request, env, config);
    if (path === "/v1/appstore/notifications") return handleNotification(request, env, config);
    if (path === "/v1/rooms/forget") return forgetRoom(request, env);
    if (path === "/v1/push/register") return handlePushRegister(request, env);
    if (path === "/v1/push/remove") return handlePushRemove(request, env);
    if (path === "/v1/push/preferences") return handlePushPreferences(request, env);
    if (path === "/v1/push/event") return handlePushEvent(request, env);
    if (path === "/v1/push/report") return handlePushReport(request, env);
    if (path === "/v1/activity/register") return handleActivityRegister(request, env);
    if (path === "/v1/activity/remove") return handleActivityRemove(request, env);
  }

  if (path === "/ready" || path.startsWith("/v1/admin/")) {
    if (!(await isAdmin(request, env))) return new Response("Not found", { status: 404 });
    if (path === "/ready" && request.method === "GET") return ready(env, config);
    const room = /^\/v1\/admin\/rooms\/([a-f0-9]{64})\/(block|unblock|status)$/.exec(path);
    if (room && (request.method === "POST" || (room[2] === "status" && request.method === "GET"))) return adminRoom(request, env, room[1]!, room[2]!);
    if (path === "/v1/admin/appstore/test-notification" && request.method === "POST") return adminTestNotification(request, env, config);
  }
  return new Response("Not found", { status: 404 });
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      const response = await route(request, env, ctx);
      if (response.status === 101) return response;
      const headers = new Headers(response.headers);
      for (const [key, value] of Object.entries(securityHeaders)) headers.set(key, value);
      return new Response(response.body, { status: response.status, headers });
    } catch (error) {
      logError("unhandled", error, { path: new URL(request.url).pathname });
      return json({ error: "internal" }, 500, securityHeaders);
    }
  },

  async scheduled(controller, env, ctx): Promise<void> {
    if (controller.cron === "* * * * *") {
      ctx.waitUntil(recoverSubscriptions(env, loadConfig(env)).catch(() => log("subscription_recovery_failed")));
      ctx.waitUntil(retryPendingActivityEnds(env).then(result => {
        if (result.accepted || result.failed || result.invalidToken || result.expired)
          log("activity_end_retry", result);
      }).catch(error => logError("activity_end_retry_failed", error)));
      return;
    }
    ctx.waitUntil((async () => {
      try {
        await retryPendingActivityEnds(env);
        const purged = await purgeRetention(env.DB, Date.now());
        await purgePushRetention(env.DB, Date.now());
        await purgeActivityRetention(env.DB, Date.now());
        log("retention_purge", { cron: controller.cron, ...purged });
      } catch (error) {
        logError("retention_purge_failed", error);
      }
    })());
  },
} satisfies ExportedHandler<Env>;
