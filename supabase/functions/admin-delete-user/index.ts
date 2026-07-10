// ============================================================
//  Supabase Edge Function: admin-delete-user
//  Borra por completo una cuenta de usuario (auth + perfil).
//  Solo el DUEÑO (role='owner') puede llamarla.
//  Recibe { targetId } = id del usuario a borrar.
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(o: unknown, s = 200) {
  return new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    // 1. ¿Quién llama? (validar su token)
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user }, error: ue } = await admin.auth.getUser(token);
    if (ue || !user) return json({ error: "No autenticado" }, 401);

    // 2. ¿Es dueño?
    const { data: prof } = await admin.from("profiles").select("role").eq("id", user.id).single();
    if (!prof || prof.role !== "owner") return json({ error: "Solo el dueño puede borrar usuarios" }, 403);

    // 3. A quién borrar
    const { targetId } = await req.json().catch(() => ({}));
    if (!targetId) return json({ error: "Falta el usuario a borrar" }, 400);
    if (targetId === user.id) return json({ error: "No puedes borrar tu propia cuenta" }, 400);

    // 4. Borrar (el perfil se borra en cascada por la relación con auth.users)
    const { error } = await admin.auth.admin.deleteUser(targetId);
    if (error) return json({ error: error.message }, 500);

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
