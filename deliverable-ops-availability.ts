// ============================================================================
// Edge Function: ops-availability   (verify_jwt=true — cualquier usuario logueado)
//
// EN VIVO: consulta el calendario de Hostfully de cada propiedad activa para los
// próximos ~15 días y devuelve las NOCHES DISPONIBLES con su PRECIO PUBLICADO.
// La llama el tab "Disponibles" del app Personal cada vez que se abre (on-demand).
// Solo lectura de Hostfully. No escribe nada.
// ============================================================================

import { createDbClient } from "../_shared/db.ts";
import { HostfullyClient } from "../_shared/hostfully.ts";
import { env } from "../_shared/run.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DAYS = 15;

// Fecha local PR (AST, UTC-4) en YYYY-MM-DD, con desplazamiento en días.
function prDate(offsetDays = 0): string {
  return new Date(Date.now() - 4 * 60 * 60 * 1000 + offsetDays * 86_400_000)
    .toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
    const hostfully = new HostfullyClient({
      apiKey: env("HOSTFULLY_API_KEY"),
      baseUrl: env("HOSTFULLY_BASE_URL"),
    });

    const from = prDate(0);
    const to = prDate(DAYS - 1); // 15 noches: hoy .. hoy+14

    const { data: props, error } = await db
      .from("ops_properties")
      .select("id,name,hostfully_uid,is_active")
      .eq("is_active", true)
      .not("hostfully_uid", "is", null);
    if (error) return json({ ok: false, error: error.message }, 500);

    const list = (props ?? []) as Array<{ id: string; name: string; hostfully_uid: string }>;

    const results = await Promise.all(list.map(async (p) => {
      try {
        const nights = await hostfully.getCalendar(p.hostfully_uid, from, to);
        const avail = nights
          .filter((n) => n.isAvailable && n.date >= from && n.date <= to)
          .map((n) => ({ date: n.date, price: Math.round(Number(n.basePrice) || 0) }))
          .sort((a, b) => a.date < b.date ? -1 : 1);
        return { name: p.name, nights: avail };
      } catch (_e) {
        return { name: p.name, nights: [], error: true };
      }
    }));

    // Solo propiedades CON noches disponibles; más huecos primero.
    const properties = results
      .filter((r) => r.nights.length > 0)
      .sort((a, b) => b.nights.length - a.nights.length);

    return json({ ok: true, from, to, days: DAYS, properties });
  } catch (err) {
    console.error("ops-availability error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
