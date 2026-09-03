// Supabase Edge Function: /presence
// Three jobs, all server-side so nothing can be forged from the browser:
//   1. agent heartbeat  -- laptop agent reports real system idle time
//      (auth: x-agent-token = employees.agent_token)
//   2. verify           -- employee answers a "still working?" challenge
//      with a fresh face descriptor; compared here against the enrolled
//      reference (which the employee can never read)
//   3. enroll           -- ceo/hr store an employee's reference face
//
// Deploy: supabase functions deploy presence --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-agent-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

const dist = (a: number[], b: number[]) => Math.sqrt(a.reduce((s, v, i) => s + (v - b[i]) ** 2, 0));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  /* ---------------- 1. laptop agent heartbeat ---------------- */
  const agentToken = req.headers.get("x-agent-token");
  if (agentToken) {
    const { data: emp } = await admin.from("employees").select("id, status").eq("agent_token", agentToken).maybeSingle();
    if (!emp || emp.status !== "active") return json({ error: "unknown agent" }, 403);
    const idle = Math.max(0, Number(body.idle_seconds) || 0);
    const { data: ses } = await admin.from("work_sessions").select("*").eq("employee_id", emp.id)
      .neq("status", "ended").order("started_at", { ascending: false }).limit(1).maybeSingle();
    if (!ses) return json({ ok: true, session: null });
    const now = Date.now();
    const lastAct = new Date(now - idle * 1000).toISOString();
    const patch: Record<string, unknown> = { agent_seen_at: new Date(now).toISOString(), last_heartbeat_at: new Date(now).toISOString() };
    // the agent can only push last_activity forward, never back
    if (new Date(lastAct) > new Date(ses.last_activity_at)) patch.last_activity_at = lastAct;
    await admin.from("work_sessions").update(patch).eq("id", ses.id);
    return json({ ok: true, session: ses.id, status: ses.status, idle_seconds: idle });
  }

  /* ---------------- user-authenticated actions ---------------- */
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await userClient.auth.getUser();
  if (!u?.user) return json({ error: "unauthorized" }, 401);
  const { data: me } = await admin.from("app_users").select("id, role, is_active").eq("id", u.user.id).single();
  if (!me?.is_active) return json({ error: "forbidden" }, 403);

  if (body.action === "enroll") {
    if (!["ceo", "hr"].includes(me.role)) return json({ error: "forbidden" }, 403);
    const samples: number[][] = (body.descriptors || []).filter((d: unknown) => Array.isArray(d) && d.length === 128);
    if (!samples.length || !body.employee_id) return json({ error: "descriptors required" }, 400);
    const avg = samples[0].map((_, i) => samples.reduce((s, d) => s + d[i], 0) / samples.length);
    const { error } = await admin.from("face_enrollments").upsert({
      employee_id: body.employee_id, descriptor: avg, samples: samples.length,
      enrolled_by: me.id, enrolled_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, samples: samples.length });
  }

  if (body.action === "verify") {
    const { data: emp } = await admin.from("employees").select("id").eq("user_id", me.id).maybeSingle();
    if (!emp) return json({ error: "no employee record" }, 400);
    const desc: number[] = body.descriptor;
    if (!Array.isArray(desc) || desc.length !== 128) return json({ error: "descriptor required" }, 400);
    const { data: ref } = await admin.from("face_enrollments").select("descriptor").eq("employee_id", emp.id).maybeSingle();
    if (!ref) return json({ error: "not_enrolled" }, 409);
    const { data: policy } = await admin.from("app_settings").select("value").eq("key", "presence_policy").maybeSingle();
    const threshold = Number(policy?.value?.face_threshold) || 0.5;
    const d = dist(desc, ref.descriptor as number[]);
    const ok = d <= threshold;
    const now = new Date().toISOString();

    let challengeId = body.challenge_id as string | undefined;
    if (challengeId) {
      const { data: ch } = await admin.from("presence_challenges").select("*").eq("id", challengeId).eq("employee_id", emp.id).maybeSingle();
      if (!ch) return json({ error: "challenge not found" }, 404);
      await admin.from("presence_challenges").update({
        attempts: (ch.attempts || 0) + 1, face_distance: d,
        ...(ok ? { answered_at: now, answered_via: body.via === "phone" ? "phone" : "laptop", result: "confirmed" } : {}),
      }).eq("id", ch.id);
    }

    const { data: ses } = await admin.from("work_sessions").select("*").eq("employee_id", emp.id)
      .neq("status", "ended").order("started_at", { ascending: false }).limit(1).maybeSingle();
    if (ses) {
      await admin.from("session_events").insert({ session_id: ses.id, employee_id: emp.id, kind: ok ? "confirm" : "face_fail", meta: { distance: d, via: body.via || "laptop", challenge_id: challengeId || null } });
      if (ok) {
        const patch: Record<string, unknown> = { last_activity_at: now, last_heartbeat_at: now, status: "working", break_started_at: null };
        if (ses.status === "break" && ses.break_started_at) {
          patch.break_seconds = (ses.break_seconds || 0) + Math.round((Date.now() - new Date(ses.break_started_at).getTime()) / 1000);
          await admin.from("session_events").insert({ session_id: ses.id, employee_id: emp.id, kind: "break_end", meta: { via: body.via || "laptop" } });
        }
        await admin.from("work_sessions").update(patch).eq("id", ses.id);
      }
    }
    return json({ ok, distance: Number(d.toFixed(4)), threshold });
  }

  return json({ error: "unknown action" }, 400);
});
