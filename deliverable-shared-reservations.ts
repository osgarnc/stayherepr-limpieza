// ============================================================================
// _shared/reservations.ts
//
// Lógica ÚNICA de "sincronizar una reserva de Hostfully -> tabla ops_reservations
// + anunciar la reserva NUEVA en el archivo de su propiedad". La usan por igual:
//   - el cron ops-sync-reservations (barrido de red de seguridad), y
//   - el webhook hostfully-bookings (instantáneo, al entrar el evento BOOKING_UPDATED).
//
// IDEMPOTENTE Y SIN CARRERAS: intenta un INSERT atómico. Si la fila es NUEVA, el
// insert gana y anunciamos UNA sola vez (la constraint única de lead_uid garantiza
// que solo un llamador concurrente —webhook o cron— gane). Si ya existía (23505),
// hacemos UPDATE y NO anunciamos. Así nunca sale tarjeta duplicada aunque el webhook
// y el cron coincidan.
// ============================================================================
import { type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HostfullyClient } from "./hostfully.ts";
import { archiveConversation, tgEscape } from "./telegram.ts";

export interface ResvLead {
  uid: string;
  firstName: string | null;
  channel: string | null;
  checkInISO: string;
  checkOutISO: string;
}

export interface ResvProperty {
  id: string;
  name: string;
  hostfully_uid: string;
}

/** Etiqueta legible del canal de reserva. */
export function channelLabel(ch: string | null | undefined): string {
  const c = String(ch ?? "").toUpperCase();
  if (c.includes("AIRBNB")) return "Airbnb";
  if (c.includes("PRICELINE")) return "Priceline";
  if (c.includes("BOOKING")) return "Booking.com";
  if (c.includes("VRBO") || c.includes("HOMEAWAY")) return "Vrbo";
  if (c.includes("EXPEDIA")) return "Expedia";
  if (c.includes("DIRECT") || c.includes("WEBSITE")) return "Directo";
  return ch ? String(ch) : "—";
}

export interface SyncResult {
  upserted: boolean;
  announced: boolean;
  skipped?: string;
}

/**
 * Sincroniza UNA reserva a ops_reservations y anuncia si es nueva. Lanza solo si el UPDATE de una
 * fila existente falla (para que el caller lo registre); el resto es best-effort.
 */
export async function syncReservationLead(
  db: SupabaseClient,
  hostfully: HostfullyClient,
  prop: ResvProperty,
  lead: ResvLead,
  today: string,
): Promise<SyncResult> {
  const checkOut = (lead.checkOutISO || "").slice(0, 10);
  const checkIn = (lead.checkInISO || "").slice(0, 10);
  if (!lead.uid || !checkOut) return { upserted: false, announced: false, skipped: "incompleta" };
  if (checkOut < today) return { upserted: false, announced: false, skipped: "pasada" };

  // Early/Late pagados por Host Co (leídos de las notas de la reserva en Hostfully).
  let early = false, late = false;
  try {
    const up = await hostfully.getHostCoUpsells(lead.uid);
    early = up.earlyCheckin;
    late = up.lateCheckout;
  } catch (_) { /* si falla, quedan en false */ }

  const row = {
    lead_uid: lead.uid,
    property_id: prop.id,
    hostfully_property_uid: prop.hostfully_uid,
    property_name: prop.name,
    guest_name: lead.firstName ?? null,
    check_in: checkIn || null,
    check_out: checkOut,
    status: "BOOKED",
    source: lead.channel ?? null,
    early_checkin_approved: early,
    late_checkout_approved: late,
    updated_at: new Date().toISOString(),
  };

  // LEDGER DURABLE (nunca se purga): registra TODA reserva vista mientras está viva, para que el
  // reporte de fin de mes por dueño no pierda reservas de canal iCal (Booking.com) tras el check-out
  // —ops_reservations sí se purga (check_out < hoy) y /leads no las devuelve. Best-effort.
  try {
    await db.from("ops_reservations_ledger").upsert({
      lead_uid: lead.uid,
      property_id: prop.id,
      guest_name: lead.firstName ?? null,
      source: lead.channel ?? null,
      check_in: checkIn || null,
      check_out: checkOut,
      updated_at: new Date().toISOString(),
    }, { onConflict: "lead_uid" });
  } catch (e) {
    console.error("ledger upsert falló:", e);
  }

  // INSERT atómico primero: si es nueva, gana el insert → anunciamos una sola vez.
  const { error: insErr } = await db.from("ops_reservations").insert(row);
  if (!insErr) {
    let announced = false;
    try {
      await archiveConversation(
        db,
        `📅 <b>Nueva reserva</b> · <b>${tgEscape(lead.firstName ?? "Huésped")}</b>\n` +
          `🏠 ${tgEscape(prop.name)}\n🗓️ ${checkIn || "?"} → ${checkOut}\n📱 ${tgEscape(channelLabel(lead.channel))}`,
        prop.id,
      );
      announced = true;
    } catch (e) {
      console.error("anuncio de reserva nueva falló:", e);
    }
    return { upserted: true, announced };
  }

  // 23505 = ya existía → UPDATE de campos mutables, sin anunciar.
  if ((insErr as { code?: string }).code === "23505") {
    const { error: uErr } = await db.from("ops_reservations").update(row).eq("lead_uid", lead.uid);
    if (uErr) throw new Error(uErr.message);
    return { upserted: true, announced: false };
  }
  throw new Error(insErr.message);
}
