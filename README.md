# Fila e Faturamento: Barbearia do Andrezinho

Arquivo único (`index.html`) + banco no Supabase (`supabase.sql`).

## Links
- Cliente: `https://SEU-LINK/`
- Barbeiro: `https://SEU-LINK/#/barbeiro` (fila, faturamento e rotina dos clientes)
- Dono (você): `https://SEU-LINK/#/dono` (tudo isso + trocar senhas + corrigir valores)

## Estado atual
- O SQL já foi rodado no seu Supabase (projeto `barbearia-andrezinho`).
- O `index.html` já está ligado a esse projeto.
- **As duas senhas ainda são as de exemplo (`TROQUE-SENHA-DONO` e `TROQUE-SENHA-BARBEIRO`).** Antes de publicar, entre em `#/dono` com a senha de exemplo do dono, abra a aba **Senhas** e troque as duas.

## Publicar
1. Deixe só o `index.html` numa pasta.
2. Abra app.netlify.com/drop e arraste a pasta. O Netlify mostra o endereço do site.

## Como usar no dia a dia
- **Fila:** Chamar (abre o WhatsApp com a mensagem pronta e inicia 10 min), Finalizar (escolhe o serviço, confirma o valor), Liberar/Remover.
- **Faturamento:** hoje, semana, mês (comparando com o mesmo período anterior), ticket médio, últimos 14 dias, semana a semana e por serviço.
- **Clientes:** mostra quem está em rotina, atrasado, sumiu ou espaçando as visitas, com botão “Chamar de volta” no WhatsApp.
- **Dono:** na aba Faturamento aparecem os últimos atendimentos com Editar e Excluir. O barbeiro não vê esses botões.

## Preços dos serviços
Os preços no `index.html` (Corte 35, Barba 25, Corte + Barba 55) são **exemplos**. Ajuste em `SERVICOS`, no início do arquivo. Ao finalizar, dá para digitar qualquer valor.

## Limites que você precisa saber
- O faturamento só aparece para quem entra com senha. Os dados ficam trancados no banco; o painel acessa por funções protegidas.
- Depois de 8 senhas erradas, o login bloqueia por 10 minutos para todo mundo (proteção contra tentativa de adivinhar).
- O cronômetro de 10 minutos só remove o cliente da fila com o painel aberto.
- “Em rotina / atrasado / sumiu” são estimativas pela média de dias entre as visitas de cada cliente (precisa de 2 visitas). As regras ficam em `ROTINA`.
- Só entram no faturamento os atendimentos finalizados pelo botão Finalizar.
- Números de telefone ficam guardados no banco. Vale avisar os clientes (LGPD).
- Os limites dos planos gratuitos mudam; confira nos sites do Supabase e da hospedagem.
