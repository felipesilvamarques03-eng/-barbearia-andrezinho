-- =====================================================================
-- Fila de Barbearia: VÁRIAS BARBEARIAS no mesmo banco
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
--
-- Serve para os dois casos:
--  * banco que já tinha a versão de uma barbearia só (Andrezinho):
--    os dados e as senhas atuais passam para a barbearia "andrezinho";
--  * banco novo, vazio.
-- Pode rodar de novo sem problema (o script é repetível).
--
-- Senha da PLATAFORMA (o painel onde você cadastra barbearias):
--  * se já existia a senha do dono, ela vira também a senha da plataforma;
--  * em banco novo, a senha inicial é TROQUE-SENHA-PLATAFORMA (troque no painel).
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

-- senha da plataforma: herda a do dono antigo, se existir
insert into config (chave, valor)
select 'pin_plataforma',
       coalesce((select valor from config where chave = 'pin_dono'),
                extensions.crypt('TROQUE-SENHA-PLATAFORMA', extensions.gen_salt('bf')))
on conflict (chave) do nothing;

-- a barbearia que já existia vira "andrezinho", com as mesmas senhas
insert into barbearias (slug, nome, pin_dono, pin_barbeiro)
select 'andrezinho', 'Barbearia do Andrezinho',
       (select valor from config where chave = 'pin_dono'),
       (select valor from config where chave = 'pin_barbeiro')
where exists (select 1 from config where chave = 'pin_dono')
  and exists (select 1 from config where chave = 'pin_barbeiro')
  and not exists (select 1 from barbearias where slug = 'andrezinho');

delete from config where chave in ('pin_dono', 'pin_barbeiro')
  and exists (select 1 from barbearias where slug = 'andrezinho');

-- ---------- barbearia_id em cada tabela ----------
alter table clientes   add column if not exists barbearia_id bigint references barbearias(id) on delete cascade;
alter table fila       add column if not exists barbearia_id bigint references barbearias(id) on delete cascade;
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

-- ---------- trancar o acesso direto às tabelas ----------
alter table clientes   enable row level security;
alter table fila       enable row level security;
alter table config     enable row level security;
alter table tentativas enable row level security;
alter table sessoes    enable row level security;
alter table barbearias enable row level security;
revoke all on clientes, fila, config, tentativas, sessoes, barbearias from anon, authenticated;

-- ---------- remover as funções da versão de uma barbearia só ----------
drop function if exists _papel(text);
drop function if exists _exigir(text, boolean);
drop function if exists fila_publica();
drop function if exists entrar_fila(text, text);
drop function if exists buscar_cliente(text);
drop function if exists sair_fila(bigint, text);
drop function if exists adm_login(text);

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

-- devolve a barbearia da sessão (dono ou barbeiro); p_dono = exige o dono
create or replace function _exigir(p_token text, p_dono boolean default false)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from _sessao(p_token);
  if v.o_papel = 'plataforma' or v.o_barb is null then raise exception 'nao_autorizado'; end if;
  if p_dono and v.o_papel <> 'dono' then raise exception 'so_dono'; end if;
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

create or replace function _barb(p_slug text)
returns bigint language sql stable security definer set search_path = public as $$
  select b.id from barbearias b where b.slug = lower(btrim(coalesce(p_slug, ''))) and b.ativo;
$$;

revoke execute on function _bloqueio(bigint) from public, anon, authenticated;
revoke execute on function _falhou(bigint) from public, anon, authenticated;
revoke execute on function _novo_token(text, bigint) from public, anon, authenticated;
revoke execute on function _sessao(text) from public, anon, authenticated;
revoke execute on function _exigir(text, boolean) from public, anon, authenticated;
revoke execute on function _exigir_plat(text) from public, anon, authenticated;
revoke execute on function _barb(text) from public, anon, authenticated;

-- ---------- funções públicas (cliente) ----------
create or replace function info_barbearia(p_slug text)
returns table (nome text, servicos jsonb, min_por_cliente int, tolerancia_min int)
language sql stable security definer set search_path = public as $$
  select b.nome, b.servicos, b.min_por_cliente, b.tolerancia_min
  from barbearias b where b.id = _barb(p_slug);
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
declare v_b bigint := _barb(p_slug); v_dono text; v_barb text; v_papel text;
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

create or replace function adm_finalizar(p_token text, p_id bigint, p_servico text, p_valor numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token); v_tel text;
begin
  if p_valor is null or p_valor < 0 or p_valor > 100000 then raise exception 'valor_invalido'; end if;
  update fila set status = 'atendido', servico = nullif(btrim(coalesce(p_servico, '')), ''),
                  valor = round(p_valor, 2), finalizado_em = now()
   where id = p_id and barbearia_id = v_b and status in ('esperando','chamado')
   returning telefone into v_tel;
  if v_tel is null then raise exception 'nao_encontrado'; end if;
  update clientes set visitas = visitas + 1, ultima_visita = now()
   where barbearia_id = v_b and telefone = v_tel;
end $$;

create or replace function adm_atendimentos(p_token text)
returns table (id bigint, telefone text, nome text, servico text, valor numeric, finalizado_em timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token);
begin
  return query
    select f.id, f.telefone, f.nome, f.servico, f.valor, f.finalizado_em
    from fila f where f.barbearia_id = v_b and f.status = 'atendido' and f.finalizado_em is not null
    order by f.finalizado_em desc limit 5000;
end $$;

-- ---------- só o dono da barbearia ----------
create or replace function dono_editar_valor(p_token text, p_id bigint, p_valor numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true);
begin
  if p_valor is null or p_valor < 0 or p_valor > 100000 then raise exception 'valor_invalido'; end if;
  update fila set valor = round(p_valor, 2) where id = p_id and barbearia_id = v_b and status = 'atendido';
end $$;

create or replace function dono_excluir_atendimento(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true); v_tel text;
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
declare v_b bigint := _exigir(p_token, true); v_outro text;
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
create or replace function dono_ajustes(p_token text, p_nome text, p_servicos jsonb, p_min int, p_tol int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_b bigint := _exigir(p_token, true); s jsonb;
begin
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
returns table (id bigint, slug text, nome text, ativo boolean, criado_em timestamptz,
               clientes bigint, atendimentos_30d bigint, ultimo_atendimento timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  return query
    select b.id, b.slug, b.nome, b.ativo, b.criado_em,
      (select count(*) from clientes c where c.barbearia_id = b.id),
      (select count(*) from fila f where f.barbearia_id = b.id and f.status = 'atendido'
         and f.finalizado_em > now() - interval '30 days'),
      (select max(f.finalizado_em) from fila f where f.barbearia_id = b.id and f.status = 'atendido')
    from barbearias b order by b.criado_em;
end $$;

create or replace function plat_criar(p_token text, p_slug text, p_nome text, p_pin_dono text, p_pin_barbeiro text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text := lower(btrim(coalesce(p_slug, '')));
begin
  perform _exigir_plat(p_token);
  if v_slug !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' or v_slug in ('plataforma','barbeiro','dono','admin') then
    raise exception 'slug_invalido';
  end if;
  if exists (select 1 from barbearias where slug = v_slug) then raise exception 'slug_em_uso'; end if;
  if length(btrim(coalesce(p_nome, ''))) not between 2 and 60 then raise exception 'nome_invalido'; end if;
  if coalesce(length(p_pin_dono), 0) not between 6 and 64 or coalesce(length(p_pin_barbeiro), 0) not between 6 and 64 then
    raise exception 'senha_curta';
  end if;
  if p_pin_dono = p_pin_barbeiro then raise exception 'senha_repetida'; end if;
  insert into barbearias (slug, nome, pin_dono, pin_barbeiro)
  values (v_slug, btrim(p_nome), crypt(p_pin_dono, gen_salt('bf')), crypt(p_pin_barbeiro, gen_salt('bf')));
end $$;

create or replace function plat_ativar(p_token text, p_id bigint, p_ativo boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _exigir_plat(p_token);
  update barbearias set ativo = coalesce(p_ativo, ativo) where id = p_id;
  if p_ativo is false then delete from sessoes where barbearia_id = p_id; end if;
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
