// ============================================================
//  Supabase Edge Function: send-weekly-invoices
//  Junta los servicios/gastos APROBADOS que aún no se han
//  archivado, los agrupa por persona + semana, arma la factura
//  con su reporte de fotos y los envía por correo (Resend).
//  Al enviar con éxito, marca esos envíos como archivados.
//
//  Se ejecuta por horario (cron) o se puede invocar a mano.
//  Variables de entorno (secrets) que usa:
//    RESEND_API_KEY   (obligatoria)  — llave de Resend
//    MAIL_FROM        — remitente. Sin dominio propio usa: "Stay Here PR <onboarding@resend.dev>"
//    MAIL_TEST_TO     — si está puesta, TODO se envía solo a este correo (modo prueba)
//    CRON_SECRET      — opcional; si está, hay que mandar el header x-cron-secret igual
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const MAIL_FROM      = Deno.env.get("MAIL_FROM") ?? "Stay Here PR <onboarding@resend.dev>";
const MAIL_TEST_TO   = Deno.env.get("MAIL_TEST_TO") ?? "";
const CRON_SECRET    = Deno.env.get("CRON_SECRET") ?? "";

const sb = createClient(SUPABASE_URL, SERVICE_KEY);

const money = (n: number) => "$" + Number(n || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const esc = (x: unknown) => String(x ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");

// Semana configurable: empieza el día "ws" (0=domingo … 6=sábado) y dura 7 días
function weekKey(iso: string, ws: number) { const d = new Date(iso + "T00:00:00Z"); const day = (d.getUTCDay() - ws + 7) % 7; d.setUTCDate(d.getUTCDate() - day); return d.toISOString().slice(0, 10); }
function weekEnd(mon: string) { const s = new Date(mon + "T00:00:00Z"); s.setUTCDate(s.getUTCDate() + 6); return s.toISOString().slice(0, 10); }

async function signed(path: string | null) {
  if (!path) return null;
  const { data } = await sb.storage.from("evidence").createSignedUrl(path, 60 * 60 * 24 * 30); // 30 días
  return data?.signedUrl ?? null;
}

function jsonResp(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  try {
    if (CRON_SECRET && req.headers.get("x-cron-secret") !== CRON_SECRET) {
      return jsonResp({ ok: false, error: "No autorizado" }, 401);
    }

    const [{ data: company }, { data: dist }, { data: props }, { data: pros }] = await Promise.all([
      sb.from("company_settings").select("*").eq("id", 1).maybeSingle(),
      sb.from("distribution").select("*").eq("active", true),
      sb.from("properties").select("id,name"),
      sb.from("professionals").select("*"),
    ]);
    const propName = (id: string) => (props ?? []).find((p: any) => p.id === id)?.name ?? id;
    const proById = (id: string) => (pros ?? []).find((p: any) => p.id === id);

    const { data: subs, error: subsErr } = await sb.from("submissions").select("*").eq("status", "approved").is("archived_at", null);
    if (!subs || subs.length === 0) return jsonResp({
      ok: true, sent: 0, msg: "No hay nada aprobado pendiente de enviar.",
      debug: { serviceKeyLen: (SERVICE_KEY || "").length, url: SUPABASE_URL, subsErr: subsErr?.message ?? null, subsCount: subs?.length ?? null },
    });

    const { data: items } = await sb.from("submission_items").select("*").in("submission_id", subs.map((s: any) => s.id));
    const itemsBySub: Record<string, any[]> = {};
    (items ?? []).forEach((it: any) => { (itemsBySub[it.submission_id] ||= []).push(it); });

    // Agrupar por persona + semana (según el día de inicio configurado)
    const ws = Number(company?.week_start_day ?? 1);
    const groups: Record<string, any[]> = {};
    subs.forEach((s: any) => { const k = s.professional_id + "|" + weekKey(s.date, ws); (groups[k] ||= []).push(s); });

    let recipients = (dist ?? []).map((d: any) => d.email);
    if (MAIL_TEST_TO) recipients = [MAIL_TEST_TO];
    if (recipients.length === 0) return jsonResp({ ok: false, msg: "No hay correos activos en la lista de distribución." });

    let sent = 0; const results: any[] = [];
    for (const key of Object.keys(groups)) {
      const [pid, wk] = key.split("|");
      const list = groups[key].sort((a: any, b: any) => (a.date < b.date ? -1 : 1));
      const pro = proById(pid);
      const html = await buildEmail(pro, wk, list, itemsBySub, company, propName);
      const subject = `Factura ${pro?.name ?? ""} - Semana ${wk} al ${weekEnd(wk)}`;
      const r = await sendEmail(recipients, subject, html);
      if (r.ok) {
        sent++;
        await sb.from("submissions").update({ archived_at: new Date().toISOString() }).in("id", list.map((s: any) => s.id));
      }
      results.push({ persona: pro?.name, semana: wk, ok: r.ok, error: r.error });
    }
    return jsonResp({ ok: true, enviadas: sent, grupos: Object.keys(groups).length, results });
  } catch (e) {
    return jsonResp({ ok: false, error: String(e) }, 500);
  }
});

async function sendEmail(to: string[], subject: string, html: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: MAIL_FROM, to, subject, html }),
  });
  if (res.ok) return { ok: true };
  return { ok: false, error: await res.text() };
}

async function buildEmail(pro: any, wk: string, list: any[], itemsBySub: Record<string, any[]>, company: any, propName: (id: string) => string) {
  let svc = 0, exp = 0;
  const rows = list.map((s: any) => {
    if (s.type === "service") {
      svc += Number(s.total);
      const names = (itemsBySub[s.id] ?? []).map((i: any) => propName(i.property_id)).join(", ");
      const ex: string[] = [];
      (itemsBySub[s.id] ?? []).forEach((i: any) => {
        if (Number(i.early_checkin) > 0) ex.push("Early Check-in");
        if (Number(i.late_checkout) > 0) ex.push("Late Check-out");
        if (Number(i.extra_guest) > 0) ex.push("Extra huésped");
      });
      const exLine = ex.length ? `<br><span style="color:#3A5249;font-size:11px">Cargos: ${esc(ex.join(", "))}</span>` : "";
      return `<tr><td style="padding:8px;border-bottom:1px solid #E2D9C6">${esc(s.date)}</td><td style="padding:8px;border-bottom:1px solid #E2D9C6">Servicio de limpieza - ${esc(names)}${exLine}</td><td style="padding:8px;border-bottom:1px solid #E2D9C6;text-align:right">${money(s.total)}</td></tr>`;
    }
    exp += Number(s.total);
    return `<tr><td style="padding:8px;border-bottom:1px solid #E2D9C6">${esc(s.date)}</td><td style="padding:8px;border-bottom:1px solid #E2D9C6">Reembolso - ${esc(s.expense_desc)} (${esc(propName(s.property_id))})</td><td style="padding:8px;border-bottom:1px solid #E2D9C6;text-align:right">${money(s.total)}</td></tr>`;
  }).join("");
  const total = svc + exp;

  const cards: string[] = [];
  for (const s of list) {
    if (s.type === "service") {
      for (const i of (itemsBySub[s.id] ?? [])) {
        const [b, a, d] = await Promise.all([signed(i.photo_before), signed(i.photo_after), signed(i.damage_photo)]);
        cards.push(photoCard("Antes", propName(i.property_id), s.date, b));
        cards.push(photoCard("Después", propName(i.property_id), s.date, a));
        if (i.damage_note) cards.push(photoCard("Daño: " + esc(i.damage_note), propName(i.property_id), s.date, d));
      }
    } else {
      const r = await signed(s.receipt_photo);
      cards.push(photoCard("Recibo: " + esc(s.expense_desc), propName(s.property_id), s.date, r));
    }
  }

  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body style="margin:0;background:#fff">
    <div style="font-family:Georgia,serif;color:#12261F;max-width:660px;margin:auto;padding:16px">
    <h1 style="color:#0E7C7B;margin:0 0 4px">FACTURA</h1>
    <div style="font-family:Arial,sans-serif;font-size:13px;color:#3A5249;margin-bottom:16px">Período: ${wk} al ${weekEnd(wk)}</div>
    <table style="width:100%;font-family:Arial,sans-serif;font-size:13px;margin-bottom:16px"><tr>
      <td style="vertical-align:top;width:50%"><b>Emisor</b><br>${esc(pro?.name)}<br>${esc(pro?.address || "")}<br>Id. fiscal: ${esc(pro?.tax_id || "")}<br>${esc(pro?.email || "")}</td>
      <td style="vertical-align:top;width:50%"><b>Facturar a</b><br>${esc(company?.name || "")}<br>${esc(company?.address || "")}<br>EIN: ${esc(company?.ein || "")}</td>
    </tr></table>
    <table style="width:100%;border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px">
      <thead><tr style="background:#12261F;color:#fff"><th style="text-align:left;padding:8px">Fecha</th><th style="text-align:left;padding:8px">Descripción</th><th style="text-align:right;padding:8px">Monto</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p style="text-align:right;font-family:Arial,sans-serif;font-size:14px">Servicios: ${money(svc)} &nbsp;&nbsp; Gastos: ${money(exp)}<br>
      <b style="font-size:20px">TOTAL A PAGAR: ${money(total)}</b></p>
    <h2 style="color:#0E7C7B;font-size:18px;border-top:2px solid #E2D9C6;padding-top:16px">Reporte de fotos</h2>
    <div>${cards.join("") || '<p style="color:#3A5249">Sin fotos.</p>'}</div>
    <p style="color:#3A5249;font-family:Arial,sans-serif;font-size:11px;margin-top:20px">Stay Here PR - Servicios de limpieza. Cada foto documenta donde, cuando, quien y por que (antes, despues, dano o recibo).</p>
    </div></body></html>`;
}

function photoCard(why: string, prop: string, date: string, url: string | null) {
  const img = url
    ? `<img src="${url}" style="width:100%;height:150px;object-fit:cover;border-radius:8px">`
    : `<div style="height:150px;background:#eee;border-radius:8px;text-align:center;line-height:150px;color:#999">Sin foto</div>`;
  return `<div style="display:inline-block;width:180px;margin:6px;vertical-align:top;font-family:Arial,sans-serif;font-size:12px">
    ${img}<div style="font-weight:bold;margin-top:4px">${why}</div><div style="color:#3A5249">${esc(prop)} - ${esc(date)}</div></div>`;
}
