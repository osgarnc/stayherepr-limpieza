// ============================================================================
// Edge Function: ops-sync-reservations   (cron — sin verify_jwt)
//
// Sincroniza las reservas BOOKED de Hostfully -> tabla `ops_reservations`, que
// alimenta el "Calendario compartido" del app Personal (lo ven TODOS).
// Marca early/late APROBADOS Y PAGADOS leyendo las notas de Host Co en la
// reserva (getHostCoUpsells) -> early_checkin_approved / late_checkout_approved.
//
// SOLO LECTURA de Hostfully (no altera reservas). Escribe a Supabase con
// service_role (salta RLS). Colócala en:  stayhere-ops/supabase/functions/
//   ops-sync-reservations/index.ts   y despliégala con verify_jwt DESACTIVADO.
// ============================================================================

import { createDbClient } from "../_shared/db.ts";
import { HostfullyClient } from "../_shared/hostfully.ts";
import { env } from "../_shared/run.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Fecha local de PR (AST, UTC-4) en YYYY-MM-DD.
function todayPR(): string {
  return new Date(Date.now() - 4 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    // Si CRON_SECRET está configurado, exige el header (igual que otras funciones cron).
    const cronSecret = (env("CRON_SECRET") ?? "").trim();
    if (cronSecret && req.headers.get("x-cron-secret") !== cronSecret) {
      return json({ ok: false, error: "No autorizado" }, 401);
    }

    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    const hostfully = new HostfullyClient({
      apiKey: env("HOSTFULLY_API_KEY"),
      baseUrl: env("HOSTFULLY_BASE_URL"),
    });

    const today = todayPR();
    const runStart = new Date().toISOString();

    // Propiedades con hostfully_uid (para poder mapear property_id).
    const { data: props, error: pErr } = await db
      .from("ops_properties")
      .select("id,name,hostfully_uid")
      .not("hostfully_uid", "is", null);
    if (pErr) return json({ ok: false, error: pErr.message }, 500);

    let upserts = 0;
    const problems: unknown[] = [];

    for (const p of (props ?? []) as Array<{ id: string; name: string; hostfully_uid: string }>) {
      let leads: Awaited<ReturnType<HostfullyClient["listBookedLeads"]>> = [];
      try {
        leads = await hostfully.listBookedLeads(p.hostfully_uid);
      } catch (e) {
        problems.push({ property: p.name, error: String(e) });
        continue;
      }

      for (const l of leads) {
        const checkOut = (l.checkOutISO || "").slice(0, 10);
        const checkIn = (l.checkInISO || "").slice(0, 10);
        if (!l.uid || !checkOut) continue;
        if (checkOut < today) continue; // el calendario solo muestra presentes/futuros

        // Early/Late pagados por Host Co (leídos de las notas de la reserva en Hostfully).
        let early = false, late = false;
        try {
          const up = await hostfully.getHostCoUpsells(l.uid);
          early = up.earlyCheckin;
          late = up.lateCheckout;
        } catch (_) { /* si falla, quedan en false */ }

        const { error: uErr } = await db.from("ops_reservations").upsert({
          lead_uid: l.uid,
          property_id: p.id,
          hostfully_property_uid: p.hostfully_uid,
          property_name: p.name,
          guest_name: l.firstName ?? null,
          check_in: checkIn || null,
          check_out: checkOut,
          status: "BOOKED",
          source: l.channel ?? null,
          early_checkin_approved: early,
          late_checkout_approved: late,
          updated_at: new Date().toISOString(),
        }, { onConflict: "lead_uid" });
        if (uErr) { problems.push({ lead: l.uid, error: uErr.message }); continue; }
        upserts++;
      }
    }

    // Limpieza:
    //  1) borra reservas ya pasadas (check_out < hoy).
    await db.from("ops_reservations").delete().lt("check_out", today);
    //  2) borra futuras que NO se tocaron en esta corrida (cancelaciones/cambios).
    await db.from("ops_reservations").delete().gte("check_out", today).lt("updated_at", runStart);

    return json({ ok: true, upserts, properties: (props ?? []).length, problems });
  } catch (err) {
    console.error("ops-sync-reservations error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
