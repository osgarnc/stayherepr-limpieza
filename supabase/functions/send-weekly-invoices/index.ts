// ============================================================
//  Supabase Edge Function: send-weekly-invoices
//  Junta los servicios/gastos APROBADOS que aun no se han
//  archivado, los agrupa por persona + semana, arma la factura
//  con su reporte de fotos y los envia por correo (Resend).
//  Al enviar con exito, marca esos envios como archivados.
//
//  Se ejecuta por horario (cron) o se puede invocar a mano.
//  Variables de entorno (secrets) que usa:
//    RESEND_API_KEY   (obligatoria)  - llave de Resend
//    MAIL_FROM        - remitente. Sin dominio propio usa: "Stay Here PR <onboarding@resend.dev>"
//    MAIL_TEST_TO     - si esta puesta, TODO se envia solo a este correo (modo prueba)
//    CRON_SECRET      - opcional; si esta, hay que mandar el header x-cron-secret igual
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

// Bisemanal: periodos de 14 dias (domingo->sabado) anclados a un domingo de inicio
const BIWEEK_ANCHOR = "2026-07-12"; // domingo, inicio de la 1a bisemana
function biweekKey(iso: string) {
  const anchor = new Date(BIWEEK_ANCHOR + "T00:00:00Z");
  const d = new Date(iso + "T00:00:00Z");
  const period = Math.floor((d.getTime() - anchor.getTime()) / (14 * 86400000));
  const start = new Date(anchor); start.setUTCDate(start.getUTCDate() + period * 14);
  return start.toISOString().slice(0, 10);
}
function biweekEnd(startISO: string) { const s = new Date(startISO + "T00:00:00Z"); s.setUTCDate(s.getUTCDate() + 13); return s.toISOString().slice(0, 10); }
function todayUTC() { return new Date().toISOString().slice(0, 10); }

async function signed(path: string | null) {
  if (!path) return null;
  const { data } = await sb.storage.from("evidence").createSignedUrl(path, 60 * 60 * 24 * 30); // 30 dias
  return data?.signedUrl ?? null;
}

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function jsonResp(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
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

    const { data: subs } = await sb.from("submissions").select("*").eq("status", "approved").is("archived_at", null);
    if (!subs || subs.length === 0) return jsonResp({ ok: true, sent: 0, msg: "No hay nada aprobado pendiente de enviar." });

    const { data: items } = await sb.from("submission_items").select("*").in("submission_id", subs.map((s: any) => s.id));
    const itemsBySub: Record<string, any[]> = {};
    (items ?? []).forEach((it: any) => { (itemsBySub[it.submission_id] ||= []).push(it); });

    // Enviar todo (manual) o solo bisemanas ya cerradas (automatico/cron)?
    let sendAll = false;
    try { const body = await req.json(); sendAll = !!(body && body.all === true); } catch (_) { /* sin body = automatico */ }

    // En modo automatico (cron cada hora), solo enviar en el dia+hora configurado (hora de PR, UTC-4)
    if (!sendAll) {
      const sendDow = Number(company?.send_dow ?? 0);   // 0=domingo
      const sendHour = Number(company?.send_hour ?? 9);  // 9am PR
      const pr = new Date(Date.now() - 4 * 3600 * 1000);
      if (pr.getUTCDay() !== sendDow || pr.getUTCHours() !== sendHour) {
        return jsonResp({ ok: true, sent: 0, msg: `No es el horario configurado (dia ${sendDow}, ${sendHour}h PR). Ahora en PR: dia ${pr.getUTCDay()}, ${pr.getUTCHours()}h.` });
      }
    }

    // Agrupar por persona + bisemana
    const groups: Record<string, any[]> = {};
    subs.forEach((s: any) => { const k = s.professional_id + "|" + biweekKey(s.date); (groups[k] ||= []).push(s); });

    let recipients = (dist ?? []).map((d: any) => d.email);
    if (MAIL_TEST_TO) recipients = [MAIL_TEST_TO];
    if (recipients.length === 0) return jsonResp({ ok: false, msg: "No hay correos activos en la lista de distribucion." });

    let sent = 0; const results: any[] = [];
    const today = todayUTC();
    for (const key of Object.keys(groups)) {
      const [pid, wk] = key.split("|");
      const end = biweekEnd(wk);
      // El automatico solo envia bisemanas ya cerradas (fin < hoy). El manual envia todo.
      if (!sendAll && end >= today) { results.push({ persona: proById(pid)?.name, bisemana: wk + " al " + end, ok: false, motivo: "bisemana en curso" }); continue; }
      const list = groups[key].sort((a: any, b: any) => (a.date < b.date ? -1 : 1));
      const pro = proById(pid);
      const html = await buildEmail(pro, wk, end, list, itemsBySub, company, propName);
      const subject = `Factura bisemanal ${pro?.name ?? ""} - ${wk} al ${end}`;
      const r = await sendEmail(recipients, subject, html);
      if (r.ok) {
        sent++;
        await sb.from("submissions").update({ archived_at: new Date().toISOString() }).in("id", list.map((s: any) => s.id));
      }
      results.push({ persona: pro?.name, bisemana: wk + " al " + end, ok: r.ok, error: r.error });
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

async function buildEmail(pro: any, wk: string, end: string, list: any[], itemsBySub: Record<string, any[]>, company: any, propName: (id: string) => string) {
  // ---- Servicios agrupados por PROPIEDAD (con subtotal por propiedad) ----
  const byProp: Record<string, { name: string; lines: any[]; subtotal: number }> = {};
  let servicesGross = 0;
  const expenses: any[] = [];
  let expensesTotal = 0;
  const svcExtra: any[] = [];

  for (const s of list) {
    if (s.type === "service") {
      for (const i of (itemsBySub[s.id] ?? [])) {
        const pid = i.property_id;
        const base = Number(i.rate_applied) || 0;
        const ex: string[] = [];
        if (Number(i.early_checkin) > 0) ex.push("Early Check-in " + money(Number(i.early_checkin)));
        if (Number(i.late_checkout) > 0) ex.push("Late Check-out " + money(Number(i.late_checkout)));
        if (Number(i.extra_guest) > 0) ex.push("Extra huesped " + money(Number(i.extra_guest)));
        if (Number(i.laundry) > 0) ex.push("Lavanderia " + money(Number(i.laundry)));
        const extras = (Number(i.early_checkin) || 0) + (Number(i.late_checkout) || 0) + (Number(i.extra_guest) || 0) + (Number(i.laundry) || 0);
        const tot = base + extras;
        servicesGross += tot;
        (byProp[pid] ??= { name: propName(pid), lines: [], subtotal: 0 });
        byProp[pid].lines.push({ date: s.date, ex, tot });
        byProp[pid].subtotal += tot;
      }
    } else if (s.custom_lines && Array.isArray(s.custom_lines.lines)) {
      // Factura libre: renglones "servicio" llevan retencion 10%; los demas son material (exento).
      for (const l of s.custom_lines.lines) {
        const amt = Number(l.amount) || 0;
        const ld = l.date || s.date;
        const lp = l.prop ? propName(l.prop) : "";
        if (l.svc) { servicesGross += amt; svcExtra.push({ date: ld, desc: l.desc, prop: lp, amount: amt }); }
        else { expensesTotal += amt; expenses.push({ date: ld, desc: l.desc, prop: lp, amount: amt }); }
      }
    } else {
      const g = Number(s.total) || 0; expensesTotal += g;
      expenses.push({ date: s.date, desc: s.expense_desc, prop: propName(s.property_id), amount: g });
    }
  }
  const tax = servicesGross * 0.10;
  const servicesNet = servicesGross - tax;
  const totalPay = servicesNet + expensesTotal;

  const propBlocks = Object.values(byProp).map((p) => {
    const rows = p.lines.map((l: any) =>
      `<tr><td style="padding:6px 8px;border-bottom:1px solid #eee">${esc(l.date)}${l.ex.length ? `<br><span style="color:#3A5249;font-size:11px">${esc(l.ex.join(", "))}</span>` : ""}</td><td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">${money(l.tot)}</td></tr>`
    ).join("");
    return `<div style="margin-bottom:12px"><div style="font-weight:bold;color:#12261F">${esc(p.name)}</div>` +
      `<table style="width:100%;border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px">${rows}` +
      `<tr><td style="padding:6px 8px;text-align:right;font-weight:bold">Subtotal ${esc(p.name)}</td><td style="padding:6px 8px;text-align:right;font-weight:bold">${money(p.subtotal)}</td></tr></table></div>`;
  }).join("");

  const svcExtraBlock = svcExtra.length
    ? `<h3 style="color:#0E7C7B;font-size:15px;margin:16px 0 6px">Otros servicios (con retenci&oacute;n)</h3>` +
      `<table style="width:100%;border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px">` +
      svcExtra.map((e: any) => `<tr><td style="padding:6px 8px;border-bottom:1px solid #eee">${esc(e.date)} - ${esc(e.desc)}${e.prop ? ` (${esc(e.prop)})` : ""}</td><td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">${money(e.amount)}</td></tr>`).join("") + `</table>`
    : "";

  const expBlock = expenses.length
    ? `<h3 style="color:#0E7C7B;font-size:15px;margin:16px 0 6px">Gastos reembolsables (sin descuento)</h3>` +
      `<table style="width:100%;border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px">` +
      expenses.map((e: any) => `<tr><td style="padding:6px 8px;border-bottom:1px solid #eee">${esc(e.date)} - ${esc(e.desc)}${e.prop ? ` (${esc(e.prop)})` : ""}</td><td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">${money(e.amount)}</td></tr>`).join("") +
      `<tr><td style="padding:6px 8px;text-align:right;font-weight:bold">Subtotal gastos</td><td style="padding:6px 8px;text-align:right;font-weight:bold">${money(expensesTotal)}</td></tr></table>`
    : "";

  const cards: string[] = [];
  for (const s of list) {
    if (s.type === "service") {
      for (const i of (itemsBySub[s.id] ?? [])) {
        const [b, a] = await Promise.all([signed(i.photo_before), signed(i.photo_after)]);
        cards.push(photoCard("Antes", propName(i.property_id), s.date, b));
        cards.push(photoCard("Despu&eacute;s", propName(i.property_id), s.date, a));
        const dmgPaths: string[] = (i.damage_photos && i.damage_photos.length) ? i.damage_photos : (i.damage_photo ? [i.damage_photo] : []);
        const dmgUrls = await Promise.all(dmgPaths.map((pth: string) => signed(pth)));
        dmgUrls.forEach((du, di) => cards.push(photoCard("Da&ntilde;o" + (dmgUrls.length > 1 ? " " + (di + 1) : "") + (i.damage_note ? ": " + esc(i.damage_note) : ""), propName(i.property_id), s.date, du)));
      }
    } else if (s.receipt_photo) {
      const r = await signed(s.receipt_photo);
      cards.push(photoCard("Recibo: " + esc(s.expense_desc), propName(s.property_id), s.date, r));
    }
  }

  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body style="margin:0;background:#fff">
    <div style="font-family:Georgia,serif;color:#12261F;max-width:660px;margin:auto;padding:16px">
    <h1 style="color:#0E7C7B;margin:0 0 4px">FACTURA BISEMANAL</h1>
    <div style="font-family:Arial,sans-serif;font-size:13px;color:#3A5249;margin-bottom:16px">Per&iacute;odo: ${wk} al ${end}</div>
    <table style="width:100%;font-family:Arial,sans-serif;font-size:13px;margin-bottom:16px"><tr>
      <td style="vertical-align:top;width:50%"><b>Contratista</b><br>${esc(pro?.name)}<br>${esc(pro?.address || "")}<br>Id. fiscal: ${esc(pro?.tax_id || "")}<br>${esc(pro?.email || "")}</td>
      <td style="vertical-align:top;width:50%"><b>Pagado por</b><br>${esc(company?.name || "")}<br>${esc(company?.address || "")}<br>EIN: ${esc(company?.ein || "")}</td>
    </tr></table>
    <h3 style="color:#0E7C7B;font-size:15px;margin:0 0 6px">Servicios por propiedad</h3>
    ${propBlocks || '<p style="color:#3A5249;font-family:Arial,sans-serif;font-size:13px">Sin servicios.</p>'}
    ${svcExtraBlock}
    ${expBlock}
    <table style="width:100%;font-family:Arial,sans-serif;font-size:14px;margin-top:16px;border-top:2px solid #12261F">
      <tr><td style="padding:6px 8px">Subtotal servicios (bruto)</td><td style="padding:6px 8px;text-align:right">${money(servicesGross)}</td></tr>
      <tr><td style="padding:6px 8px;color:#C0492E">Taxes (-10% sobre servicios)</td><td style="padding:6px 8px;text-align:right;color:#C0492E">-${money(tax)}</td></tr>
      <tr><td style="padding:6px 8px">Servicios netos</td><td style="padding:6px 8px;text-align:right">${money(servicesNet)}</td></tr>
      ${expensesTotal > 0 ? `<tr><td style="padding:6px 8px">Gastos reembolsables (completo)</td><td style="padding:6px 8px;text-align:right">${money(expensesTotal)}</td></tr>` : ""}
      <tr><td style="padding:10px 8px;font-size:19px;font-weight:bold;border-top:1px solid #ccc">TOTAL A PAGAR</td><td style="padding:10px 8px;text-align:right;font-size:19px;font-weight:bold;border-top:1px solid #ccc">${money(totalPay)}</td></tr>
    </table>
    <h2 style="color:#0E7C7B;font-size:18px;border-top:2px solid #E2D9C6;padding-top:16px;margin-top:20px">Reporte de fotos</h2>
    <div>${cards.join("") || '<p style="color:#3A5249">Sin fotos.</p>'}</div>
    <p style="color:#3A5249;font-family:Arial,sans-serif;font-size:11px;margin-top:20px">Stay Here PR - Servicios de limpieza. Cada foto documenta donde, cuando, quien y por que (antes, despues, dano o recibo).</p>
    </div></body></html>`;
}

function isVideoUrl(u: string) { return /\.(mp4|mov|webm|m4v|3gp|avi|mkv|quicktime)(\?|$)/i.test(u || ""); }
function photoCard(why: string, prop: string, date: string, url: string | null) {
  const img = !url
    ? `<div style="height:150px;background:#eee;border-radius:8px;text-align:center;line-height:150px;color:#999">Sin foto</div>`
    : isVideoUrl(url)
      ? `<a href="${url}" style="display:block;height:150px;background:#12261F;color:#fff;border-radius:8px;text-align:center;line-height:150px;text-decoration:none;font-weight:bold">&#127909; Ver video</a>`
      : `<img src="${url}" style="width:100%;height:150px;object-fit:cover;border-radius:8px">`;
  return `<div style="display:inline-block;width:180px;margin:6px;vertical-align:top;font-family:Arial,sans-serif;font-size:12px">
    ${img}<div style="font-weight:bold;margin-top:4px">${why}</div><div style="color:#3A5249">${esc(prop)} - ${esc(date)}</div></div>`;
}
