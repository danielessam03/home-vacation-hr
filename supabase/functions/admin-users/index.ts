// Supabase Edge Function: /admin-users
// The ONLY place a login is created or a password/email changed, for all
// three Home Vacation systems (HR, maintenance, CRM). Runs with the
// service-role key server-side; the browser never sees it.
//
//   create        { email, username, password, full_name_en, full_name_ar,
//                   role, branch_id, access_hr, access_maint, access_crm,
//                   employee_id }
//   set_password  { id, password }
//   set_email     { id, email }
//   set_enabled   { id, enabled }        -- whole unified login on/off
//
// Caller must be an active ceo/hr in app_users. HR may not touch CEO
// accounts; nobody can disable themselves.
//
// Deploy: supabase functions deploy admin-users --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

const USERNAME_RE = /^[A-Za-z0-9._-]{2,32}$/;
const ROLES = ["ceo", "hr", "accountant", "manager", "staff"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  /* ---- who is calling ---- */
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await userClient.auth.getUser();
  if (!u?.user) return json({ error: "unauthorized" }, 401);
  const { data: me } = await admin.from("app_users").select("id, role, is_active").eq("id", u.user.id).single();
  if (!me?.is_active || !["ceo", "hr"].includes(me.role)) return json({ error: "forbidden" }, 403);

  const targetId: string | undefined = body.id || body.user_id;
  const guardTarget = async () => {
    if (!targetId) return "id required";
    const { data: t } = await admin.from("app_users").select("id, role").eq("id", targetId).maybeSingle();
    if (!t) return "user not found";
    if (t.role === "ceo" && me.role !== "ceo") return "only a CEO can change a CEO account";
    return null;
  };

  /* ---------------- create ---------------- */
  if (body.action === "create") {
    const email = String(body.email || "").trim().toLowerCase();
    const username = String(body.username || "").trim();
    const password = String(body.password || "");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "valid email required" }, 400);
    if (!USERNAME_RE.test(username)) return json({ error: "username: letters, numbers, dot, dash or underscore (2-32)" }, 400);
    if (password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
    const role = ROLES.includes(body.role) ? body.role : "staff";
    if (role === "ceo" && me.role !== "ceo") return json({ error: "only a CEO can create a CEO account" }, 403);
    const { data: clash } = await admin.from("app_users").select("id").ilike("username", username).maybeSingle();
    if (clash) return json({ error: "username already taken" }, 409);

    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { full_name_en: body.full_name_en || null, full_name_ar: body.full_name_ar || null },
    });
    if (cErr || !created?.user) return json({ error: cErr?.message || "create failed" }, 400);
    const uid = created.user.id;

    // the auth trigger created the app_users row; now apply what HR chose
    const patch = {
      username, role, branch_id: body.branch_id || null,
      full_name_en: body.full_name_en || null, full_name_ar: body.full_name_ar || null,
      access_hr: body.access_hr !== false, access_maint: !!body.access_maint, access_crm: !!body.access_crm,
    };
    let { data: row, error: uErr } = await admin.from("app_users").update(patch).eq("id", uid).select().single();
    if (uErr) {
      // trigger may not have fired yet (should not happen, but never leave a half account)
      const ins = await admin.from("app_users").insert({ id: uid, email, ...patch }).select().single();
      row = ins.data; uErr = ins.error;
    }
    if (uErr) return json({ error: uErr.message }, 400);
    if (body.employee_id) {
      await admin.from("employees").update({ user_id: uid }).eq("id", body.employee_id).is("user_id", null);
    }
    return json({ ok: true, user: row });
  }

  /* ---------------- set_password ---------------- */
  if (body.action === "set_password") {
    const g = await guardTarget(); if (g) return json({ error: g }, 400);
    const password = String(body.password || "");
    if (password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
    const { error } = await admin.auth.admin.updateUserById(targetId!, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  /* ---------------- set_email ---------------- */
  if (body.action === "set_email") {
    const g = await guardTarget(); if (g) return json({ error: g }, 400);
    const email = String(body.email || "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "valid email required" }, 400);
    const { error } = await admin.auth.admin.updateUserById(targetId!, { email, email_confirm: true });
    if (error) return json({ error: error.message }, 400);
    const { data: row, error: e2 } = await admin.from("app_users").update({ email }).eq("id", targetId!).select().single();
    if (e2) return json({ error: e2.message }, 400);
    await admin.from("hv_users").update({ email }).eq("auth_user_id", targetId!);
    return json({ ok: true, user: row });
  }

  /* ---------------- set_enabled ---------------- */
  if (body.action === "set_enabled") {
    const g = await guardTarget(); if (g) return json({ error: g }, 400);
    if (targetId === me.id) return json({ error: "you cannot disable yourself" }, 400);
    const enabled = !!body.enabled;
    const { data: row, error } = await admin.from("app_users").update({ is_active: enabled }).eq("id", targetId!).select().single();
    if (error) return json({ error: error.message }, 400);
    // the per-system rows follow the master switch
    if (enabled) {
      await admin.from("hv_users").update({ is_active: !!row.access_maint }).eq("auth_user_id", targetId!);
      await admin.from("profiles").update({ is_active: !!row.access_crm }).eq("id", targetId!);
    } else {
      await admin.from("hv_users").update({ is_active: false }).eq("auth_user_id", targetId!);
      await admin.from("profiles").update({ is_active: false }).eq("id", targetId!);
    }
    return json({ ok: true, user: row });
  }

  return json({ error: "unknown action" }, 400);
});
