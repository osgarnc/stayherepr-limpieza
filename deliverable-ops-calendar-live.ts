// ============================================================================
// Edge Function: ops-calendar-live   (verify_jwt=true — cualquier usuario logueado)
//
// EN VIVO: consulta las reservas BOOKED de Hostfully de cada propiedad activa y
// devuelve las presentes/futuras (check-out >= hoy) con early/late aprobado
// (leído de las notas de Host Co). La llama el tab "Calendario" del app Personal
// cada vez que se abre. Solo lectura de Hostfully; no escribe nada.
// ============================================================================

import { createDbClient } from "../_shared/db.ts";
import { HostfullyClient } from "../_shared/hostfully.ts";
import { env } from "../_shared/run.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function todayPR(): string {
  return new Date(Date.now() - 4 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    const hostfully = new HostfullyClient({
      apiKey: env("HOSTFULLY_API_KEY"),
      baseUrl: env("HOSTFULLY_BASE_URL"),
    });
    const today = todayPR();

    const { data: props, error } = await db
      .from("ops_properties")
      .select("id,name,hostfully_uid")
      .eq("is_active", true)
      .not("hostfully_uid", "is", null);
    if (error) return json({ ok: false, error: error.message }, 500);

    const list = (props ?? []) as Array<{ id: string; name: string; hostfully_uid: string }>;

    const perProp = await Promise.all(list.map(async (p) => {
      let leads: Awaited<ReturnType<HostfullyClient["listBookedLeads"]>> = [];
      try { leads = await hostfully.listBookedLeads(p.hostfully_uid); } catch { return []; }
      const upcoming = leads.filter((l) => (l.checkOutISO || "").slice(0, 10) >= today);
      return await Promise.all(upcoming.map(async (l) => {
        let early = false, late = false;
        try { const up = await hostfully.getHostCoUpsells(l.uid); early = up.earlyCheckin; late = up.lateCheckout; } catch { /* keep false */ }
        return {
          property_name: p.name,
          guest_name: l.firstName ?? null,
          check_in: (l.checkInISO || "").slice(0, 10) || null,
          check_out: (l.checkOutISO || "").slice(0, 10) || null,
          early_checkin_approved: early,
          late_checkout_approved: late,
        };
      }));
    }));

    const reservations = perProp.flat();
    return json({ ok: true, today, reservations });
  } catch (err) {
    console.error("ops-calendar-live error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
