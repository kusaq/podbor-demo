// Единственная серверная точка мини-аппа. Исходник: supabase/functions/api/index.ts
// Секреты: BOT_TOKEN, BOOT_ADMINS. фронт шлёт publishable-ключ.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const BOT_TOKEN = (Deno.env.get("BOT_TOKEN") ?? "").trim();
console.log("bot token", { length: BOT_TOKEN.length, looksValid: /^\d+:[A-Za-z0-9_-]{30,}$/.test(BOT_TOKEN), botId: BOT_TOKEN.split(":")[0] });
const BOOT_ADMINS = (Deno.env.get("BOOT_ADMINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const MAX_AGE_SEC = 24 * 60 * 60;
const ROLES = ["manager", "owner", "supplier", "admin"];

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

const enc = new TextEncoder();
async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

type TgUser = { id: number; first_name?: string; last_name?: string };

async function verifyInitData(initData: string): Promise<TgUser | null> {
  if (!BOT_TOKEN || !initData) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return null;
  params.delete("hash");
  const checkString = [...params.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");
  const secret = await hmac(enc.encode("WebAppData"), BOT_TOKEN);
  if (hex(await hmac(secret, checkString)) !== hash) {
    console.log("init data signature mismatch", { fields: [...params.keys()], botId: BOT_TOKEN.split(":")[0] });
    return null;
  }
  const age = Date.now() / 1000 - Number(params.get("auth_date"));
  if (!(age >= 0 && age < MAX_AGE_SEC)) {
    console.log("init data too old", { age });
    return null;
  }
  try {
    return JSON.parse(params.get("user") ?? "null");
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { initData?: string; action?: string; payload?: Record<string, unknown> };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const tg = await verifyInitData(String(body.initData ?? ""));
  if (!tg) return json({ error: "bad_init_data" }, 401);
  const myId = String(tg.id);

  const lookup = await db.from("app_users").select("*").eq("tg_id", myId).maybeSingle();
  if (lookup.error) {
    console.error("access lookup failed", { code: lookup.error.code, message: lookup.error.message });
    return json({ error: "db_lookup_failed" }, 500);
  }
  let me = lookup.data;
  if (!me && BOOT_ADMINS.includes(myId)) {
    const name = [tg.first_name, tg.last_name].filter(Boolean).join(" ") || "Админ";
    const ins = await db.from("app_users").insert({ tg_id: myId, name, role: "admin", active: true }).select().single();
    if (ins.error) {
      console.error("admin bootstrap failed", { code: ins.error.code, message: ins.error.message });
      return json({ error: "db_bootstrap_failed" }, 500);
    }
    me = ins.data;
  }
  if (!me || !me.active) return json({ error: "no_access" }, 403);

  const action = body.action;
  const p = body.payload ?? {};

  if (action === "me") {
    const mocks = await db.from("mocks").select("id, kind, data").order("created_at");
    if (mocks.error) {
      console.error("mocks lookup failed", { code: mocks.error.code, message: mocks.error.message });
      return json({ error: "db_mocks_failed" }, 500);
    }
    return json({ me, mocks: mocks.data ?? [] });
  }


  // Personal prototype state. Identity always comes from verified Telegram data.
  if (action === "workspace.get") {
    const result = await db.from("user_workspaces").select("state, revision, updated_at").eq("user_id", myId).maybeSingle();
    if (result.error) return json({ error: "db_workspace_failed" }, 500);
    return json({ state: result.data?.state ?? null, revision: result.data?.revision ?? 0 });
  }

  if (action === "workspace.save") {
    const state = p.state;
    const revision = p.revision;
    if (!state || typeof state !== "object" || Array.isArray(state) ||
        !Number.isSafeInteger(revision) || Number(revision) < 0) return json({ error: "bad_workspace" }, 400);
    if (enc.encode(JSON.stringify(state)).length > 5500000) return json({ error: "workspace_too_large" }, 413);
    const allowed = ["version", "settings", "requests", "clients", "prices", "picked", "callRes", "hist", "sent", "offers", "log", "supArrived", "stockOn", "marketOn"];
    if (Object.keys(state).some((k) => !allowed.includes(k)) || (state as Record<string, unknown>).version !== 1) {
      return json({ error: "bad_workspace" }, 400);
    }
    const record = { state, revision: Number(revision) + 1, updated_at: new Date().toISOString() };
    const result = revision === 0
      ? await db.from("user_workspaces").insert({ ...record, user_id: myId }).select("revision").single()
      : await db.from("user_workspaces").update(record).eq("user_id", myId).eq("revision", revision).select("revision").maybeSingle();
    if (result.error?.code === "23505" || (!result.error && !result.data)) return json({ error: "workspace_conflict" }, 409);
    if (result.error) return json({ error: "db_workspace_failed" }, 500);
    return json({ revision: result.data.revision });
  }

  const canManage = me.role === "admin" || me.role === "owner";
  if (!canManage) return json({ error: "forbidden" }, 403);

  if (action === "users.list") {
    const r = await db.from("app_users").select("*").order("created_at");
    if (r.error) return json({ error: "db", detail: r.error.message }, 500);
    return json({ users: r.data });
  }

  if (action === "users.save") {
    const tgId = String(p.tg_id ?? "").trim();
    const orig = p.orig ? String(p.orig) : null;
    const name = String(p.name ?? "").trim();
    const role = String(p.role ?? "");
    const active = p.active !== false;
    if (!/^-?\d{5,15}$/.test(tgId)) return json({ error: "bad_id" }, 400);
    if (!name) return json({ error: "bad_name" }, 400);
    if (!ROLES.includes(role)) return json({ error: "bad_role" }, 400);
    if (me.role !== "admin") {
      if (role === "admin") return json({ error: "forbidden" }, 403);
      if (orig) {
        const t = await db.from("app_users").select("role").eq("tg_id", orig).maybeSingle();
        if (t.data?.role === "admin") return json({ error: "forbidden" }, 403);
      }
    }
    if (orig === myId && (!active || role !== me.role)) return json({ error: "self" }, 400);
    if (!orig || orig !== tgId) {
      const ex = await db.from("app_users").select("tg_id").eq("tg_id", tgId).maybeSingle();
      if (ex.data) return json({ error: "exists" }, 409);
    }
    const r = orig
      ? await db.from("app_users").update({ tg_id: tgId, name, role, active }).eq("tg_id", orig).select().single()
      : await db.from("app_users").insert({ tg_id: tgId, name, role, active }).select().single();
    if (r.error) return json({ error: "db", detail: r.error.message }, 500);
    return json({ user: r.data });
  }

  if (action === "users.delete") {
    const tgId = String(p.tg_id ?? "");
    if (tgId === myId) return json({ error: "self" }, 400);
    if (me.role !== "admin") {
      const t = await db.from("app_users").select("role").eq("tg_id", tgId).maybeSingle();
      if (t.data?.role === "admin") return json({ error: "forbidden" }, 403);
    }
    const r = await db.from("app_users").delete().eq("tg_id", tgId);
    if (r.error) return json({ error: "db", detail: r.error.message }, 500);
    return json({ ok: true });
  }

  return json({ error: "unknown_action" }, 400);
});
