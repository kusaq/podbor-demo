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
    const user = JSON.parse(params.get("user") ?? "null");
    return user && Number.isSafeInteger(user.id) && user.id > 0 ? user : null;
  } catch {
    return null;
  }
}

async function hashValue(value: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(value))));
}
function crmError(error: { code?: string; message?: string }): Response {
  const message = error.message ?? '';
  const names = ['crm_forbidden','crm_not_found','crm_conflict','crm_bad_assignee','crm_bad_status','crm_reason_required','crm_comment_required','crm_consent_required','crm_bad_comment'];
  const name = names.find((x) => message.includes(x));
  if (name) return json({ error: name }, name === 'crm_forbidden' ? 403 : name === 'crm_not_found' ? 404 : name === 'crm_conflict' ? 409 : 400);
  if (error.code === '23505') return json({ error: 'crm_duplicate' }, 409);
  if (['23514','23502','22P02','22007','22008','22003'].includes(error.code ?? '')) return json({ error: 'crm_bad_data' }, 400);
  console.error('crm database operation failed', { code: error.code });
  return json({ error: 'crm_db' }, 500);
}
function crmData(input: unknown, creating: boolean): Record<string, unknown> | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const data = input as Record<string, unknown>;
  const allowed = ['client_name','phone','model','budget','generation','years','mileage','spec','city','payment','legal','purchase_time','source_text','consent_at','status','reasons','main_reason','note','assigned_to','next_contact_at','archived'];
  if (Object.keys(data).some((k) => !allowed.includes(k))) return null;
  const result = { ...data };
  const lengths: Record<string,number> = { client_name:160,model:200,generation:200,years:80,spec:4000,city:160,payment:30,legal:30,purchase_time:200,source_text:12000,main_reason:160,note:4000 };
  for (const [key, max] of Object.entries(lengths)) {
    if (key in result && (typeof result[key] !== 'string' || String(result[key]).length > max)) return null;
  }
  if ('phone' in result) {
    let phone = String(result.phone).replace(/\D/g, '');
    if (phone.length === 11 && phone[0] === '8') phone = '7' + phone.slice(1);
    if (phone.length === 10) phone = '7' + phone;
    if (!/^\d{10,15}$/.test(phone)) return null;
    result.phone = phone;
  }
  if ('budget' in result) {
    const n = Number(result.budget); if (!Number.isFinite(n) || n <= 0 || n > 100000000000) return null; result.budget = n;
  }
  if ('mileage' in result && result.mileage !== null && result.mileage !== '') {
    const n = Number(result.mileage); if (!Number.isSafeInteger(n) || n < 0 || n > 20000000) return null; result.mileage = n;
  }
  for (const key of ['consent_at','next_contact_at']) {
    if (key in result && result[key] !== null && result[key] !== '' && (typeof result[key] !== 'string' || !Number.isFinite(Date.parse(String(result[key]))))) return null;
  }
  if ('reasons' in result && (!Array.isArray(result.reasons) || result.reasons.length > 20 || result.reasons.some((x: unknown) => typeof x !== 'string' || x.length > 160 || !x.trim()))) return null;
  if ('assigned_to' in result && result.assigned_to !== null && result.assigned_to !== '' && !/^\d{5,15}$/.test(String(result.assigned_to))) return null;
  if ('status' in result && !['search','think','lost','won'].includes(String(result.status))) return null;
  if ('archived' in result && typeof result.archived !== 'boolean') return null;
  if (creating && (!String(result.client_name ?? '').trim() || !String(result.model ?? '').trim() || !result.phone || !result.budget || !result.consent_at)) return null;
  return result;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { initData?: string; desktopSession?: string; action?: string; payload?: Record<string, unknown> };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ error: 'bad_json' }, 400);
  const action = body.action;
  const p = body.payload && typeof body.payload === 'object' && !Array.isArray(body.payload) ? body.payload : {};
  let myId: string;
  let tg: TgUser | null = null;
  let sessionHash: string | null = null;
  if (action === 'desktop.exchange') {
    const code = String(p.code ?? '').toUpperCase().replace(/[\s-]/g, '');
    if (!/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{12}$/.test(code)) return json({ error: 'desktop_bad_code' }, 401);
    const found = await db.from('desktop_login_codes').delete().eq('code_hash', await hashValue(code)).gt('expires_at', new Date().toISOString()).select('user_id').maybeSingle();
    if (found.error) return json({ error: 'desktop_db' }, 500);
    if (!found.data) return json({ error: 'desktop_bad_code' }, 401);
    const user = await db.from('app_users').select('tg_id,role,active').eq('tg_id', found.data.user_id).maybeSingle();
    if (user.error) return json({ error: 'desktop_db' }, 500);
    if (!user.data?.active || !['admin','owner','manager'].includes(user.data.role)) return json({ error: 'no_access' }, 403);
    const sessionToken = hex(crypto.getRandomValues(new Uint8Array(32)));
    const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
    const inserted = await db.from('desktop_sessions').insert({ token_hash: await hashValue(sessionToken), user_id: user.data.tg_id, expires_at: expiresAt });
    if (inserted.error) return json({ error: 'desktop_db' }, 500);
    return json({ sessionToken, expiresAt });
  }
  if (body.desktopSession) {
    if (!/^[a-f0-9]{64}$/.test(body.desktopSession)) return json({ error: 'desktop_expired' }, 401);
    sessionHash = await hashValue(body.desktopSession);
    const session = await db.from('desktop_sessions').select('user_id').eq('token_hash', sessionHash).gt('expires_at', new Date().toISOString()).maybeSingle();
    if (session.error) return json({ error: 'desktop_db' }, 500);
    if (!session.data) return json({ error: 'desktop_expired' }, 401);
    myId = String(session.data.user_id);
  } else {
    tg = await verifyInitData(String(body.initData ?? ''));
    if (!tg) return json({ error: 'bad_init_data' }, 401);
    myId = String(tg.id);
  }

  const lookup = await db.from("app_users").select("*").eq("tg_id", myId).maybeSingle();
  if (lookup.error) {
    console.error("access lookup failed", { code: lookup.error.code, message: lookup.error.message });
    return json({ error: "db_lookup_failed" }, 500);
  }
  let me = lookup.data;
  if (!me && tg && BOOT_ADMINS.includes(myId)) {
    const name = [tg.first_name, tg.last_name].filter(Boolean).join(" ") || "Админ";
    const company = await db.from("app_companies").select("id").eq("slug", "podbor-demo").single();
    if (company.error) return json({ error: "db_bootstrap_failed" }, 500);
    const ins = await db.from("app_users").insert({ tg_id: myId, name, role: "admin", active: true, company_id: company.data.id }).select().single();
    if (ins.error) {
      console.error("admin bootstrap failed", { code: ins.error.code, message: ins.error.message });
      return json({ error: "db_bootstrap_failed" }, 500);
    }
    me = ins.data;
  }
  if (!me || !me.active) return json({ error: "no_access" }, 403);


  if (action === 'desktop.logout') {
    if (sessionHash) { const out = await db.from('desktop_sessions').delete().eq('token_hash', sessionHash).eq('user_id', myId); if (out.error) return json({ error: 'desktop_db' }, 500); }
    return json({ ok: true });
  }
  if (action === 'desktop.code') {
    if (!tg || !['admin','owner','manager'].includes(me.role)) return json({ error: 'forbidden' }, 403);
    const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    const code = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => alphabet[b & 31]).join('');
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    const removed = await db.from('desktop_login_codes').delete().eq('user_id', myId);
    if (removed.error) return json({ error: 'desktop_db' }, 500);
    const result = await db.from('desktop_login_codes').insert({ code_hash: await hashValue(code), user_id: myId, expires_at: expiresAt });
    if (result.error) return json({ error: 'desktop_db' }, 500);
    return json({ code: code.match(/.{4}/g)!.join('-'), expiresAt });
  }
  if (action?.startsWith('crm.')) {
    if (!['admin','owner','manager'].includes(me.role)) return json({ error: 'crm_forbidden' }, 403);
    if (action === 'crm.import') {
      const result = await db.rpc('crm_import_company', { p_actor: myId });
      return result.error ? crmError(result.error) : json({ imported: result.data });
    }
    if (action === 'crm.list') {
      const page = Number.isSafeInteger(p.page) && Number(p.page) >= 0 && Number(p.page) <= 10000 ? Number(p.page) : 0;
      const result = await db.rpc('crm_list_requests', { p_actor: myId, p_query: String(p.query ?? '').slice(0, 200), p_status: String(p.status ?? ''), p_assignee: String(p.assignee ?? ''), p_archived: p.archived === true, p_page: page });
      return result.error ? crmError(result.error) : json(result.data);
    }
    if (action === 'crm.save') {
      const id = p.id ? String(p.id) : null;
      if (id && (!/^[0-9a-f-]{36}$/i.test(id) || !Number.isSafeInteger(p.version) || Number(p.version) < 1)) return json({ error: 'crm_bad_data' }, 400);
      const data = crmData(p.data, !id);
      if (!data) return json({ error: 'crm_bad_data' }, 400);
      const result = await db.rpc('crm_save_request', { p_actor: myId, p_id: id, p_version: id ? Number(p.version) : 0, p_data: data });
      return result.error ? crmError(result.error) : json({ request: result.data });
    }
    if (action === 'crm.detail' || action === 'crm.comment') {
      const id = String(p.id ?? '');
      if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'crm_bad_data' }, 400);
      if (action === 'crm.comment') {
        const text = String(p.text ?? '').trim();
        if (!text || text.length > 4000) return json({ error: 'crm_bad_comment' }, 400);
        const result = await db.rpc('crm_add_comment', { p_actor: myId, p_id: id, p_text: text });
        return result.error ? crmError(result.error) : json({ activity: result.data });
      }
      const result = await db.rpc('crm_request_detail', { p_actor: myId, p_id: id });
      return result.error ? crmError(result.error) : json(result.data);
    }
    return json({ error: 'unknown_action' }, 400);
  }

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
      ? await db.from("user_workspaces").insert({ ...record, user_id: myId, source_company_id: me.company_id }).select("revision").single()
      : await db.from("user_workspaces").update(record).eq("user_id", myId).eq("revision", revision).select("revision").maybeSingle();
    if (result.error?.code === "23505" || (!result.error && !result.data)) return json({ error: "workspace_conflict" }, 409);
    if (result.error) return json({ error: "db_workspace_failed" }, 500);
    return json({ revision: result.data.revision });
  }

  const canManage = me.role === "admin" || me.role === "owner";
  if (!canManage) return json({ error: "forbidden" }, 403);

  if (action === "users.list") {
    const r = await db.from("app_users").select("*").eq("company_id", me.company_id).order("created_at");
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
    if (orig) {
      const target = await db.from('app_users').select('role,company_id').eq('tg_id', orig).eq('company_id', me.company_id).maybeSingle();
      if (target.error) return json({ error: 'db' }, 500);
      if (!target.data) return json({ error: 'crm_not_found' }, 404);
    }
    if (me.role !== "admin") {
      if (role === "admin") return json({ error: "forbidden" }, 403);
      if (orig) {
        const t = await db.from("app_users").select("role").eq("tg_id", orig).maybeSingle();
        if (t.data?.role === "admin") return json({ error: "forbidden" }, 403);
      }
    }
    if (orig === myId && (!active || role !== me.role || tgId !== myId)) return json({ error: "self" }, 400);
    if (!orig || orig !== tgId) {
      const ex = await db.from("app_users").select("tg_id").eq("tg_id", tgId).maybeSingle();
      if (ex.data) return json({ error: "exists" }, 409);
    }
    const r = orig
      ? await db.from("app_users").update({ tg_id: tgId, name, role, active }).eq("tg_id", orig).eq("company_id", me.company_id).select().single()
      : await db.from("app_users").insert({ tg_id: tgId, name, role, active, company_id: me.company_id }).select().single();
    if (r.error) return json({ error: "db", detail: r.error.message }, 500);
    return json({ user: r.data });
  }

  if (action === "users.delete") {
    const tgId = String(p.tg_id ?? "");
    if (tgId === myId) return json({ error: "self" }, 400);
    if (me.role !== "admin") {
      const t = await db.from("app_users").select("role").eq("tg_id", tgId).eq("company_id", me.company_id).maybeSingle();
      if (t.data?.role === "admin") return json({ error: "forbidden" }, 403);
    }
    const r = await db.from("app_users").delete().eq("tg_id", tgId).eq("company_id", me.company_id);
    if (r.error) return json({ error: "db", detail: r.error.message }, 500);
    return json({ ok: true });
  }

  return json({ error: "unknown_action" }, 400);
});
