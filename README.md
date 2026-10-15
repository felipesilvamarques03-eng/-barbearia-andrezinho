# Fila de Barbearia (várias barbearias, planos Basic, Pro e Expert)

Site em um arquivo (`index.html`) + banco no Supabase (`supabase-multi.sql`) + duas funções do Mercado Pago (`supabase/functions`).

## Links
- Plataforma (você): `/#/plataforma`, onde cadastra barbearias, muda plano, libera pagamento feito fora do app, define preços e redefine senhas.
- Cada barbearia: clientes `/#/<endereco>`, barbeiro `/#/<endereco>/barbeiro`, dono `/#/<endereco>/dono`.
- Links antigos (`/`, `/#/barbeiro`, `/#/dono`) abrem a Barbearia do Andrezinho.

## Planos
| | Basic R$ 19,90 | Pro R$ 39,90 | Expert R$ 69,90 |
|---|---|---|---|
| Fila online, chamada pelo WhatsApp, QR Pix no fim do corte | ✔ | ✔ | ✔ |
| Faturamento, rotina dos clientes | | ✔ | ✔ |
| Cadastro de barbeiros (comissão, aluguel de cadeira, salário) | | ✔ | ✔ |
| Despesas e relatórios mensais e anuais com lucro | | | ✔ |

- Barbearia nova: 2 dias grátis. Venceu: 3 dias de aviso; depois painel e fila pausam (o dono continua entrando para pagar; nada é apagado).
- Andrezinho: Expert, isento de mensalidade.
- Preços editáveis no painel da plataforma.

## Pagamentos
- Mensalidade: assinatura recorrente no Mercado Pago (cartão). Cada pagamento aprovado libera 1 mês.
  O aviso do Mercado Pago nunca é usado direto: a função consulta a assinatura e o pagamento na API do Mercado Pago antes de liberar.
- Clientes da barbearia: ao finalizar o corte, o barbeiro escolhe dinheiro, Pix ou cartão. No Pix aparece um QR Code
  (padrão BR Code do Banco Central) com o valor, na chave do profissional (se ele recebe direto) ou na chave da barbearia.
  O sistema não confirma o Pix sozinho: o barbeiro confere no app do banco.

## Configuração do Supabase (Edge Functions > Secrets)
- `MP_ACCESS_TOKEN`: Access Token de produção da sua aplicação no Mercado Pago.
- `NTFY_TOPICO`: canal do app ntfy para receber no celular o aviso de cada mensalidade paga (opcional).
- Webhook no Mercado Pago (Webhooks > Configurar notificações, eventos de Planos e assinaturas):
  `https://pndispqytfrezeiokgwk.supabase.co/functions/v1/mp-webhook`

## Dados pessoais
CPF, nascimento e endereço dos profissionais ficam só para o dono da barbearia (o barbeiro vê apenas o nome).
Telefones dos clientes e dados dos profissionais são dados pessoais: vale informar as pessoas sobre o uso (LGPD).
