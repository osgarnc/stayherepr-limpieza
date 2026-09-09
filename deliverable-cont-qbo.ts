// ============================================================================
// Edge Function: cont-qbo   (verify_jwt=true)  — CONTABILIDAD
//
// Único punto de contacto con QuickBooks Online. El navegador NUNCA ve las
// credenciales de Intuit: manda una acción, esta función la ejecuta.
//
// Acciones (body: { action: "..." }):
//   estado    → ¿está conectado? nombre de la compañía y si el tracking de
//               clases está prendido.
//   catalogo  → lista de clases y cuentas de QBO, para el mapeo de propiedades.
//   postear   → { payout_id }  crea el Deposit del payout y lo marca posteado.
//   anular    → { payout_id }  borra en QBO el Deposit ya creado y lo despostea.
//
// SEGURIDAD
//   - Solo entra quien tiene can_reconcile() en su perfil.
//   - El refresh_token de Intuit ROTA en cada uso: se guarda ANTES de devolver
//     nada, porque si se pierde hay que reconectar la app a mano.
//   - Se niega a escribir dentro del periodo ya cuadrado (PERIODO_CERRADO) y a
//     postear un renglón sin clase.
//
// SECRETS que hay que poner en Supabase (Edge Functions → Secrets):
//   QBO_CLIENT_ID, QBO_CLIENT_SECRET
// ============================================================================

import { createDbClient } from "../_shared/db.ts";
import { env } from "../_shared/run.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Nada se escribe con fecha dentro del periodo ya reconciliado.
const PERIODO_CERRADO = "2026-07-31";

const TOKEN_URL = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer";
const API_BASE: Record<string, string> = {
  production: "https://quickbooks.api.intuit.com",
  sandbox: "https://sandbox-quickbooks.api.intuit.com",
};
const MINOR = "70";
const r2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;

type Cfg = {
  realm_id: string;
  refresh_token: string;
  environment: string;
  company_name: string | null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createDbClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));

    // ---- quién llama ------------------------------------------------------
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ ok: false, error: "No autorizado" }, 401);
    const { data: userRes } = await db.auth.getUser(jwt);
    const uid = userRes?.user?.id;
    if (!uid) return json({ ok: false, error: "No autorizado" }, 401);
    const { data: prof } = await db
      .from("profiles").select("can_reconcile").eq("id", uid).maybeSingle();
    if (!prof?.can_reconcile) return json({ ok: false, error: "Sin acceso a Contabilidad" }, 403);

    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const action = String(body.action || "");

    const { data: cfg } = await db
      .from("cont_qbo_config").select("*").eq("id", 1).maybeSingle();
    if (!cfg?.refresh_token || !cfg?.realm_id) {
      return json({ ok: false, error: "QuickBooks no está conectado todavía.", sin_conexion: true }, 200);
    }

    const qbo = await connect(db, cfg as Cfg);

    if (action === "estado") {
      const info = await qbo.get(`companyinfo/${qbo.realm}`);
      const pref = await qbo.get("preferences");
      const clases = !!pref?.Preferences?.AccountingInfoPrefs?.ClassTrackingPerTxnLine ||
                     !!pref?.Preferences?.AccountingInfoPrefs?.ClassTrackingPerTxn;
      const nombre = info?.CompanyInfo?.CompanyName || null;
      if (nombre && nombre !== cfg.company_name) {
        await db.from("cont_qbo_config").update({ company_name: nombre }).eq("id", 1);
      }
      return json({ ok: true, compania: nombre, realm: qbo.realm, entorno: qbo.entorno, clases });
    }

    if (action === "catalogo") {
      const [cl, ac] = await Promise.all([
        qbo.query("SELECT Id, Name FROM Class MAXRESULTS 500"),
        qbo.query("SELECT Id, Name, AccountType FROM Account MAXRESULTS 900"),
      ]);
      return json({
        ok: true,
        clases: (cl.Class || []).map((c: any) => ({ id: c.Id, name: c.Name })),
        cuentas: (ac.Account || []).map((a: any) => ({ id: a.Id, name: a.Name, type: a.AccountType })),
      });
    }

    if (action === "postear" || action === "anular") {
      const payoutId = String(body.payout_id || "");
      if (!payoutId) return json({ ok: false, error: "Falta payout_id" }, 400);

      const { data: pay } = await db
        .from("cont_payouts").select("*").eq("id", payoutId).maybeSingle();
      if (!pay) return json({ ok: false, error: "Ese payout no existe" }, 404);

      // ---------------- anular ------------------------------------------
      if (action === "anular") {
        if (!pay.qbo_deposit_id) return json({ ok: false, error: "Ese payout no está posteado" }, 400);
        const cur = await qbo.get(`deposit/${pay.qbo_deposit_id}`);
        const d = cur?.Deposit;
        if (!d) return json({ ok: false, error: "No encontré el depósito en QuickBooks" }, 404);
        await qbo.post("deposit?operation=delete", { Id: d.Id, SyncToken: d.SyncToken });
        await db.from("cont_payouts").update({
          status: "listo", qbo_deposit_id: null, qbo_posted_at: null,
          updated_at: new Date().toISOString(),
        }).eq("id", payoutId);
        await log(db, payoutId, "anular", true, pay.qbo_deposit_id, qbo.tid, null, uid);
        return json({ ok: true, anulado: pay.qbo_deposit_id });
      }

      // ---------------- postear ------------------------------------------
      if (pay.qbo_deposit_id) {
        return json({ ok: false, error: `Ya está posteado (depósito ${pay.qbo_deposit_id}).` }, 409);
      }
      if (String(pay.pay_date).slice(0, 10) <= PERIODO_CERRADO) {
        return json({
          ok: false,
          error: `Bloqueado: ${pay.pay_date} cae dentro del periodo ya reconciliado (hasta ${PERIODO_CERRADO}).`,
        }, 400);
      }

      const { data: lines } = await db
        .from("cont_payout_lines").select("*").eq("payout_id", payoutId).order("ord");
      if (!lines?.length) return json({ ok: false, error: "Ese payout no tiene renglones" }, 400);

      const sinClase = lines.filter((l: any) => !l.qbo_class_id);
      if (sinClase.length) {
        return json({
          ok: false,
          error: `${sinClase.length} renglón(es) sin clase. Todo asiento tiene que llevar clase — ` +
                 `asigna la propiedad en Ajustes de Contabilidad.`,
        }, 400);
      }

      const suma = r2(lines.reduce((a: number, l: any) => a + Number(l.amount || 0), 0));
      if (Math.abs(suma - Number(pay.amount)) > 0.005) {
        return json({
          ok: false,
          error: `No cuadra: los renglones suman ${suma.toFixed(2)} y el payout es ${Number(pay.amount).toFixed(2)}.`,
        }, 400);
      }

      const { data: cuentas } = await db.from("cont_qbo_account").select("key,qbo_account_id");
      const CTA: Record<string, string> = {};
      (cuentas || []).forEach((c: any) => { CTA[c.key] = c.qbo_account_id; });
      const faltan = [...new Set(lines.map((l: any) => l.kind))].filter((k) => !CTA[String(k)]);
      if (faltan.length) {
        return json({ ok: false, error: `Sin cuenta de QuickBooks para: ${faltan.join(", ")}` }, 400);
      }

      const marca = `CONTA-${String(pay.source).toUpperCase()} ${pay.ref}`;
      // Idempotencia: si ya existe un depósito con esta marca, lo adoptamos en
      // vez de crear un duplicado (el DocNumber de QBO no es único).
      const previo = await qbo.query(
        `SELECT Id, PrivateNote FROM Deposit WHERE TxnDate = '${pay.pay_date}'`,
      );
      const yaEsta = (previo.Deposit || []).find((d: any) =>
        String(d.PrivateNote || "").includes(marca)
      );
      if (yaEsta) {
        await db.from("cont_payouts").update({
          status: "posteado", qbo_deposit_id: yaEsta.Id,
          qbo_posted_at: new Date().toISOString(), updated_at: new Date().toISOString(),
        }).eq("id", payoutId);
        await log(db, payoutId, "postear (ya existía)", true, yaEsta.Id, qbo.tid, null, uid);
        return json({ ok: true, deposit_id: yaEsta.Id, adoptado: true });
      }

      const cuerpo = {
        TxnDate: String(pay.pay_date).slice(0, 10),
        DepositToAccountRef: { value: CTA["banco"] },
        PrivateNote: `${marca} — ${pay.source} ${pay.account_label || ""} $${Number(pay.amount).toFixed(2)}. ` +
                     `Creado desde la app de Stay Here PR.`,
        Line: lines.map((l: any) => {
          const det: Record<string, unknown> = {
            AccountRef: { value: CTA[String(l.kind)] },
            ClassRef: { value: String(l.qbo_class_id) },
          };
          // Toda línea contra Accounts Receivable necesita cliente; la
          // retención de Stripe usa el cliente "Stripe Reserve".
          if (l.kind === "reserva") det.Entity = { value: "283", type: "Customer" };
          return {
            Amount: r2(Number(l.amount)),
            DetailType: "DepositLineDetail",
            Description: String(l.description || "").slice(0, 1000),
            DepositLineDetail: det,
          };
        }),
      };

      let creado;
      try {
        creado = await qbo.post("deposit", cuerpo);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        await log(db, payoutId, "postear", false, null, qbo.tid, msg, uid);
        return json({ ok: false, error: msg }, 400);
      }
      const dep = creado?.Deposit;
      await db.from("cont_payouts").update({
        status: "posteado", qbo_deposit_id: dep?.Id,
        qbo_posted_at: new Date().toISOString(), updated_at: new Date().toISOString(),
      }).eq("id", payoutId);
      await log(db, payoutId, "postear", true, dep?.Id, qbo.tid, null, uid);
      return json({ ok: true, deposit_id: dep?.Id, total: dep?.TotalAmt, lineas: (dep?.Line || []).length });
    }

    return json({ ok: false, error: `Acción desconocida: ${action}` }, 400);
  } catch (err) {
    console.error("cont-qbo error:", err);
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

// ---------------------------------------------------------------------------
// Cliente de QuickBooks. Refresca el token y GUARDA el nuevo refresh_token
// antes de devolver: el de Intuit rota y perderlo obliga a reconectar a mano.
// ---------------------------------------------------------------------------
async function connect(db: any, cfg: Cfg) {
  const id = env("QBO_CLIENT_ID");
  const secret = env("QBO_CLIENT_SECRET");
  const basic = btoa(`${id}:${secret}`);

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: cfg.refresh_token,
    }),
  });
  const tok = await res.json().catch(() => ({}));
  if (!res.ok || !tok.access_token) {
    throw new Error(
      `No se pudo refrescar el token de QuickBooks (${res.status}). ` +
      `Si dice invalid_grant, hay que reconectar la app a Intuit.`,
    );
  }
  // Guardar PRIMERO. Si esto falla, mejor fallar aquí que perder el token.
  if (tok.refresh_token && tok.refresh_token !== cfg.refresh_token) {
    const { error } = await db.from("cont_qbo_config").update({
      refresh_token: tok.refresh_token,
      last_refresh: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", 1);
    if (error) throw new Error(`No pude guardar el refresh_token nuevo: ${error.message}`);
  }

  const entorno = cfg.environment || "production";
  const base = API_BASE[entorno] || API_BASE.production;
  const realm = cfg.realm_id;
  const head = {
    Authorization: `Bearer ${tok.access_token}`,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
  const self = {
    realm,
    entorno,
    tid: null as string | null,
    async call(method: string, path: string, payload?: unknown) {
      const url = `${base}/v3/company/${realm}/${path}` +
                  (path.includes("?") ? "&" : "?") + `minorversion=${MINOR}`;
      const r = await fetch(url, {
        method,
        headers: head,
        body: payload === undefined ? undefined : JSON.stringify(payload),
      });
      self.tid = r.headers.get("intuit_tid");
      const txt = await r.text();
      let data: any = {};
      try { data = txt ? JSON.parse(txt) : {}; } catch { /* respuesta no-JSON */ }
      if (!r.ok) {
        const f = data?.Fault?.Error?.[0];
        throw new Error(
          f ? `${f.Message}${f.Detail ? " — " + f.Detail : ""} (código ${f.code}, tid ${self.tid})`
            : `QuickBooks respondió ${r.status} (tid ${self.tid})`,
        );
      }
      return data;
    },
    get(path: string) { return self.call("GET", path); },
    post(path: string, payload: unknown) { return self.call("POST", path, payload); },
    async query(q: string) {
      const d = await self.call("GET", `query?query=${encodeURIComponent(q)}`);
      return d.QueryResponse || {};
    },
  };
  return self;
}

async function log(
  db: any, payoutId: string | null, action: string, ok: boolean,
  qboId: string | null, tid: string | null, detail: string | null, uid: string,
) {
  await db.from("cont_qbo_log").insert({
    payout_id: payoutId, action, ok, qbo_id: qboId,
    intuit_tid: tid, detail, created_by: uid,
  });
}

function json(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: cors });
}
