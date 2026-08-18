// ============================================================================
// Edge Function: ops-owner-report   (verify_jwt=true)  — FASE 4
//
// Reporte de fin de mes por DUEÑO, para el mes dado (YYYY-MM):
//   - Estadías con CHECK-IN en el mes (por propiedad asignada a un dueño).
//   - COMPLETO: une reservas de Hostfully (/leads) + ops_reservations_ledger (durable,
//     lo llena el webhook/cron y NUNCA se purga) para no perder reservas de canal
//     (Booking.com/iCal, ej. Dario) que ya hicieron check-out.
//   - Ingreso = renta (getInvoiceData.rent). Comisión = renta * %propiedad.
//   - AIRBNB no cuadra comisión (Airbnb paga directo). No suma al pago.
//   - REFUNDS: ajustes negativos de la orden (informativos, no se restan solos).
//   - CANCELACIONES: de ops_cancellations (las registra el sync al detectarlas).
//   - Pago por propiedad = Σ(renta − comisión, no Airbnb) − gastos FACTURABLES.
// Solo lectura de Hostfully.
// ============================================================================

import { createDbClient } from "../_shared/db.ts";
import { HostfullyClient } from "../_shared/hostfully.ts";
import { env } from "../_shared/run.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const r2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { month } = await req.json().catch(() => ({})) as { month?: string };
    if (!/^\d{4}-\d{2}$/.test(month || "")) return json({ ok: false, error: "month inválido (YYYY-MM)" }, 400);
    const [y, m] = (month as string).split("-").map(Number);
    const monthStart = `${month}-01`;
    const nextStart = (m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, "0")}`) + "-01";

    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    const hostfully = new HostfullyClient({ apiKey: env("HOSTFULLY_API_KEY"), baseUrl: env("HOSTFULLY_BASE_URL") });

    const [poRes, ownRes, propRes, expRes, resvRes, cancRes] = await Promise.all([
      db.from("ops_property_owner").select("property_id,owner_id,commission_pct"),
      db.from("ops_owners").select("id,name"),
      db.from("ops_properties").select("id,name,hostfully_uid").not("hostfully_uid", "is", null),
      db.from("ops_property_expenses").select("*").gte("date", monthStart).lt("date", nextStart),
      db.from("ops_reservations_ledger").select("property_id,lead_uid,guest_name,source,check_in").gte("check_in", monthStart).lt("check_in", nextStart),
      db.from("ops_cancellations").select("*").gte("check_in", monthStart).lt("check_in", nextStart),
    ]);

    const ownerName: Record<string, string> = {};
    (ownRes.data ?? []).forEach((o: any) => ownerName[o.id] = o.name);
    const propMap: Record<string, any> = {};
    (propRes.data ?? []).forEach((p: any) => propMap[p.id] = p);
    const assign: Record<string, { owner_id: string; commission_pct: number }> = {};
    (poRes.data ?? []).forEach((a: any) => { if (a.owner_id) assign[a.property_id] = { owner_id: a.owner_id, commission_pct: Number(a.commission_pct) || 0 }; });
    const expByProp: Record<string, any[]> = {};
    (expRes.data ?? []).forEach((e: any) => { (expByProp[e.property_id] ||= []).push(e); });
    const resvByProp: Record<string, any[]> = {};
    (resvRes.data ?? []).forEach((r: any) => { (resvByProp[r.property_id] ||= []).push(r); });
    const cancByProp: Record<string, any[]> = {};
    (cancRes.data ?? []).forEach((c: any) => { (cancByProp[c.property_id] ||= []).push(c); });

    const assignedPropIds = Object.keys(assign).filter((pid) => propMap[pid]);

    const propResults = await Promise.all(assignedPropIds.map(async (pid) => {
      const p = propMap[pid]; const a = assign[pid];

      // Candidatos: uids de /leads UNIDOS con los de ops_reservations (canal).
      let leads: Awaited<ReturnType<HostfullyClient["listBookedLeads"]>> = [];
      try { leads = await hostfully.listBookedLeads(p.hostfully_uid); } catch { /* skip */ }
      const cand = new Map<string, string>(); // lead_uid -> check-in aprox (YYYY-MM-DD)
      leads.forEach((l) => cand.set(l.uid, (l.checkInISO || "").slice(0, 10)));
      (resvByProp[pid] ?? []).forEach((r: any) => { if (r.lead_uid && !cand.has(r.lead_uid)) cand.set(r.lead_uid, String(r.check_in ?? "")); });
      const uids = [...cand.entries()].filter(([, ci]) => (ci || "").slice(0, 7) === month).map(([uid]) => uid);

      const stays = await Promise.all(uids.map(async (uid) => {
        let rent = 0, guest = "", ci = cand.get(uid) || "", co = "", channel = "";
        const refunds: { type: string; amount: number }[] = [];
        try {
          const inv = await hostfully.getInvoiceData(uid);
          if (inv) {
            rent = inv.rent || 0; guest = inv.guestFullName || ""; channel = inv.channel || "";
            ci = (inv.checkInISO || ci).slice(0, 10); co = (inv.checkOutISO || "").slice(0, 10);
            (inv.adjustments ?? []).forEach((adj: any) => { if (Number(adj.amount) < 0) refunds.push({ type: String(adj.type || "AJUSTE"), amount: r2(adj.amount) }); });
          }
        } catch { /* keep */ }
        if ((ci || "").slice(0, 7) !== month) return null; // por si getInvoiceData corrigió la fecha fuera del mes
        const airbnb = /airbnb/i.test(channel);
        const commission = airbnb ? 0 : rent * (a.commission_pct / 100);
        const net = airbnb ? 0 : rent - commission;
        const refund = r2(Math.abs(refunds.reduce((s, x) => s + x.amount, 0)));
        return { guest: guest || "—", check_in: ci, check_out: co, channel, airbnb, rent: r2(rent), commission: r2(commission), net: r2(net), refund, refunds };
      }));
      const rows = stays.filter(Boolean) as any[];

      const staysRent = rows.filter((s) => !s.airbnb).reduce((s, x) => s + x.rent, 0);
      const staysComm = rows.reduce((s, x) => s + x.commission, 0);
      const staysNet = rows.reduce((s, x) => s + x.net, 0);
      const refundsTotal = rows.reduce((s, x) => s + (x.refund || 0), 0);
      const exps = (expByProp[pid] ?? []).map((e: any) => ({ date: e.date, description: e.description, amount: Number(e.amount) || 0, billable: !!e.billable }));
      const billableExp = exps.filter((e) => e.billable).reduce((s, e) => s + e.amount, 0);
      const cancellations = (cancByProp[pid] ?? []).map((c: any) => ({ guest: c.guest_name || "—", check_in: c.check_in, check_out: c.check_out, source: c.source, status: c.status }));
      return {
        owner_id: a.owner_id, property_name: p.name, commission_pct: a.commission_pct,
        stays: rows, stays_rent: r2(staysRent), stays_commission: r2(staysComm), stays_net: r2(staysNet),
        refunds_total: r2(refundsTotal), expenses: exps, billable_expense: r2(billableExp),
        cancellations, payout: r2(staysNet - billableExp),
      };
    }));

    const byOwner: Record<string, any[]> = {};
    propResults.forEach((pr) => { (byOwner[pr.owner_id] ||= []).push(pr); });
    const owners = Object.keys(byOwner).map((oid) => {
      const props = byOwner[oid].sort((a, b) => a.property_name < b.property_name ? -1 : 1);
      return { name: ownerName[oid] || "—", properties: props, total_payout: r2(props.reduce((s, p) => s + p.payout, 0)) };
    }).sort((a, b) => a.name < b.name ? -1 : 1);

    return json({ ok: true, month, owners });
  } catch (err) {
    console.error("ops-owner-report error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
