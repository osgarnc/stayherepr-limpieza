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

import { createDbClient, isBotPaused } from "../_shared/db.ts";
import { HostfullyClient } from "../_shared/hostfully.ts";
import { syncReservationLead } from "../_shared/reservations.ts";
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
    const cronSecret = (Deno.env.get("CRON_SECRET") ?? "").trim();
    if (cronSecret && req.headers.get("x-cron-secret") !== cronSecret) {
      return json({ ok: false, error: "No autorizado" }, 401);
    }

    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    if (await isBotPaused(db)) return json({ ok: true, paused: true }, 200);
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
        // Misma lógica compartida con el webhook hostfully-bookings (insert-o-update atómico +
        // anuncio único). Idempotente: si el webhook ya la insertó, aquí solo se actualiza.
        try {
          const r = await syncReservationLead(db, hostfully, p, l, today);
          if (r.upserted) upserts++;
        } catch (e) {
          problems.push({ lead: l.uid, error: e instanceof Error ? e.message : String(e) });
        }
      }
    }

    // Fuente ADICIONAL: huéspedes que nos ESCRIBIERON (ops_messages) cuya reserva el endpoint /leads
    // NO devuelve — Hostfully solo retorna una ventana limitada (~20 leads/propiedad, muchos bloqueos),
    // así que reservas creadas hace días quedan fuera aunque el huésped esté hospedado (caso Fritz).
    // Verificamos su lead y lo sincronizamos si está BOOKED con check-out futuro.
    try {
      const propByUid = new Map<string, { id: string; name: string; hostfully_uid: string }>();
      for (const p of (props ?? []) as Array<{ id: string; name: string; hostfully_uid: string }>) {
        propByUid.set(p.hostfully_uid, p);
      }
      const since = new Date(Date.now() - 21 * 24 * 60 * 60 * 1000).toISOString();
      const { data: msgs } = await db.from("ops_messages").select("lead_uid")
        .gte("created_at", since).not("lead_uid", "is", null);
      const distinct = [...new Set(((msgs ?? []) as Array<{ lead_uid: string | null }>).map((m) => m.lead_uid).filter(Boolean))] as string[];
      for (const leadUid of distinct) {
        const { data: ex } = await db.from("ops_reservations").select("lead_uid").eq("lead_uid", leadUid).maybeSingle();
        if (ex) continue; // ya está (se refresca/verifica abajo)
        const lead = await hostfully.getReservationLead(leadUid).catch(() => null);
        if (!lead || lead.status !== "BOOKED" || !lead.propertyUid) continue;
        const prop = propByUid.get(lead.propertyUid);
        if (!prop) continue;
        try {
          const r = await syncReservationLead(db, hostfully, prop, {
            uid: lead.uid,
            firstName: lead.firstName,
            channel: lead.channel,
            checkInISO: lead.checkInISO,
            checkOutISO: lead.checkOutISO,
          }, today);
          if (r.upserted) upserts++;
        } catch (e) {
          problems.push({ lead: leadUid, error: e instanceof Error ? e.message : String(e) });
        }
      }
    } catch (e) {
      problems.push({ source: "ops_messages", error: e instanceof Error ? e.message : String(e) });
    }

    // Limpieza:
    //  1) borra reservas ya pasadas (check_out < hoy).
    await db.from("ops_reservations").delete().lt("check_out", today);
    //  2) futuras NO tocadas esta corrida: NO se borran a ciegas. El endpoint /leads de Hostfully tiene
    //     una ventana limitada y puede NO devolver reservas VÁLIDAS (caso Fritz), así que borrar a ciegas
    //     eliminaría huéspedes reales. Verificamos cada una: solo se borra si su lead ya NO está BOOKED.
    const { data: stale } = await db.from("ops_reservations")
      .select("lead_uid").gte("check_out", today).lt("updated_at", runStart);
    for (const s of (stale ?? []) as Array<{ lead_uid: string }>) {
      // GET /leads/{uid} SÍ devuelve reservas de canal (Booking.com) que el LIST omite (caso Dario).
      const lead = await hostfully.getReservationLead(s.lead_uid).catch(() => null);
      // Solo borramos cuando CONFIRMAMOS que ya no está viva. Si el GET falla (null = blip de API),
      // NO borramos (evita perder una reserva válida por un error transitorio); se reevalúa la próxima corrida.
      if (!lead) continue;
      const gone = lead.status !== "BOOKED" || (lead.checkOutISO || "").slice(0, 10) < today;
      if (gone) {
        await db.from("ops_reservations").delete().eq("lead_uid", s.lead_uid);
      } else {
        // Viva pero el LIST no la devolvió → refresca updated_at para no reevaluarla cada corrida.
        await db.from("ops_reservations").update({ updated_at: new Date().toISOString() }).eq("lead_uid", s.lead_uid);
      }
    }

    return json({ ok: true, upserts, properties: (props ?? []).length, problems });
  } catch (err) {
    console.error("ops-sync-reservations error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
