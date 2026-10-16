-- =====================================================================
-- Fila de Barbearia: VÁRIAS BARBEARIAS + PLANOS (Basic, Pro, Expert)
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
--
-- Serve para os dois casos:
--  * banco que já tinha a versão de uma barbearia só (Andrezinho):
--    os dados e as senhas atuais passam para a barbearia "andrezinho",
--    que fica no plano Expert, isenta de mensalidade;
--  * banco novo, vazio.
-- Pode rodar de novo sem problema (o script é repetível).
--
-- Senha da PLATAFORMA (o painel onde você cadastra barbearias):
--  * se já existia a senha do dono, ela vira também a senha da plataforma;
--  * em banco novo, a senha inicial é TROQUE-SENHA-PLATAFORMA (troque no painel).
--
-- Regras de cobrança:
--  * barbearia nova: 2 dias de teste grátis;
--  * venceu: 3 dias de aviso; depois, painel e fila ficam bloqueados
--    (o dono continua entrando para pagar; nenhum dado é apagado).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tabelas (formato antigo, caso o banco seja novo) ----------
create table if not exists clientes (
  telefone text not null,
  nome text not null,
  visitas int not null default 0,
  ultima_visita timestamptz,
  criado_em timestamptz not null default now()
);
create table if not exists fila (
  id bigint generated always as identity primary key,
  telefone text not null,
  nome text not null,
  status text not null default 'esperando'
    check (status in ('esperando','chamado','atendido','removido')),
  entrada timestamptz not null default now(),
  chamado_em timestamptz
);
alter table fila
  add column if not exists servico text,
  add column if not exists valor numeric(10,2),
  add column if not exists finalizado_em timestamptz;
create table if not exists config (chave text primary key, valor text not null);
create table if not exists tentativas (
  id bigint generated always as identity primary key,
  em timestamptz not null default now()
);
create table if not exists sessoes (
  token_hash text primary key,
  papel text not null,
  expira timestamptz not null
);

-- ---------- planos ----------
create table if not exists planos (
  codigo text primary key check (codigo in ('basic','pro','expert')),
  nome text not null,
  preco numeric(10,2) not null check (preco between 1 and 10000),
  nivel int not null unique
);
insert into planos (codigo, nome, preco, nivel) values
  ('basic',  'Basic',  15.00, 1),
  ('pro',    'Pro',    39.90, 2),
  ('expert', 'Expert', 69.90, 3)
on conflict (codigo) do nothing;
-- agendBarber 1.0: o Basic sai por R$ 15,00 (só ajusta se ainda estiver no preço antigo)
update planos set preco = 15.00 where codigo = 'basic' and preco = 19.90;

-- ---------- barbearias ----------
create table if not exists barbearias (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
  nome text not null check (length(btrim(nome)) between 2 and 60),
  servicos jsonb not null default
    '[{"nome":"Corte","preco":35},{"nome":"Barba","preco":25},{"nome":"Corte + Barba","preco":55}]'::jsonb,
  min_por_cliente int not null default 30 check (min_por_cliente between 5 and 240),
  tolerancia_min int not null default 10 check (tolerancia_min between 1 and 60),
  pin_dono text not null,
  pin_barbeiro text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
alter table barbearias
  add column if not exists plano text not null default 'pro' references planos(codigo),
  add column if not exists isento boolean not null default false,
  add column if not exists teste_ate timestamptz,
  add column if not exists pago_ate timestamptz,
  add column if not exists mp_assinatura_id text,
  add column if not exists mp_status text,
  add column if not exists mp_pendente_id text,
  add column if not exists cidade text not null default 'Rio de Janeiro',
  add column if not exists pix_tipo text check (pix_tipo is null or pix_tipo in ('cpf','cnpj','email','telefone','aleatoria')),
  add column if not exists pix_chave text,
  add column if not exists pix_nome text;

-- senha da plataforma: herda a do dono antigo, se existir
insert into config (chave, valor)
select 'pin_plataforma',
       coalesce((select valor from config where chave = 'pin_dono'),
                extensions.crypt('TROQUE-SENHA-PLATAFORMA', extensions.gen_salt('bf')))
on conflict (chave) do nothing;

-- a barbearia que já existia vira "andrezinho": mesmas senhas, plano Expert, isenta
insert into barbearias (slug, nome, pin_dono, pin_barbeiro, plano, isento)
select 'andrezinho', 'Barbearia do Andrezinho',
       (select valor from config where chave = 'pin_dono'),
       (select valor from config where chave = 'pin_barbeiro'),
       'expert', true
where exists (select 1 from config where chave = 'pin_dono')
  and exists (select 1 from config where chave = 'pin_barbeiro')
  and not exists (select 1 from barbearias where slug = 'andrezinho');
update barbearias set plano = 'expert', isento = true where slug = 'andrezinho';

delete from config where chave in ('pin_dono', 'pin_barbeiro')
  and exists (select 1 from barbearias where slug = 'andrezinho');

-- ---------- profissionais (barbeiros da casa, aluguel de cadeira, comissão...) ----------
create table if not exists profissionais (
  id bigint generated always as identity primary key,
  barbearia_id bigint not null references barbearias(id) on delete cascade,
  nome text not null check (length(btrim(nome)) between 5 and 100),          -- nome completo
  apelido text check (apelido is null or length(btrim(apelido)) between 1 and 30),
  cpf text not null check (cpf ~ '^\d{11}$'),
  nascimento date not null,
  telefone text check (telefone is null or telefone ~ '^\d{10,11}$'),
  email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  pix_tipo text check (pix_tipo is null or pix_tipo in ('cpf','cnpj','email','telefone','aleatoria')),
  pix_chave text check (pix_chave is null or length(pix_chave) <= 77),
  recebe_direto boolean not null default false,   -- o Pix do cliente cai direto na chave do profissional
  endereco text check (endereco is null or length(endereco) <= 200),
  funcao text not null default 'Barbeiro' check (length(btrim(funcao)) between 2 and 40),
  -- comissao: o profissional recebe X% de cada atendimento
  -- aluguel: o profissional paga aluguel da cadeira e fica com 100% dos atendimentos
  -- aluguel_comissao: paga aluguel e recebe X% de cada atendimento
  -- salario: recebe salário fixo
  -- nenhum: sem repasse (ex.: o próprio dono)
  tipo text not null check (tipo in ('comissao','aluguel','aluguel_comissao','salario','nenhum')),
  comissao_pct numeric(5,2) check (comissao_pct is null or comissao_pct between 0 and 100),
  aluguel_valor numeric(10,2) check (aluguel_valor is null or aluguel_valor between 0 and 100000),
  aluguel_periodo text check (aluguel_periodo is null or aluguel_periodo in ('semanal','mensal')),
  salario numeric(10,2) check (salario is null or salario between 0 and 100000),
  inicio date not null default current_date,
  saida date,
  ativo boolean not null default true,
  obs text check (obs is null or length(obs) <= 500),
  criado_em timestamptz not null default now(),
  unique (barbearia_id, cpf)
);

-- ---------- despesas ----------
create table if not exists despesas (
  id bigint generated always as identity primary key,
  barbearia_id bigint not null references barbearias(id) on delete cascade,
  data date not null,
  categoria text not null check (length(btrim(categoria)) between 2 and 40),
  descricao text check (descricao is null or length(descricao) <= 120),
  valor numeric(10,2) not null check (valor > 0 and valor <= 1000000),
  criado_em timestamptz not null default now()
);
create index if not exists despesas_b_data on despesas (barbearia_id, data);

-- ---------- pagamentos de mensalidade ----------
create table if not exists pagamentos (
  id bigint generated always as identity primary key,
  barbearia_id bigint not null references barbearias(id) on delete cascade,
  origem text not null check (origem in ('mercadopago','manual')),
  ref text unique,                       -- id do pagamento no Mercado Pago
  valor numeric(10,2),
  pago_em timestamptz not null default now(),
  dias int not null default 0
);

-- ---------- barbearia_id em cada tabela ----------
alter table clientes   add column if not exists barbearia_id bigint references barbearias(id) on delete cascade;
alter table fila       add column if not exists barbearia_id bigint references barbearias(id) on delete cascade;
alter table fila       add column if not exists profissional_id bigint references profissionais(id) on delete set null;
alter table fila       add column if not exists forma_pagamento text
  check (forma_pagamento is null or forma_pagamento in ('dinheiro','pix','cartao'));
alter table sessoes    add column if not exists barbearia_id bigint references barbearias(id) on delete cascade;
alter table tentativas add column if not exists barbearia_id bigint;

update clientes set barbearia_id = (select id from barbearias where slug = 'andrezinho') where barbearia_id is null;
update fila     set barbearia_id = (select id from barbearias where slug = 'andrezinho') where barbearia_id is null;
delete from clientes where barbearia_id is null;   -- só acontece se não houver dono antigo
delete from fila     where barbearia_id is null;
alter table clientes alter column barbearia_id set not null;
alter table fila     alter column barbearia_id set not null;

-- chave do cliente passa a ser (barbearia, telefone)
do $$
begin
  if exists (select 1 from pg_constraint where conrelid = 'clientes'::regclass and contype = 'p'
             and array_length(conkey, 1) = 1) then
    execute 'alter table clientes drop constraint ' ||
      (select conname from pg_constraint where conrelid = 'clientes'::regclass and contype = 'p');
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'clientes'::regclass and contype = 'p') then
    alter table clientes add primary key (barbearia_id, telefone);
  end if;
end $$;

-- sessões: papel pode ser dono, barbeiro ou plataforma; sessões antigas são encerradas
alter table sessoes drop constraint if exists sessoes_papel_check;
delete from sessoes where barbearia_id is null and papel <> 'plataforma';
alter table sessoes add constraint sessoes_papel_check check (papel in ('dono','barbeiro','plataforma'));

drop index if exists fila_status_entrada;
drop index if exists fila_telefone;
drop index if exists fila_finalizado;
create index if not exists fila_b_status_entrada on fila (barbearia_id, status, entrada);
create index if not exists fila_b_telefone on fila (barbearia_id, telefone);
create index if not exists fila_b_finalizado on fila (barbearia_id, finalizado_em) where status = 'atendido';
create index if not exists tentativas_b_em on tentativas (barbearia_id, em);
create index if not exists profissionais_b on profissionais (barbearia_id);

-- ---------- trancar o acesso direto às tabelas ----------
alter table clientes      enable row level security;
alter table fila          enable row level security;
alter table config        enable row level security;
alter table tentativas    enable row level security;
alter table sessoes       enable row level security;
alter table barbearias    enable row level security;
alter table planos        enable row level security;
alter table profissionais enable row level security;
alter table despesas      enable row level security;
alter table pagamentos    enable row level security;
revoke all on clientes, fila, config, tentativas, sessoes, barbearias, planos, profissionais, despesas, pagamentos
  from anon, authenticated;

-- ---------- remover funções de versões anteriores (assinaturas mudaram) ----------
drop function if exists _papel(text);
drop function if exists _exigir(text, boolean);
drop function if exists fila_publica();
drop function if exists entrar_fila(text, text);
drop function if exists buscar_cliente(text);
drop function if exists sair_fila(bigint, text);
drop function if exists adm_login(text);
drop function if exists info_barbearia(text);
drop function if exists adm_finalizar(text, bigint, text, numeric);
drop function if exists adm_finalizar(text, bigint, text, numeric, bigint);
drop function if exists adm_atendimentos(text);
drop function if exists plat_listar(text);
drop function if exists plat_criar(text, text, text, text, text);
drop function if exists dono_ajustes(text, text, jsonb, int, int);
drop function if exists adm_conta(text);

-- ---------- funções internas ----------
create or replace function _bloqueio(p_barb bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from tentativas
       where barbearia_id is not distinct from p_barb and em > now() - interval '10 minutes') >= 8 then
    raise exception 'bloqueado';
  end if;
end $$;

create or replace function _falhou(p_barb bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from tentativas where em < now() - interval '1 day';
  insert into tentativas (barbearia_id) values (p_barb);
end $$;

create or replace function _novo_token(p_papel text, p_barb bigint)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_tok text := encode(gen_random_bytes(24), 'hex');
begin
  delete from sessoes where expira < now();
  insert into sessoes (token_hash, papel, barbearia_id, expira)
    values (encode(digest(v_tok, 'sha256'), 'hex'), p_papel, p_barb, now() + interval '16 hours');
  return v_tok;
end $$;

create or replace function _sessao(p_token text, out o_papel text, out o_barb bigint)
language plpgsql security definer set search_path = public, extensions as $$
begin
  select s.papel, s.barbearia_id into o_papel, o_barb from sessoes s
   where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.expira > now();
  if o_papel is null then raise exception 'nao_autorizado'; end if;
end $$;

-- situação da mensalidade: isento, ativo (pago), teste, aviso (venceu há até 3 dias), bloqueado
create or replace function _situacao(p_barb bigint, out o_sit text, out o_vence timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare b record;
begin
  select isento, pago_ate, teste_ate into b from barbearias where id = p_barb;
  if not found then o_sit := 'inexistente'; return; end if;
  o_vence := greatest(b.pago_ate, b.teste_ate);       -- greatest ignora valores nulos
  if b.isento then o_sit := 'isento';
  elsif b.pago_ate > now() then o_sit := 'ativo';
  elsif b.teste_ate > now() then o_sit := 'teste';
  elsif o_vence > now() - interval '3 days' then o_sit := 'aviso';
  else o_sit := 'bloqueado';
  end if;
end $$;

create or replace function _nivel(p_barb bigint)
returns int language sql stable security definer set search_path = public as $$
  select p.nivel from barbearias b join planos p on p.codigo = b.plano where b.id = p_barb;
$$;

-- devolve a barbearia da sessão; p_dono = exige o dono; p_nivel = 1 Basic, 2 Pro, 3 Expert
create or replace function _exigir(p_token text, p_dono boolean default false, p_nivel int default 1)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from _sessao(p_token);
  if v.o_papel = 'plataforma' or v.o_barb is null then raise exception 'nao_autorizado'; end if;
  if p_dono and v.o_papel <> 'dono' then raise exception 'so_dono'; end if;
  if not exists (select 1 from barbearias b where b.id = v.o_barb and b.ativo) then raise exception 'barbearia_inativa'; end if;
  if (select o_sit from _situacao(v.o_barb)) = 'bloqueado' then raise exception 'assinatura_vencida'; end if;
  if _nivel(v.o_barb) < p_nivel then raise exception 'plano_insuficiente'; end if;
  return v.o_barb;
end $$;

-- só o dono, mesmo com a mensalidade vencida (para poder pagar)
create or replace function _exigir_conta(p_token text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from _sessao(p_token);
  if v.o_papel <> 'dono' or v.o_barb is null then raise exception 'so_dono'; end if;
  if not exists (select 1 from barbearias b where b.id = v.o_barb and b.ativo) then raise exception 'barbearia_inativa'; end if;
  return v.o_barb;
end $$;

create or replace function _exigir_plat(p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from _sessao(p_token);
  if v.o_papel <> 'plataforma' then raise exception 'nao_autorizado'; end if;
end $$;

-- barbearia ativa e com a mensalidade em dia (para a fila dos clientes)
create or replace function _barb(p_slug text)
returns bigint language sql stable security definer set search_path = public as $$
  select b.id from barbearias b
  where b.slug = lower(btrim(coalesce(p_slug, ''))) and b.ativo
    and (select o_sit from _situacao(b.id)) <> 'bloqueado';
$$;

-- barbearia ativa, mesmo vencida (para o login do dono e do barbeiro)
create or replace function _barb_login(p_slug text)
returns bigint language sql stable security definer set search_path = public as $$
  select b.id from barbearias b where b.slug = lower(btrim(coalesce(p_slug, ''))) and b.ativo;
$$;

create or replace function _cpf_valido(p text)
returns boolean language plpgsql immutable as $$
declare d int[]; s int; r int; i int;
begin
  if p is null or p !~ '^\d{11}$' or p ~ '^(\d)\1{10}$' then return false; end if;
  d := array(select substr(p, g, 1)::int from generate_series(1, 11) g);
  s := 0; for i in 1..9 loop s := s + d[i] * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> d[10] then return false; end if;
  s := 0; for i in 1..10 loop s := s + d[i] * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = d[11];
end $$;

-- chave Pix no formato do DICT: CPF/CNPJ só números, e-mail minúsculo, telefone +55DDNÚMERO, aleatória (UUID)
create or replace function _pix_normalizar(p_tipo text, p_chave text)
returns text language plpgsql immutable as $$
declare c text := btrim(coalesce(p_chave, '')); d text := regexp_replace(coalesce(p_chave, ''), '\D', '', 'g');
begin
  if p_tipo is null or c = '' then return null; end if;
  if p_tipo = 'cpf' then
    if not _cpf_valido(d) then raise exception 'pix_invalido'; end if; return d;
  elsif p_tipo = 'cnpj' then
    if d !~ '^\d{14}$' then raise exception 'pix_invalido'; end if; return d;
  elsif p_tipo = 'email' then
    c := lower(c); if c !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(c) > 77 then raise exception 'pix_invalido'; end if; return c;
  elsif p_tipo = 'telefone' then
    if d ~ '^\d{10,11}$' then d := '55' || d; end if;
    if d !~ '^55\d{10,11}$' then raise exception 'pix_invalido'; end if; return '+' || d;
  elsif p_tipo = 'aleatoria' then
    c := lower(c); if c !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'pix_invalido'; end if; return c;
  end if;
  raise exception 'pix_invalido';
end $$;

revoke execute on function _bloqueio(bigint) from public, anon, authenticated;
revoke execute on function _falhou(bigint) from public, anon, authenticated;
revoke execute on function _novo_token(text, bigint) from public, anon, authenticated;
revoke execute on function _sessao(text) from public, anon, authenticated;
revoke execute on function _situacao(bigint) from public, anon, authenticated;
revoke execute on function _nivel(bigint) from public, anon, authenticated;
revoke execute on function _exigir(text, boolean, int) from public, anon, authenticated;
revoke execute on function _exigir_conta(text) from public, anon, authenticated;
revoke execute on function _exigir_plat(text) from public, anon, authenticated;
revoke execute on function _barb(text) from public, anon, authenticated;
revoke execute on function _barb_login(text) from public, anon, authenticated;
revoke execute on function _cpf_valido(text) from public, anon, authenticated;
revoke execute on function _pix_normalizar(text, text) from public, anon, authenticated;

-- ---------- funções públicas (cliente) ----------
create or replace function info_barbearia(p_slug text)
returns table (nome text, servicos jsonb, min_por_cliente int, tolerancia_min int, plano text, disponivel boolean)
language sql stable security definer set search_path = public as $$
  select b.nome, b.servicos, b.min_por_cliente, b.tolerancia_min, b.plano,
         (select o_sit from _situacao(b.id)) <> 'bloqueado'
  from barbearias b where b.id = _barb_login(p_slug);
$$;

create or replace function fila_publica(p_slug text)
returns table (id bigint, primeiro_nome text, entrada timestamptz, status text)
language sql stable security definer set search_path = public as $$
  select f.id, split_part(f.nome, ' ', 1), f.entrada, f.status
  from fila f where f.barbearia_id = _barb(p_slug) and f.status in ('esperando','chamado')
  order by f.entrada;
$$;

create or replace function entrar_fila(p_slug text, p_tel text, p_nome text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_b bigint := _barb(p_slug);
  v_tel text := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  v_nome text := btrim(coalesce(p_nome, ''));
  v_id bigint;
begin
  if v_b is null then raise exception 'barbearia_nao_encontrada'; end if;
  if v_tel !~ '^\d{2}9\d{8}$' then raise exception 'telefone_invalido'; end if;
  if length(v_nome) < 2 or length(v_nome) > 60 then raise exception 'nome_invalido'; end if;
  select f.id into v_id from fila f
   where f.barbearia_id = v_b and f.telefone = v_tel and f.status in ('esperando','chamado') limit 1;
  if v_id is not null then return v_id; end if;
  if (select count(*) from fila where barbearia_id = v_b and status in ('esperando','chamado')) >= 40 then
    raise exception 'fila_cheia';
  end if;
  insert into clientes (barbearia_id, telefone, nome) values (v_b, v_tel, v_nome)
    on conflict (barbearia_id, telefone) do update set nome = excluded.nome;
  insert into fila (barbearia_id, telefone, nome) values (v_b, v_tel, v_nome) returning id into v_id;
  return v_id;
end $$;

create or replace function buscar_cliente(p_slug text, p_tel text)
returns table (nome text, visitas int, ultima_visita timestamptz)
language sql stable security definer set search_path = public as $$
  select c.nome, c.visitas, c.ultima_visita from clientes c
  where c.barbearia_id = _barb(p_slug)
    and c.telefone = regexp_replace(coalesce(p_tel, ''), '\D', '', 'g') limit 1;
$$;

create or replace function sair_fila(p_slug text, p_id bigint, p_tel text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fila set status = 'removido'
  where id = p_id and barbearia_id = _barb(p_slug)
    and telefone = regexp_replace(coalesce(p_tel, ''), '\D', '', 'g')
    and status in ('esperando','chamado');
end $$;

-- ---------- área restrita (dono e barbeiro de cada barbearia) ----------
create or replace function adm_login(p_slug text, p_pin text)
returns table (out_papel text, out_token text)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _barb_login(p_slug); v_dono text; v_barb text; v_papel text;
begin
  if v_b is null then raise exception 'barbearia_nao_encontrada'; end if;
  perform _bloqueio(v_b);
  select b.pin_dono, b.pin_barbeiro into v_dono, v_barb from barbearias b where b.id = v_b;
  if p_pin is not null and v_dono = crypt(p_pin, v_dono) then v_papel := 'dono';
  elsif p_pin is not null and v_barb = crypt(p_pin, v_barb) then v_papel := 'barbeiro';
  end if;
  if v_papel is null then perform _falhou(v_b); return; end if;   -- sem erro: a tentativa fica registrada
  return query select v_papel, _novo_token(v_papel, v_b);
end $$;

create or replace function adm_sair(p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from sessoes where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
end $$;

-- plano e situação da mensalidade (dono e barbeiro; funciona mesmo vencida)
create or replace function adm_conta(p_token text)
returns table (papel text, plano text, nivel int, isento boolean, situacao text, vence_em timestamptz,
               mp_status text, tem_assinatura boolean, cidade text, pix_tipo text, pix_chave text, pix_nome text,
               aviso_global text)
language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from _sessao(p_token);
  if v.o_papel = 'plataforma' or v.o_barb is null then raise exception 'nao_autorizado'; end if;
  return query
    select v.o_papel, b.plano, p.nivel, b.isento, s.o_sit, s.o_vence, b.mp_status, b.mp_assinatura_id is not null,
           b.cidade, b.pix_tipo, b.pix_chave, b.pix_nome,
           (select c.valor from config c where c.chave = 'aviso_global'
              and coalesce((select (c2.valor)::timestamptz from config c2 where c2.chave = 'aviso_global_ate'), 'infinity') > now())
    from barbearias b join planos p on p.codigo = b.plano, _situacao(b.id) s
    where b.id = v.o_barb and b.ativo;
  if not found then raise exception 'barbearia_inativa'; end if;
end $$;

create or replace function planos_lista()
returns table (codigo text, nome text, preco numeric, nivel int)
language sql stable security definer set search_path = public as $$
  select codigo, nome, preco, nivel from planos order by nivel;
$$;

create or replace function adm_fila(p_token text)
returns table (id bigint, telefone text, nome text, status text, entrada timestamptz,
               chamado_em timestamptz, visitas int, ultima_visita timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token);
begin
  return query
    select f.id, f.telefone, f.nome, f.status, f.entrada, f.chamado_em,
           coalesce(c.visitas, 0), c.ultima_visita
    from fila f left join clientes c on c.barbearia_id = f.barbearia_id and c.telefone = f.telefone
    where f.barbearia_id = v_b and f.status in ('esperando','chamado') order by f.entrada;
end $$;

create or replace function adm_chamar(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token);
begin
  update fila set status = 'chamado', chamado_em = now()
   where id = p_id and barbearia_id = v_b and status in ('esperando','chamado');
end $$;

create or replace function adm_remover(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token);
begin
  update fila set status = 'removido'
   where id = p_id and barbearia_id = v_b and status in ('esperando','chamado');
end $$;

create or replace function adm_finalizar(p_token text, p_id bigint, p_servico text, p_valor numeric,
                                         p_profissional bigint default null, p_forma text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token); v_tel text;
begin
  if p_valor is null or p_valor < 0 or p_valor > 100000 then raise exception 'valor_invalido'; end if;
  if p_forma is not null and p_forma not in ('dinheiro','pix','cartao') then raise exception 'forma_invalida'; end if;
  if p_profissional is not null and not exists
     (select 1 from profissionais where id = p_profissional and barbearia_id = v_b and ativo) then
    raise exception 'profissional_invalido';
  end if;
  update fila set status = 'atendido', servico = nullif(btrim(coalesce(p_servico, '')), ''),
                  valor = round(p_valor, 2), finalizado_em = now(), profissional_id = p_profissional,
                  forma_pagamento = p_forma
   where id = p_id and barbearia_id = v_b and status in ('esperando','chamado')
   returning telefone into v_tel;
  if v_tel is null then raise exception 'nao_encontrado'; end if;
  update clientes set visitas = visitas + 1, ultima_visita = now()
   where barbearia_id = v_b and telefone = v_tel;
end $$;

-- faturamento e clientes: plano Pro ou Expert
create or replace function adm_atendimentos(p_token text)
returns table (id bigint, telefone text, nome text, servico text, valor numeric, finalizado_em timestamptz,
               profissional_id bigint, forma_pagamento text)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, false, 2);
begin
  return query
    select f.id, f.telefone, f.nome, f.servico, f.valor, f.finalizado_em, f.profissional_id, f.forma_pagamento
    from fila f where f.barbearia_id = v_b and f.status = 'atendido' and f.finalizado_em is not null
    order by f.finalizado_em desc limit 10000;
end $$;

-- lista curta dos profissionais (para escolher quem atendeu): Pro ou Expert, dono ou barbeiro
create or replace function adm_profissionais(p_token text)
returns table (id bigint, nome text, ativo boolean, nome_completo text, pix_chave text, recebe_direto boolean)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, false, 2);
begin
  return query select p.id, coalesce(p.apelido, split_part(p.nome, ' ', 1)), p.ativo, p.nome,
                      p.pix_chave, p.recebe_direto and p.pix_chave is not null
    from profissionais p where p.barbearia_id = v_b order by p.ativo desc, p.nome;
end $$;

-- ---------- só o dono da barbearia ----------
create or replace function dono_editar_valor(p_token text, p_id bigint, p_valor numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 2);
begin
  if p_valor is null or p_valor < 0 or p_valor > 100000 then raise exception 'valor_invalido'; end if;
  update fila set valor = round(p_valor, 2) where id = p_id and barbearia_id = v_b and status = 'atendido';
end $$;

create or replace function dono_excluir_atendimento(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 2); v_tel text;
begin
  update fila set status = 'removido' where id = p_id and barbearia_id = v_b and status = 'atendido'
    returning telefone into v_tel;
  if v_tel is not null then
    update clientes c set
      visitas = (select count(*) from fila f where f.barbearia_id = v_b and f.telefone = c.telefone and f.status = 'atendido'),
      ultima_visita = (select max(f.finalizado_em) from fila f where f.barbearia_id = v_b and f.telefone = c.telefone and f.status = 'atendido')
    where c.barbearia_id = v_b and c.telefone = v_tel;
  end if;
end $$;

create or replace function dono_trocar_pin(p_token text, p_quem text, p_novo text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir_conta(p_token); v_outro text;
begin
  if p_quem not in ('dono','barbeiro') then raise exception 'quem_invalido'; end if;
  if p_novo is null or length(p_novo) < 6 or length(p_novo) > 64 then raise exception 'senha_curta'; end if;
  select case when p_quem = 'dono' then pin_barbeiro else pin_dono end into v_outro from barbearias where id = v_b;
  if crypt(p_novo, v_outro) = v_outro then raise exception 'senha_repetida'; end if;
  if p_quem = 'dono' then update barbearias set pin_dono = crypt(p_novo, gen_salt('bf')) where id = v_b;
  else update barbearias set pin_barbeiro = crypt(p_novo, gen_salt('bf')) where id = v_b; end if;
  delete from sessoes where barbearia_id = v_b and papel = p_quem;
end $$;

-- nome, serviços/preços e tempos da barbearia
create or replace function dono_ajustes(p_token text, p_nome text, p_servicos jsonb, p_min int, p_tol int,
                                        p_cidade text default null, p_pix_tipo text default null,
                                        p_pix_chave text default null, p_pix_nome text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true); s jsonb; v_chave text := _pix_normalizar(p_pix_tipo, p_pix_chave);
begin
  if p_cidade is not null and length(btrim(p_cidade)) not between 2 and 40 then raise exception 'cidade_invalida'; end if;
  if v_chave is not null and length(btrim(coalesce(p_pix_nome, ''))) not between 2 and 60 then raise exception 'pix_nome'; end if;
  update barbearias set cidade = coalesce(nullif(btrim(p_cidade), ''), cidade),
    pix_tipo = case when v_chave is null then null else p_pix_tipo end,
    pix_chave = v_chave, pix_nome = case when v_chave is null then null else btrim(p_pix_nome) end
  where id = v_b;
  if length(btrim(coalesce(p_nome, ''))) not between 2 and 60 then raise exception 'nome_invalido'; end if;
  if p_min is null or p_min not between 5 and 240 or p_tol is null or p_tol not between 1 and 60 then
    raise exception 'ajuste_invalido';
  end if;
  if jsonb_typeof(p_servicos) <> 'array' or jsonb_array_length(p_servicos) not between 1 and 20 then
    raise exception 'servicos_invalidos';
  end if;
  for s in select * from jsonb_array_elements(p_servicos) loop
    if jsonb_typeof(s->'nome') <> 'string' or length(btrim(s->>'nome')) not between 1 and 40
       or jsonb_typeof(s->'preco') <> 'number' or (s->>'preco')::numeric not between 0 and 10000 then
      raise exception 'servicos_invalidos';
    end if;
  end loop;
  update barbearias set nome = btrim(p_nome), servicos = p_servicos, min_por_cliente = p_min, tolerancia_min = p_tol
   where id = v_b;
end $$;

-- profissionais: cadastro completo (Pro ou Expert, só o dono)
create or replace function dono_profissionais(p_token text)
returns setof profissionais
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 2);
begin
  return query select * from profissionais where barbearia_id = v_b order by ativo desc, nome;
end $$;

create or replace function dono_salvar_profissional(p_token text, p jsonb)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b bigint := _exigir(p_token, true, 2);
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_cpf text := regexp_replace(coalesce(p->>'cpf', ''), '\D', '', 'g');
  v_nasc date;
  v_tipo text := p->>'tipo';
  v_ativo boolean := coalesce((p->>'ativo')::boolean, true);
  v_pct numeric; v_alug numeric; v_per text; v_sal numeric;
  v_pix text := _pix_normalizar(nullif(p->>'pix_tipo', ''), p->>'pix_chave');
  v_direto boolean := coalesce((p->>'recebe_direto')::boolean, false) and v_pix is not null;
begin
  begin v_nasc := (p->>'nascimento')::date; exception when others then raise exception 'nascimento_invalido'; end;
  if v_nasc is null or v_nasc > current_date - interval '14 years' or v_nasc < current_date - interval '100 years' then
    raise exception 'nascimento_invalido';
  end if;
  if not _cpf_valido(v_cpf) then raise exception 'cpf_invalido'; end if;
  if exists (select 1 from profissionais where barbearia_id = v_b and cpf = v_cpf and id is distinct from v_id) then
    raise exception 'cpf_repetido';
  end if;
  if length(btrim(coalesce(p->>'nome', ''))) < 5 or position(' ' in btrim(p->>'nome')) = 0 then
    raise exception 'nome_completo';
  end if;
  if v_tipo not in ('comissao','aluguel','aluguel_comissao','salario','nenhum') then raise exception 'tipo_invalido'; end if;
  if v_tipo in ('comissao','aluguel_comissao') then
    v_pct := (p->>'comissao_pct')::numeric;
    if v_pct is null or v_pct not between 0 and 100 then raise exception 'comissao_invalida'; end if;
  end if;
  if v_tipo in ('aluguel','aluguel_comissao') then
    v_alug := (p->>'aluguel_valor')::numeric; v_per := p->>'aluguel_periodo';
    if v_alug is null or v_alug <= 0 or v_per not in ('semanal','mensal') then raise exception 'aluguel_invalido'; end if;
  end if;
  if v_tipo = 'salario' then
    v_sal := (p->>'salario')::numeric;
    if v_sal is null or v_sal <= 0 then raise exception 'salario_invalido'; end if;
  end if;
  if v_id is null then
    insert into profissionais (barbearia_id, nome, apelido, cpf, nascimento, telefone, email, pix_tipo, pix_chave,
                               recebe_direto, endereco, funcao,
                               tipo, comissao_pct, aluguel_valor, aluguel_periodo, salario, inicio, ativo, obs)
    values (v_b, btrim(p->>'nome'), nullif(btrim(p->>'apelido'), ''), v_cpf, v_nasc,
            nullif(regexp_replace(coalesce(p->>'telefone', ''), '\D', '', 'g'), ''),
            nullif(lower(btrim(p->>'email')), ''),
            case when v_pix is null then null else p->>'pix_tipo' end, v_pix, v_direto,
            nullif(btrim(p->>'endereco'), ''),
            coalesce(nullif(btrim(p->>'funcao'), ''), 'Barbeiro'),
            v_tipo, v_pct, v_alug, v_per, v_sal, coalesce((p->>'inicio')::date, current_date), true, nullif(btrim(p->>'obs'), ''))
    returning id into v_id;
  else
    update profissionais set nome = btrim(p->>'nome'), apelido = nullif(btrim(p->>'apelido'), ''), cpf = v_cpf,
      nascimento = v_nasc, telefone = nullif(regexp_replace(coalesce(p->>'telefone', ''), '\D', '', 'g'), ''),
      email = nullif(lower(btrim(p->>'email')), ''),
      pix_tipo = case when v_pix is null then null else p->>'pix_tipo' end, pix_chave = v_pix, recebe_direto = v_direto,
      endereco = nullif(btrim(p->>'endereco'), ''), funcao = coalesce(nullif(btrim(p->>'funcao'), ''), 'Barbeiro'),
      tipo = v_tipo, comissao_pct = v_pct, aluguel_valor = v_alug, aluguel_periodo = v_per, salario = v_sal,
      inicio = coalesce((p->>'inicio')::date, inicio), obs = nullif(btrim(p->>'obs'), ''),
      saida = case when v_ativo then null else coalesce(saida, current_date) end,
      ativo = v_ativo
    where id = v_id and barbearia_id = v_b;
    if not found then raise exception 'nao_encontrado'; end if;
  end if;
  return v_id;
end $$;

-- despesas: Expert, só o dono
create or replace function dono_despesas(p_token text)
returns table (id bigint, data date, categoria text, descricao text, valor numeric)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 3);
begin
  return query select d.id, d.data, d.categoria, d.descricao, d.valor from despesas d
    where d.barbearia_id = v_b and d.data >= (date_trunc('year', current_date) - interval '2 years')::date
    order by d.data desc, d.id desc limit 10000;
end $$;

create or replace function dono_salvar_despesa(p_token text, p_id bigint, p_data date, p_categoria text,
                                               p_descricao text, p_valor numeric)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 3); v_id bigint;
begin
  if p_data is null or p_data > current_date + 366 or p_data < current_date - 3660 then raise exception 'data_invalida'; end if;
  if length(btrim(coalesce(p_categoria, ''))) not between 2 and 40 then raise exception 'categoria_invalida'; end if;
  if p_valor is null or p_valor <= 0 or p_valor > 1000000 then raise exception 'valor_invalido'; end if;
  if p_id is null then
    insert into despesas (barbearia_id, data, categoria, descricao, valor)
    values (v_b, p_data, btrim(p_categoria), nullif(btrim(coalesce(p_descricao, '')), ''), round(p_valor, 2))
    returning id into v_id;
  else
    update despesas set data = p_data, categoria = btrim(p_categoria),
      descricao = nullif(btrim(coalesce(p_descricao, '')), ''), valor = round(p_valor, 2)
    where id = p_id and barbearia_id = v_b returning id into v_id;
    if v_id is null then raise exception 'nao_encontrado'; end if;
  end if;
  return v_id;
end $$;

create or replace function dono_excluir_despesa(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true, 3);
begin
  delete from despesas where id = p_id and barbearia_id = v_b;
end $$;

-- ---------- plataforma (você: cadastra e gerencia as barbearias) ----------
create or replace function plat_login(p_pin text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_h text;
begin
  perform _bloqueio(null);
  select valor into v_h from config where chave = 'pin_plataforma';
  if p_pin is null or v_h is null or v_h <> crypt(p_pin, v_h) then perform _falhou(null); return null; end if;
  return _novo_token('plataforma', null);
end $$;

create or replace function plat_listar(p_token text)
returns table (id bigint, slug text, nome text, ativo boolean, criado_em timestamptz, plano text, isento boolean,
               situacao text, vence_em timestamptz, mp_status text,
               clientes bigint, atendimentos_30d bigint, ultimo_atendimento timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  return query
    select b.id, b.slug, b.nome, b.ativo, b.criado_em, b.plano, b.isento, s.o_sit, s.o_vence, b.mp_status,
      (select count(*) from clientes c where c.barbearia_id = b.id),
      (select count(*) from fila f where f.barbearia_id = b.id and f.status = 'atendido'
         and f.finalizado_em > now() - interval '30 days'),
      (select max(f.finalizado_em) from fila f where f.barbearia_id = b.id and f.status = 'atendido')
    from barbearias b, _situacao(b.id) s order by b.criado_em;
end $$;

create or replace function plat_criar(p_token text, p_slug text, p_nome text, p_pin_dono text, p_pin_barbeiro text,
                                      p_plano text default 'pro')
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text := lower(btrim(coalesce(p_slug, '')));
begin
  perform _exigir_plat(p_token);
  if v_slug !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' or v_slug in ('plataforma','barbeiro','dono','admin','entrar','planos') then
    raise exception 'slug_invalido';
  end if;
  if exists (select 1 from barbearias where slug = v_slug) then raise exception 'slug_em_uso'; end if;
  if length(btrim(coalesce(p_nome, ''))) not between 2 and 60 then raise exception 'nome_invalido'; end if;
  if coalesce(length(p_pin_dono), 0) not between 6 and 64 or coalesce(length(p_pin_barbeiro), 0) not between 6 and 64 then
    raise exception 'senha_curta';
  end if;
  if p_pin_dono = p_pin_barbeiro then raise exception 'senha_repetida'; end if;
  if not exists (select 1 from planos where codigo = p_plano) then raise exception 'plano_invalido'; end if;
  insert into barbearias (slug, nome, pin_dono, pin_barbeiro, plano, teste_ate, servicos)
  values (v_slug, btrim(p_nome), crypt(p_pin_dono, gen_salt('bf')), crypt(p_pin_barbeiro, gen_salt('bf')),
          p_plano, now() + interval '2 days',
          coalesce((select valor::jsonb from config where chave = 'servicos_padrao'),
                   '[{"nome":"Corte","preco":35},{"nome":"Barba","preco":25},{"nome":"Corte + Barba","preco":55}]'::jsonb));
end $$;

create or replace function plat_ativar(p_token text, p_id bigint, p_ativo boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  update barbearias set ativo = coalesce(p_ativo, ativo) where id = p_id;
  if p_ativo is false then delete from sessoes where barbearia_id = p_id; end if;
end $$;

-- mudar o plano e marcar/desmarcar isenção
create or replace function plat_plano(p_token text, p_id bigint, p_plano text, p_isento boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  if not exists (select 1 from planos where codigo = p_plano) then raise exception 'plano_invalido'; end if;
  update barbearias set plano = p_plano, isento = coalesce(p_isento, isento) where id = p_id;
  if not found then raise exception 'barbearia_nao_encontrada'; end if;
end $$;

-- pagamento recebido fora do Mercado Pago (ex.: Pix direto): libera N dias
create or replace function plat_liberar(p_token text, p_id bigint, p_dias int, p_valor numeric default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  if p_dias is null or p_dias not between 1 and 400 then raise exception 'dias_invalidos'; end if;
  update barbearias set pago_ate = greatest(coalesce(pago_ate, now()), now()) + make_interval(days => p_dias)
   where id = p_id;
  if not found then raise exception 'barbearia_nao_encontrada'; end if;
  insert into pagamentos (barbearia_id, origem, valor, dias) values (p_id, 'manual', p_valor, p_dias);
end $$;

create or replace function plat_preco(p_token text, p_codigo text, p_preco numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  if p_preco is null or p_preco < 1 or p_preco > 10000 then raise exception 'valor_invalido'; end if;
  update planos set preco = round(p_preco, 2) where codigo = p_codigo;
  if not found then raise exception 'plano_invalido'; end if;
end $$;

-- redefinir a senha de quem esqueceu (dono ou barbeiro de uma barbearia)
create or replace function plat_redefinir(p_token text, p_id bigint, p_quem text, p_novo text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_outro text;
begin
  perform _exigir_plat(p_token);
  if p_quem not in ('dono','barbeiro') then raise exception 'quem_invalido'; end if;
  if p_novo is null or length(p_novo) < 6 or length(p_novo) > 64 then raise exception 'senha_curta'; end if;
  select case when p_quem = 'dono' then pin_barbeiro else pin_dono end into v_outro from barbearias where id = p_id;
  if v_outro is null then raise exception 'barbearia_nao_encontrada'; end if;
  if crypt(p_novo, v_outro) = v_outro then raise exception 'senha_repetida'; end if;
  if p_quem = 'dono' then update barbearias set pin_dono = crypt(p_novo, gen_salt('bf')) where id = p_id;
  else update barbearias set pin_barbeiro = crypt(p_novo, gen_salt('bf')) where id = p_id; end if;
  delete from sessoes where barbearia_id = p_id and papel = p_quem;
end $$;

create or replace function plat_trocar_senha(p_token text, p_novo text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  if p_novo is null or length(p_novo) < 8 or length(p_novo) > 64 then raise exception 'senha_curta_plat'; end if;
  update config set valor = crypt(p_novo, gen_salt('bf')) where chave = 'pin_plataforma';
  delete from sessoes where papel = 'plataforma';
end $$;

-- ---------- Mercado Pago (só as funções do servidor chamam; ninguém pelo site) ----------
-- dados para criar a assinatura: confere se o token é do dono
create or replace function mp_iniciar(p_token text, p_plano text)
returns table (barbearia_id bigint, slug text, nome text, plano text, plano_nome text, preco numeric,
               assinatura_atual text, pendente text)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir_conta(p_token);
begin
  if not exists (select 1 from planos where codigo = p_plano) then raise exception 'plano_invalido'; end if;
  if (select isento from barbearias where id = v_b) then raise exception 'isento'; end if;
  return query select b.id, b.slug, b.nome, p.codigo, p.nome, p.preco, b.mp_assinatura_id, b.mp_pendente_id
    from barbearias b, planos p where b.id = v_b and p.codigo = p_plano;
end $$;

create or replace function mp_guardar_pendente(p_barb bigint, p_id text)
returns void language sql security definer set search_path = public as $$
  update barbearias set mp_pendente_id = p_id where id = p_barb;
$$;

-- atualização de uma assinatura (vinda do Mercado Pago). Devolve a assinatura antiga a cancelar, se houver.
create or replace function mp_assinatura(p_barb bigint, p_id text, p_status text, p_plano text)
returns text language plpgsql security definer set search_path = public as $$
declare v_antiga text;
begin
  select mp_assinatura_id into v_antiga from barbearias where id = p_barb;
  if not found then return null; end if;
  if p_status = 'authorized' then
    update barbearias set mp_assinatura_id = p_id, mp_status = p_status,
      plano = case when exists (select 1 from planos where codigo = p_plano) then p_plano else plano end,
      mp_pendente_id = case when mp_pendente_id = p_id then null else mp_pendente_id end
    where id = p_barb;
    return case when v_antiga is not null and v_antiga <> p_id then v_antiga end;
  end if;
  if v_antiga = p_id then update barbearias set mp_status = p_status where id = p_barb; end if;
  return null;
end $$;

-- mensalidade paga (vinda do Mercado Pago): libera mais 1 mês, uma vez por pagamento
create or replace function mp_pagamento(p_barb bigint, p_ref text, p_valor numeric)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from barbearias where id = p_barb) then return false; end if;
  insert into pagamentos (barbearia_id, origem, ref, valor, dias) values (p_barb, 'mercadopago', p_ref, p_valor, 30)
    on conflict (ref) do nothing;
  if not found then return false; end if;
  update barbearias set pago_ate = greatest(coalesce(pago_ate, now()), now()) + interval '1 month'
   where id = p_barb;
  return true;
end $$;

-- assinatura da barbearia, para o dono cancelar
create or replace function mp_assinatura_do_dono(p_token text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir_conta(p_token);
begin
  return (select mp_assinatura_id from barbearias where id = v_b);
end $$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
end $$;
revoke execute on function mp_iniciar(text, text) from public, anon, authenticated;
revoke execute on function mp_guardar_pendente(bigint, text) from public, anon, authenticated;
revoke execute on function mp_assinatura(bigint, text, text, text) from public, anon, authenticated;
revoke execute on function mp_pagamento(bigint, text, numeric) from public, anon, authenticated;
revoke execute on function mp_assinatura_do_dono(text) from public, anon, authenticated;
grant execute on function mp_iniciar(text, text) to service_role;
grant execute on function mp_guardar_pendente(bigint, text) to service_role;
grant execute on function mp_assinatura(bigint, text, text, text) to service_role;
grant execute on function mp_pagamento(bigint, text, numeric) to service_role;
grant execute on function mp_assinatura_do_dono(text) to service_role;

-- =====================================================================
-- LGPD: dados dos COMPRADORES (responsáveis pelas barbearias assinantes)
-- Usado só pelo painel de administrador (via conector do Supabase, como dono do projeto).
-- Base legal: execução de contrato (Lei 13.709/2018, art. 7º, V).
-- Princípios aplicados: necessidade (art. 6º, III), segurança (art. 6º, VII; art. 46),
-- responsabilização (art. 6º, X) e registro das operações (art. 37).
-- Clientes e profissionais de cada barbearia: a barbearia é a controladora;
-- o painel mostra só quantidades, nunca esses dados pessoais.
-- =====================================================================
alter table barbearias
  add column if not exists resp_nome text check (resp_nome is null or length(btrim(resp_nome)) between 5 and 100),
  add column if not exists resp_doc_tipo text check (resp_doc_tipo is null or resp_doc_tipo in ('cpf','cnpj')),
  add column if not exists resp_doc text check (resp_doc is null or resp_doc ~ '^\d{11}$|^\d{14}$'),
  add column if not exists resp_telefone text check (resp_telefone is null or resp_telefone ~ '^\d{10,11}$'),
  add column if not exists resp_email text check (resp_email is null or resp_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column if not exists endereco text check (endereco is null or length(endereco) <= 200),
  add column if not exists resp_atualizado_em timestamptz,
  add column if not exists dados_anonimizados_em timestamptz;

create table if not exists log_lgpd (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),
  acao text not null,
  barbearia_id bigint,
  motivo text,
  detalhe text
);
alter table log_lgpd enable row level security;
revoke all on log_lgpd from anon, authenticated;

create or replace function _cnpj_valido(p text)
returns boolean language plpgsql immutable as $$
declare d int[]; s int; r int; i int; p1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2]; p2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
begin
  if p is null or p !~ '^\d{14}$' or p ~ '^(\d)\1{13}$' then return false; end if;
  d := array(select substr(p, g, 1)::int from generate_series(1, 14) g);
  s := 0; for i in 1..12 loop s := s + d[i] * p1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> d[13] then return false; end if;
  s := 0; for i in 1..13 loop s := s + d[i] * p2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = d[14];
end $$;

create or replace function _mask_nome(p text) returns text language sql immutable as $$
  select case when p is null then null else
    split_part(btrim(p), ' ', 1) || coalesce(' ' || (select string_agg(left(w, 1) || '.', ' ')
      from unnest((regexp_split_to_array(btrim(p), '\s+'))[2:]) w where length(w) > 2), '') end;
$$;
create or replace function _mask_doc(p text) returns text language sql immutable as $$
  select case when p is null then null
    when length(p) = 11 then '***.' || substr(p, 4, 3) || '.' || substr(p, 7, 3) || '-**'
    else '**.***.' || substr(p, 6, 3) || '/' || substr(p, 9, 4) || '-**' end;
$$;
create or replace function _mask_tel(p text) returns text language sql immutable as $$
  select case when p is null then null else '(' || left(p, 2) || ') *****-' || right(p, 4) end;
$$;
create or replace function _mask_email(p text) returns text language sql immutable as $$
  select case when p is null then null else left(p, 1) || '***@' || split_part(p, '@', 2) end;
$$;

create or replace function _lgpd_log(p_acao text, p_barb bigint, p_motivo text, p_detalhe text default null)
returns void language sql security definer set search_path = public as $$
  insert into log_lgpd (acao, barbearia_id, motivo, detalhe) values (p_acao, p_barb, nullif(btrim(coalesce(p_motivo, '')), ''), p_detalhe);
$$;

-- lista de compradores com dados pessoais mascarados e sem nenhum valor em dinheiro
create or replace function lgpd_painel()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  select jsonb_build_object('gerado_em', now(), 'compradores', coalesce(jsonb_agg(x order by (x->>'criado_em')), '[]'::jsonb)) into v
  from (
    select jsonb_build_object(
      'id', b.id, 'slug', b.slug, 'nome', b.nome, 'cidade', b.cidade, 'criado_em', b.criado_em,
      'plano', b.plano, 'isento', b.isento, 'ativo', b.ativo, 'situacao', s.o_sit, 'vence_em', s.o_vence,
      'cobranca_automatica', b.mp_status,
      'resp_nome', _mask_nome(b.resp_nome), 'resp_doc', _mask_doc(b.resp_doc), 'resp_doc_tipo', b.resp_doc_tipo,
      'resp_telefone', _mask_tel(b.resp_telefone), 'resp_email', _mask_email(b.resp_email),
      'tem_endereco', b.endereco is not null, 'tem_dados', b.resp_nome is not null,
      'resp_atualizado_em', b.resp_atualizado_em, 'dados_anonimizados_em', b.dados_anonimizados_em,
      'pix_cadastrado', b.pix_chave is not null,
      'clientes', (select count(*) from clientes c where c.barbearia_id = b.id),
      'profissionais_ativos', (select count(*) from profissionais p where p.barbearia_id = b.id and p.ativo),
      'atendimentos_30d', (select count(*) from fila f where f.barbearia_id = b.id and f.status = 'atendido'
                             and f.finalizado_em > now() - interval '30 days'),
      'ultimo_atendimento', (select max(f.finalizado_em) from fila f where f.barbearia_id = b.id and f.status = 'atendido'),
      'mensalidades_pagas', (select count(*) from pagamentos g where g.barbearia_id = b.id),
      'ultima_mensalidade', (select max(g.pago_em) from pagamentos g where g.barbearia_id = b.id)
    ) x
    from barbearias b, _situacao(b.id) s
  ) t;
  perform _lgpd_log('abriu a lista (dados mascarados)', null, null);
  return v;
end $$;

-- dados completos de um comprador: exige motivo e fica registrado
create or replace function lgpd_revelar(p_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'motivo_obrigatorio'; end if;
  select jsonb_build_object('id', id, 'nome_barbearia', nome, 'resp_nome', resp_nome, 'resp_doc_tipo', resp_doc_tipo,
           'resp_doc', resp_doc, 'resp_telefone', resp_telefone, 'resp_email', resp_email, 'endereco', endereco)
    into v from barbearias where id = p_id;
  if v is null then raise exception 'nao_encontrado'; end if;
  perform _lgpd_log('viu os dados completos', p_id, p_motivo);
  return v;
end $$;

-- correção / cadastro dos dados do responsável (art. 18, III)
create or replace function lgpd_salvar(p_id bigint, p jsonb, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc text := nullif(regexp_replace(coalesce(p->>'resp_doc', ''), '\D', '', 'g'), '');
  v_tipo text := nullif(p->>'resp_doc_tipo', '');
  v_tel text := nullif(regexp_replace(coalesce(p->>'resp_telefone', ''), '\D', '', 'g'), '');
  v_email text := nullif(lower(btrim(coalesce(p->>'resp_email', ''))), '');
  v_nome text := nullif(btrim(coalesce(p->>'resp_nome', '')), '');
begin
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'motivo_obrigatorio'; end if;
  if v_nome is not null and (length(v_nome) < 5 or position(' ' in v_nome) = 0) then raise exception 'nome_completo'; end if;
  if v_doc is not null then
    if v_tipo = 'cpf' and not _cpf_valido(v_doc) then raise exception 'cpf_invalido'; end if;
    if v_tipo = 'cnpj' and not _cnpj_valido(v_doc) then raise exception 'cnpj_invalido'; end if;
    if v_tipo is null or v_tipo not in ('cpf','cnpj') then raise exception 'doc_tipo'; end if;
  end if;
  if v_tel is not null and v_tel !~ '^\d{10,11}$' then raise exception 'telefone_invalido'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email_invalido'; end if;
  update barbearias set resp_nome = v_nome, resp_doc_tipo = case when v_doc is null then null else v_tipo end, resp_doc = v_doc,
    resp_telefone = v_tel, resp_email = v_email, endereco = nullif(btrim(coalesce(p->>'endereco', '')), ''),
    resp_atualizado_em = now()
  where id = p_id;
  if not found then raise exception 'nao_encontrado'; end if;
  perform _lgpd_log('cadastrou/corrigiu dados', p_id, p_motivo);
end $$;

-- cópia dos dados do titular, para atender pedido de acesso ou portabilidade (art. 18, II e V)
create or replace function lgpd_exportar(p_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'motivo_obrigatorio'; end if;
  select jsonb_build_object(
    'gerado_em', now(),
    'controlador', 'Plataforma Fila de Barbearia',
    'finalidade', 'Execução do contrato de assinatura do sistema de fila e gestão (Lei 13.709/2018, art. 7º, V)',
    'titular', jsonb_build_object('nome', b.resp_nome, 'documento_tipo', b.resp_doc_tipo, 'documento', b.resp_doc,
                                  'telefone', b.resp_telefone, 'email', b.resp_email),
    'barbearia', jsonb_build_object('nome', b.nome, 'endereco_no_link', b.slug, 'endereco', b.endereco, 'cidade', b.cidade,
                                    'cadastrada_em', b.criado_em, 'plano', b.plano, 'situacao', s.o_sit, 'pago_ou_teste_ate', s.o_vence),
    'mensalidades', coalesce((select jsonb_agg(jsonb_build_object('data', g.pago_em, 'origem', g.origem) order by g.pago_em)
                               from pagamentos g where g.barbearia_id = b.id), '[]'::jsonb))
  into v from barbearias b, _situacao(b.id) s where b.id = p_id;
  if v is null then raise exception 'nao_encontrado'; end if;
  perform _lgpd_log('exportou os dados do titular', p_id, p_motivo);
  return v;
end $$;

-- eliminação/anonimização dos dados do responsável (art. 18, IV e VI; art. 16)
create or replace function lgpd_anonimizar(p_id bigint, p_motivo text, p_confirmacao text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'motivo_obrigatorio'; end if;
  if not exists (select 1 from barbearias where id = p_id and slug = lower(btrim(coalesce(p_confirmacao, '')))) then
    raise exception 'confirmacao_errada';
  end if;
  update barbearias set resp_nome = null, resp_doc_tipo = null, resp_doc = null, resp_telefone = null, resp_email = null,
    endereco = null, dados_anonimizados_em = now(), resp_atualizado_em = now()
  where id = p_id;
  perform _lgpd_log('anonimizou os dados do responsável', p_id, p_motivo);
end $$;

-- registro das operações (art. 37)
create or replace function lgpd_registro(p_limite int default 100)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('em', l.em, 'acao', l.acao, 'barbearia', b.nome, 'motivo', l.motivo) order by l.em desc), '[]'::jsonb)
  from (select * from log_lgpd order by em desc limit least(greatest(coalesce(p_limite, 100), 1), 500)) l
  left join barbearias b on b.id = l.barbearia_id;
$$;

-- ninguém de fora chama estas funções: só o dono do projeto, pelo conector do Supabase
do $$ declare f text; begin
  foreach f in array array['_cnpj_valido(text)','_mask_nome(text)','_mask_doc(text)','_mask_tel(text)','_mask_email(text)',
    '_lgpd_log(text,bigint,text,text)','lgpd_painel()','lgpd_revelar(bigint,text)','lgpd_salvar(bigint,jsonb,text)',
    'lgpd_exportar(bigint,text)','lgpd_anonimizar(bigint,text,text)','lgpd_registro(int)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon, authenticated, service_role';
  end loop;
end $$;


-- =====================================================================
-- ASSISTENTE DE IA DO ADMINISTRADOR
-- A IA só lê dados sem informação pessoal e sem dinheiro das barbearias,
-- e só PROPÕE mudanças; quem aplica é o administrador, uma por uma.
-- Ações permitidas (todas da plataforma, nunca do que o barbeiro cadastrou):
--   plano, liberar dias, ativar/desativar, isentar, preço dos planos,
--   aviso geral nos painéis, serviços padrão para barbearias NOVAS.
-- =====================================================================
create or replace function ia_barbearias()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'agora', now(),
    'planos', (select jsonb_agg(jsonb_build_object('codigo', codigo, 'nome', nome, 'preco_mensal', preco) order by nivel) from planos),
    'aviso_global', (select valor from config where chave = 'aviso_global'),
    'aviso_global_ate', (select valor from config where chave = 'aviso_global_ate'),
    'servicos_padrao_novas', (select valor::jsonb from config where chave = 'servicos_padrao'),
    'barbearias', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'endereco', b.slug, 'nome', b.nome, 'cidade', b.cidade, 'plano', b.plano, 'isenta', b.isento,
        'ativa', b.ativo, 'situacao', s.o_sit, 'pago_ou_teste_ate', s.o_vence, 'cadastrada_em', b.criado_em,
        'cobranca_automatica', b.mp_status,
        'clientes', (select count(*) from clientes c where c.barbearia_id = b.id),
        'profissionais_ativos', (select count(*) from profissionais p where p.barbearia_id = b.id and p.ativo),
        'atendimentos_30d', (select count(*) from fila f where f.barbearia_id = b.id and f.status = 'atendido'
                               and f.finalizado_em > now() - interval '30 days'))
      order by b.id) from barbearias b, _situacao(b.id) s), '[]'::jsonb));
$$;

create or replace function ia_aplicar(p_acao text, p jsonb, p_resumo text)
returns int language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; n int := 0; v_txt text; v_dias int; s jsonb;
begin
  if p ? 'ids' then
    select array_agg(x::bigint) into v_ids from jsonb_array_elements_text(p->'ids') x;
    if v_ids is null or array_length(v_ids, 1) > 500 then raise exception 'ids_invalidos'; end if;
  end if;
  if p_acao = 'plano' then
    if not exists (select 1 from planos where codigo = p->>'plano') then raise exception 'plano_invalido'; end if;
    update barbearias set plano = p->>'plano' where id = any(v_ids); get diagnostics n = row_count;
  elsif p_acao = 'liberar' then
    v_dias := (p->>'dias')::int; if v_dias is null or v_dias not between 1 and 400 then raise exception 'dias_invalidos'; end if;
    update barbearias set pago_ate = greatest(coalesce(pago_ate, now()), now()) + make_interval(days => v_dias)
     where id = any(v_ids); get diagnostics n = row_count;
    insert into pagamentos (barbearia_id, origem, dias) select unnest(v_ids), 'manual', v_dias;
  elsif p_acao = 'ativar' then
    update barbearias set ativo = (p->>'ativo')::boolean where id = any(v_ids); get diagnostics n = row_count;
    if (p->>'ativo')::boolean is false then delete from sessoes where barbearia_id = any(v_ids); end if;
  elsif p_acao = 'isentar' then
    update barbearias set isento = (p->>'isento')::boolean where id = any(v_ids); get diagnostics n = row_count;
  elsif p_acao = 'preco' then
    if (p->>'preco')::numeric is null or (p->>'preco')::numeric not between 1 and 10000 then raise exception 'valor_invalido'; end if;
    update planos set preco = round((p->>'preco')::numeric, 2) where codigo = p->>'plano'; get diagnostics n = row_count;
  elsif p_acao = 'aviso' then
    v_txt := nullif(btrim(coalesce(p->>'texto', '')), '');
    if v_txt is not null and length(v_txt) > 280 then raise exception 'aviso_longo'; end if;
    delete from config where chave in ('aviso_global', 'aviso_global_ate');
    if v_txt is not null then
      insert into config values ('aviso_global', v_txt);
      if (p->>'dias')::int between 1 and 365 then
        insert into config values ('aviso_global_ate', (now() + make_interval(days => (p->>'dias')::int))::text);
      end if;
    end if;
    n := 1;
  elsif p_acao = 'servicos_padrao' then
    if jsonb_typeof(p->'servicos') <> 'array' or jsonb_array_length(p->'servicos') not between 1 and 20 then raise exception 'servicos_invalidos'; end if;
    for s in select * from jsonb_array_elements(p->'servicos') loop
      if jsonb_typeof(s->'nome') <> 'string' or length(btrim(s->>'nome')) not between 1 and 40
         or jsonb_typeof(s->'preco') <> 'number' or (s->>'preco')::numeric not between 0 and 10000 then
        raise exception 'servicos_invalidos';
      end if;
    end loop;
    insert into config values ('servicos_padrao', (p->'servicos')::text) on conflict (chave) do update set valor = excluded.valor;
    n := 1;
  else
    raise exception 'acao_nao_permitida';
  end if;
  perform _lgpd_log('assistente (aplicado pelo administrador): ' || p_acao, null, left(p_resumo, 300), p::text);
  return n;
end $$;

revoke execute on function ia_barbearias() from public, anon, authenticated, service_role;
revoke execute on function ia_aplicar(text, jsonb, text) from public, anon, authenticated, service_role;


-- =====================================================================
-- CADASTRO PELO PRÓPRIO BARBEIRO (página pública de planos: #/planos)
-- Cria a barbearia com 2 dias grátis. Guarda o aceite da política de privacidade.
-- Limite: 20 cadastros por hora no total, para evitar abuso.
-- =====================================================================
alter table barbearias
  add column if not exists origem text not null default 'plataforma' check (origem in ('plataforma','autocadastro')),
  add column if not exists aceite_privacidade_em timestamptz;

create or replace function cadastro_publico(p jsonb)
returns table (slug text, token text)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nome text := btrim(coalesce(p->>'nome_barbearia', ''));
  v_base text; v_slug text; v_i int := 1;
  v_resp text := btrim(coalesce(p->>'resp_nome', ''));
  v_tel text := regexp_replace(coalesce(p->>'resp_telefone', ''), '\D', '', 'g');
  v_email text := lower(btrim(coalesce(p->>'resp_email', '')));
  v_plano text := 'basic';   -- agendBarber 1.0: só o plano Basic está à venda
  v_pd text := p->>'senha_dono';
  -- 1.0: o barbeiro cria uma senha só; a segunda (de ajudante) é sorteada e pode ser trocada na aba Senhas
  v_pb text := coalesce(nullif(p->>'senha_barbeiro', ''), encode(extensions.gen_random_bytes(12), 'hex'));
  v_cidade text := nullif(btrim(coalesce(p->>'cidade', '')), '');
  v_id bigint;
begin
  if coalesce((p->>'aceite')::boolean, false) is not true then raise exception 'aceite_obrigatorio'; end if;
  if (select count(*) from barbearias where origem = 'autocadastro' and criado_em > now() - interval '1 hour') >= 20 then
    raise exception 'muitos_cadastros';
  end if;
  if length(v_nome) not between 2 and 60 then raise exception 'nome_invalido'; end if;
  if length(v_resp) < 5 or position(' ' in v_resp) = 0 then raise exception 'nome_completo'; end if;
  if v_tel !~ '^\d{10,11}$' then raise exception 'telefone_invalido'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email_invalido'; end if;
  if not exists (select 1 from planos where codigo = v_plano) then raise exception 'plano_invalido'; end if;
  if coalesce(length(v_pd), 0) not between 6 and 64 or coalesce(length(v_pb), 0) not between 6 and 64 then raise exception 'senha_curta'; end if;
  if v_pd = v_pb then raise exception 'senha_repetida'; end if;
  if v_cidade is not null and length(v_cidade) > 40 then raise exception 'cidade_invalida'; end if;
  -- endereço do link a partir do nome, sem acento; se já existir, acrescenta -2, -3...
  v_base := trim(both '-' from regexp_replace(lower(translate(v_nome,
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn')), '[^a-z0-9]+', '-', 'g'));
  v_base := left(v_base, 34);
  if v_base = '' or v_base in ('plataforma','barbeiro','dono','admin','entrar','planos') then v_base := 'barbearia'; end if;
  v_slug := v_base;
  while exists (select 1 from barbearias b where b.slug = v_slug) loop v_i := v_i + 1; v_slug := v_base || '-' || v_i; end loop;
  insert into barbearias (slug, nome, pin_dono, pin_barbeiro, plano, teste_ate, servicos, cidade,
                          resp_nome, resp_telefone, resp_email, resp_atualizado_em, origem, aceite_privacidade_em)
  values (v_slug, v_nome, crypt(v_pd, gen_salt('bf')), crypt(v_pb, gen_salt('bf')), v_plano, now() + interval '2 days',
          coalesce((select valor::jsonb from config where chave = 'servicos_padrao'),
                   '[{"nome":"Corte","preco":35},{"nome":"Barba","preco":25},{"nome":"Corte + Barba","preco":55}]'::jsonb),
          coalesce(v_cidade, 'Rio de Janeiro'), v_resp, v_tel, v_email, now(), 'autocadastro', now())
  returning id into v_id;
  perform _lgpd_log('cadastro feito pelo próprio titular (aceitou a política de privacidade)', v_id, 'autocadastro');
  return query select v_slug, _novo_token('dono', v_id);
end $$;
