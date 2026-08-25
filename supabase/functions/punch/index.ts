// Supabase Edge Function: /punch
// Receives attendance punches from the ZKTeco bridge (bridge.py),
// secured by a shared secret, resolves employees by device code,
// and inserts with dedupe (same code + time + device is ignored).
//
// Deploy (Supabase Dashboard): Edge Functions -> Deploy new function ->
// name it exactly  punch  -> paste this file -> Deploy.
// Then: Edge Functions -> punch -> Secrets -> add PUNCH_SECRET with a
// long random value (same value goes into bridge.py).

import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }
  if (req.headers.get("x-punch-secret") !== Deno.env.get("PUNCH_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }

  let body: { punches?: unknown[] };
  try {
    body = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }
  const punches = (body.punches ?? []) as {
    employee_device_code: string;
    punch_time: string; // ISO 8601 with timezone
    direction?: string;
    device_id?: string;
  }[];
  if (!punches.length) {
    return new Response(JSON.stringify({ ok: true, received: 0 }), {
      headers: { "content-type": "application/json" },
    });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // resolve device codes -> employee ids
  const codes = [...new Set(punches.map((p) => String(p.employee_device_code)))];
  const { data: emps, error: empErr } = await sb
    .from("employees")
    .select("id, device_code")
    .in("device_code", codes);
  if (empErr) {
    return new Response(JSON.stringify({ error: empErr.message }), { status: 500 });
  }
  const byCode = Object.fromEntries((emps ?? []).map((e) => [e.device_code, e.id]));

  const rows = punches.map((p) => ({
    employee_id: byCode[String(p.employee_device_code)] ?? null,
    employee_device_code: String(p.employee_device_code),
    punch_time: p.punch_time,
    direction: ["in", "out"].includes(p.direction ?? "") ? p.direction : "unknown",
    device_id: p.device_id ?? "tx628",
    source: "bridge",
  }));

  const { error } = await sb
    .from("attendance_punches")
    .upsert(rows, {
      onConflict: "employee_device_code,punch_time,device_id",
      ignoreDuplicates: true,
    });
  if (error) {
    // a locked month raises ATTENDANCE_LOCKED from the trigger
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  const unknown = rows.filter((r) => !r.employee_id).length;
  return new Response(
    JSON.stringify({ ok: true, received: rows.length, unmatched_codes: unknown }),
    { headers: { "content-type": "application/json" } },
  );
});
