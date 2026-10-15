// Recebe os avisos do Mercado Pago sobre assinaturas e mensalidades.
// Nunca confia no conteúdo do aviso: busca os dados direto na API do Mercado Pago
// com o MP_ACCESS_TOKEN, então um aviso falso não libera nenhuma barbearia.
// Publicar com "Verify JWT" DESLIGADO (o Mercado Pago não envia o token do Supabase).
// Segredos: MP_ACCESS_TOKEN (obrigatório) e NTFY_TOPICO (opcional, para o aviso no seu celular).

const MP = "https://api.mercadopago.com";

async function rpc(fn: string, args: Record<string, unknown>) {
  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`banco ${fn}: ${t}`);
  return t ? JSON.parse(t) : null;
}

async function mp(path: string, method = "GET", body?: unknown) {
  const r = await fetch(MP + path, {
    method,
    headers: { Authorization: `Bearer ${Deno.env.get("MP_ACCESS_TOKEN")}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Mercado Pago ${path}: ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}

async function avisar(texto: string) {
  const topico = Deno.env.get("NTFY_TOPICO");
  if (!topico) return;
  try { await fetch(`https://ntfy.sh/${encodeURIComponent(topico)}`, { method: "POST", body: texto }); }
  catch (e) { console.error("ntfy", e); }
}

const brl = (v: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(v || 0);

// lê a assinatura no Mercado Pago e grava no banco; devolve a barbearia
async function tratarAssinatura(id: string) {
  const a = await mp(`/preapproval/${encodeURIComponent(id)}`);
  const m = /^b(\d+)-(basic|pro|expert)$/.exec(a.external_reference || "");
  if (!m) return null;
  const barb = Number(m[1]);
  const antiga = await rpc("mp_assinatura", { p_barb: barb, p_id: a.id, p_status: a.status, p_plano: m[2] });
  if (antiga) {   // trocou de plano: cancela a assinatura anterior para não cobrar duas vezes
    try { await mp(`/preapproval/${encodeURIComponent(antiga)}`, "PUT", { status: "cancelled" }); }
    catch (e) { console.error("cancelar antiga", e); }
  }
  return { barb, motivo: String(a.reason || ""), status: String(a.status || "") };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let corpo: Record<string, any> = {};
  try { corpo = await req.json(); } catch { /* aviso sem corpo */ }
  const tipo = corpo.type || url.searchParams.get("type") || url.searchParams.get("topic");
  const id = (corpo.data && corpo.data.id) || url.searchParams.get("data.id") || url.searchParams.get("id");
  if (!tipo || !id) return new Response("ok");

  try {
    if (tipo === "subscription_preapproval") {
      const r = await tratarAssinatura(String(id));
      if (r && corpo.action === "updated" && r.status === "cancelled") await avisar(`Assinatura cancelada: ${r.motivo}`);
    } else if (tipo === "subscription_authorized_payment") {
      const fatura = await mp(`/authorized_payments/${encodeURIComponent(String(id))}`);
      if (fatura.preapproval_id && fatura.payment && fatura.payment.status === "approved") {
        const r = await tratarAssinatura(String(fatura.preapproval_id));
        if (r) {
          const valor = Number(fatura.transaction_amount) || 0;
          const novo = await rpc("mp_pagamento", { p_barb: r.barb, p_ref: String(fatura.payment.id), p_valor: valor });
          if (novo) await avisar(`💈 Mensalidade paga: ${brl(valor)} · ${r.motivo}`);
        }
      }
    }
  } catch (e) {
    console.error(e);
    return new Response("erro", { status: 500 });   // o Mercado Pago tenta de novo depois
  }
  return new Response("ok");
});
