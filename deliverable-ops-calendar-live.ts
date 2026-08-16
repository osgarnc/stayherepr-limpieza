// ============================================================================
// Edge Function: ops-calendar-live   (verify_jwt=true)
//
// EN VIVO: ocupación real de todas las propiedades activas para el Calendario del
// app Personal. Combina DOS fuentes de Hostfully para no perder ninguna reserva:
//   1) LEADS (listBookedLeads): reservas con nombre de huésped + early/late.
//   2) CALENDARIO (property-calendar): noches bloqueadas por BOOKING que NO tienen
//      lead (reservas de canal sincronizadas por iCal, sin lead ni nombre en la API).
//      -> se muestran como "Reservado (canal)" para no perder la salida/limpieza.
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
function todayPR(): string { return new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10); }
function addDays(iso: string, n: number): string { return new Date(Date.parse(iso + "T00:00:00Z") + n * 86400000).toISOString().slice(0, 10); }
function nightsOf(ci: string, co: string): string[] { const out: string[] = []; let d = ci; let guard = 0; while (d < co && guard++ < 400) { out.push(d); d = addDays(d, 1); } return out; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    const hostfully = new HostfullyClient({ apiKey: env("HOSTFULLY_API_KEY"), baseUrl: env("HOSTFULLY_BASE_URL") });
    const apiKey = env("HOSTFULLY_API_KEY");
    const base = env("HOSTFULLY_BASE_URL").replace(/\/+$/, "");
    const today = todayPR();
    const calFrom = addDays(today, -10);
    const calTo = addDays(today, 120);

    const { data: props, error } = await db.from("ops_properties").select("id,name,hostfully_uid").eq("is_active", true).not("hostfully_uid", "is", null);
    if (error) return json({ ok: false, error: error.message }, 500);

    const perProp = await Promise.all(((props ?? []) as Array<{ name: string; hostfully_uid: string }>).map(async (p) => {
      const uid = p.hostfully_uid;

      // 1) Leads (con nombre + early/late)
      let leads: Awaited<ReturnType<HostfullyClient["listBookedLeads"]>> = [];
      try { leads = await hostfully.listBookedLeads(uid); } catch { /* skip */ }
      const leadStays = await Promise.all(leads.filter((l) => (l.checkOutISO || "").slice(0, 10) >= today).map(async (l) => {
        let early = false, late = false;
        try { const up = await hostfully.getHostCoUpsells(l.uid); early = up.earlyCheckin; late = up.lateCheckout; } catch { /* keep */ }
        return {
          property_name: p.name, guest_name: l.firstName ?? null,
          check_in: (l.checkInISO || "").slice(0, 10) || null, check_out: (l.checkOutISO || "").slice(0, 10) || null,
          early_checkin_approved: early, late_checkout_approved: late, source: "lead",
        };
      }));

      // Noches cubiertas por CUALQUIER lead (pasado o futuro) para no duplicar
      const covered = new Set<string>();
      leads.forEach((l) => { const ci = (l.checkInISO || "").slice(0, 10), co = (l.checkOutISO || "").slice(0, 10); if (ci && co) nightsOf(ci, co).forEach((d) => covered.add(d)); });

      // 2) Calendario crudo -> noches BOOKING sin lead (reservas de canal / iCal)
      let blocked: string[] = [];
      try {
        const r = await fetch(`${base}/property-calendar?propertiesUids=${uid}&from=${calFrom}&to=${calTo}`, { headers: { "X-HOSTFULLY-APIKEY": apiKey, "Accept": "application/json" } });
        const j = await r.json();
        const entries = j.calendars?.[0]?.entries ?? [];
        blocked = entries
          .filter((e: any) => e.availability?.unavailable === true && e.availability?.unavailabilityReason === "BOOKING")
          .map((e: any) => String(e.date))
          .filter((d: string) => d >= calFrom && !covered.has(d));
      } catch { /* skip */ }

      // Agrupar noches consecutivas -> estadías sin lead
      blocked.sort();
      const unattributed: any[] = [];
      let i = 0;
      while (i < blocked.length) {
        let start = blocked[i], end = blocked[i];
        while (i + 1 < blocked.length && blocked[i + 1] === addDays(end, 1)) { end = blocked[i + 1]; i++; }
        i++;
        const checkOut = addDays(end, 1);
        if (checkOut >= today) unattributed.push({
          property_name: p.name, guest_name: "Reservado (canal)",
          check_in: start, check_out: checkOut, early_checkin_approved: false, late_checkout_approved: false, source: "channel",
        });
      }

      return leadStays.concat(unattributed);
    }));

    return json({ ok: true, today, reservations: perProp.flat() });
  } catch (err) {
    console.error("ops-calendar-live error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
