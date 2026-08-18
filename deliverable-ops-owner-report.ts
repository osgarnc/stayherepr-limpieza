// ============================================================================
// Edge Function: ops-owner-report   (verify_jwt=true)
//
// Reporte de fin de mes por DUEÑO. Para el mes dado (YYYY-MM):
//   - Estadías con CHECK-IN en el mes, por propiedad asignada a un dueño.
//   - Ingreso = renta (Hostfully getInvoiceData.rent). Comisión = renta * %propiedad.
//   - Pago por propiedad = Σ(renta − comisión) − gastos FACTURABLES del mes.
//   - Pago al dueño = Σ pagos de sus propiedades.
// Solo lectura de Hostfully. Cancelaciones/refunds llegan en Fase 4.
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

    const [poRes, ownRes, propRes, expRes] = await Promise.all([
      db.from("ops_property_owner").select("property_id,owner_id,commission_pct"),
      db.from("ops_owners").select("id,name"),
      db.from("ops_properties").select("id,name,hostfully_uid").not("hostfully_uid", "is", null),
      db.from("ops_property_expenses").select("*").gte("date", monthStart).lt("date", nextStart),
    ]);

    const ownerName: Record<string, string> = {};
    (ownRes.data ?? []).forEach((o: any) => ownerName[o.id] = o.name);
    const propMap: Record<string, any> = {};
    (propRes.data ?? []).forEach((p: any) => propMap[p.id] = p);
    const assign: Record<string, { owner_id: string; commission_pct: number }> = {};
    (poRes.data ?? []).forEach((a: any) => { if (a.owner_id) assign[a.property_id] = { owner_id: a.owner_id, commission_pct: Number(a.commission_pct) || 0 }; });
    const expByProp: Record<string, any[]> = {};
    (expRes.data ?? []).forEach((e: any) => { (expByProp[e.property_id] ||= []).push(e); });

    const assignedPropIds = Object.keys(assign).filter((pid) => propMap[pid]);

    const propResults = await Promise.all(assignedPropIds.map(async (pid) => {
      const p = propMap[pid]; const a = assign[pid];
      let leads: Awaited<ReturnType<HostfullyClient["listBookedLeads"]>> = [];
      try { leads = await hostfully.listBookedLeads(p.hostfully_uid); } catch { /* skip */ }
      const inMonth = leads.filter((l) => (l.checkInISO || "").slice(0, 7) === month);
      const stays = await Promise.all(inMonth.map(async (l) => {
        let rent = 0, guest = l.firstName || "", ci = (l.checkInISO || "").slice(0, 10), co = (l.checkOutISO || "").slice(0, 10);
        let channel = l.channel || "";
        try {
          const inv = await hostfully.getInvoiceData(l.uid);
          if (inv) { rent = inv.rent || 0; guest = inv.guestFullName || guest; ci = (inv.checkInISO || ci).slice(0, 10); co = (inv.checkOutISO || co).slice(0, 10); channel = inv.channel || channel; }
        } catch { /* keep defaults */ }
        // Airbnb: NO se cuadra comisión (Airbnb paga directo al dueño y a Stay Here). No suma al pago.
        const airbnb = /airbnb/i.test(channel);
        const commission = airbnb ? 0 : rent * (a.commission_pct / 100);
        const net = airbnb ? 0 : rent - commission;
        return { guest, check_in: ci, check_out: co, channel, airbnb, rent: r2(rent), commission: r2(commission), net: r2(net) };
      }));
      const staysRent = stays.filter((s) => !s.airbnb).reduce((s, x) => s + x.rent, 0); // renta que cuadra (no Airbnb)
      const staysComm = stays.reduce((s, x) => s + x.commission, 0);
      const staysNet = stays.reduce((s, x) => s + x.net, 0);
      const exps = (expByProp[pid] ?? []).map((e: any) => ({ date: e.date, description: e.description, amount: Number(e.amount) || 0, billable: !!e.billable }));
      const billableExp = exps.filter((e) => e.billable).reduce((s, e) => s + e.amount, 0);
      return {
        owner_id: a.owner_id, property_name: p.name, commission_pct: a.commission_pct,
        stays, stays_rent: r2(staysRent), stays_commission: r2(staysComm), stays_net: r2(staysNet),
        expenses: exps, billable_expense: r2(billableExp), payout: r2(staysNet - billableExp),
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
