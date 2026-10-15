// Cria (ou cancela) a assinatura mensal de uma barbearia no Mercado Pago.
// Chamada pelo painel do dono. Segredo necessário: MP_ACCESS_TOKEN.
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda Edge Function.

const MP = "https://api.mercadopago.com";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

class Erro extends Error {}

async function rpc(fn: string, args: Record<string, unknown>) {
  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) { let m = ""; try { m = JSON.parse(t).message; } catch { /* sem corpo */ } throw new Erro(m || "erro_banco"); }
  return t ? JSON.parse(t) : null;
}

async function mp(path: string, method = "GET", body?: unknown) {
  const r = await fetch(MP + path, {
    method,
    headers: {
      Authorization: `Bearer ${Deno.env.get("MP_ACCESS_TOKEN")}`,
      "Content-Type": "application/json",
      ...(method === "POST" ? { "X-Idempotency-Key": crypto.randomUUID() } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  if (!r.ok) { console.error("Mercado Pago", r.status, t); throw new Erro("mp_recusou"); }
  return t ? JSON.parse(t) : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "metodo" }, 405);
  if (!Deno.env.get("MP_ACCESS_TOKEN")) return json({ erro: "mp_nao_configurado" }, 503);
  try {
    const { acao, token, plano, email, volta } = await req.json();

    if (acao === "cancelar") {
      const id = await rpc("mp_assinatura_do_dono", { p_token: token });
      if (!id) return json({ erro: "sem_assinatura" }, 400);
      await mp(`/preapproval/${id}`, "PUT", { status: "cancelled" });
      return json({ ok: true });
    }

    if (typeof email !== "string" || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ erro: "email_invalido" }, 400);
    const linhas = await rpc("mp_iniciar", { p_token: token, p_plano: plano });
    const b = linhas && linhas[0];
    if (!b) return json({ erro: "nao_autorizado" }, 400);

    // volta: endereço do painel do dono (só https)
    const voltaOk = typeof volta === "string" && /^https:\/\/[^\s]+$/.test(volta) ? volta : "https://www.mercadopago.com.br";
    const fim = new Date(); fim.setFullYear(fim.getFullYear() + 5);
    const assinatura = await mp("/preapproval", "POST", {
      reason: `Plano ${b.plano_nome} - ${b.nome}`.slice(0, 120),
      external_reference: `b${b.barbearia_id}-${b.plano}`,
      payer_email: email.trim().toLowerCase(),
      auto_recurring: {
        frequency: 1,
        frequency_type: "months",
        end_date: fim.toISOString(),
        transaction_amount: Number(b.preco),
        currency_id: "BRL",
      },
      back_url: voltaOk,
      status: "pending",
    });
    await rpc("mp_guardar_pendente", { p_barb: b.barbearia_id, p_id: assinatura.id });
    return json({ link: assinatura.init_point });
  } catch (e) {
    return json({ erro: e instanceof Erro ? e.message : "erro" }, 400);
  }
});
