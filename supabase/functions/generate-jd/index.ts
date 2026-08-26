// Supabase Edge Function: /generate-jd
// Generates professional job descriptions and offer letters with Claude,
// tailored to the Egyptian real-estate market. Only ceo/hr may call it.
//
// Deploy (Supabase Dashboard): Edge Functions -> Deploy new function ->
// name it exactly  generate-jd  -> paste this file -> Deploy.
// Secrets required on the function:
//   ANTHROPIC_API_KEY  -> from console.anthropic.com -> API keys

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: cors });
  }

  // ---- authenticate the caller and require ceo/hr --------------------
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: cors });
  }
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: profile } = await admin
    .from("app_users").select("role, is_active").eq("id", userData.user.id).single();
  if (!profile?.is_active || !["ceo", "hr"].includes(profile.role)) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: cors });
  }

  // ---- input ---------------------------------------------------------
  const { role, kind, language, candidate_name, custom_notes, company } = await req.json();
  if (!role?.title_en) {
    return new Response(JSON.stringify({ error: "role required" }), { status: 400, headers: cors });
  }

  const langLine =
    language === "ar" ? "Write the document in Arabic only."
    : language === "en" ? "Write the document in English only."
    : "Write the document twice: first the full Arabic version, then a horizontal rule (---), then the full English version.";

  const kindLine = kind === "offer"
    ? `Produce a formal JOB OFFER LETTER addressed to the candidate${candidate_name ? ` (${candidate_name})` : ""}, ready to print on company letterhead: position, start terms, compensation, schedule, probation period per Egyptian labor law, required documents checklist, validity of the offer, and signature blocks for the company and the candidate.`
    : "Produce a complete professional JOB DESCRIPTION: role summary, key responsibilities (bulleted), qualifications, working schedule, compensation summary, reporting line, KPIs relevant to the role, and the required hiring documents checklist.";

  const system = `You are the senior HR consultant of "${company?.name_en ?? "Home Vacation"}" (${company?.name_ar ?? "هوم فاكيشن"}), a real-estate brokerage and investment company in Hurghada, Red Sea, Egypt.
You write flawless, professional HR documents for the Egyptian market: correct formal Arabic (فصحى معاصرة مناسبة للمستندات الرسمية) and clean business English.
Ground everything in Egyptian labor law (Law 14/2025 and its predecessors) without inventing article numbers: standard probation up to 3 months, annual leave entitlements, social insurance registration, and the customary hiring paperwork.
Output pure Markdown only: headings with #/##, bullet lists with -, horizontal rules with ---. No HTML, no code fences, no commentary about the task itself. Start directly with the document title.`;

  const userMsg = `${kindLine}
${langLine}

Role data (use it faithfully; do not invent salary figures beyond what is given):
- Title: ${role.title_en} / ${role.title_ar}
- Duties & scope notes: ${role.duties || "-"}
- Requirements notes: ${role.requirements || "-"}
- Salary: ${role.salary_note || "per company scale (do not state a number)"}
- Commission: ${role.commission_note || "-"}
- Benefits: ${role.benefits || "-"}
- Default schedule: ${role.schedule_note || "per company work week"}
- Required hiring papers: ${(role.papers || []).join("; ") || "standard Egyptian hiring file"}
${custom_notes ? `\nCustom terms for this specific ${kind === "offer" ? "candidate" : "position"} (these OVERRIDE the defaults above where they conflict): ${custom_notes}` : ""}`;

  // ---- Claude --------------------------------------------------------
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  let response;
  try {
    response = await anthropic.beta.messages.create({
      model: "claude-opus-5",
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system,
      messages: [{ role: "user", content: userMsg }],
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: "AI error: " + (e as Error).message }), { status: 500, headers: cors });
  }

  if (response.stop_reason === "refusal") {
    return new Response(JSON.stringify({ error: "The AI declined this request. Rephrase the notes and try again." }), { status: 422, headers: cors });
  }

  const content = response.content
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("\n");

  return new Response(JSON.stringify({ content_md: content }), {
    headers: { ...cors, "content-type": "application/json" },
  });
});
