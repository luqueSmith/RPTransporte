-- APC Corporacion · Reportes de transporte
-- Ejecutar completo en Supabase > SQL Editor.
-- La web usa un PIN simple de visualización y la APK usa una clave de sincronización propia.
-- IMPORTANTE: no use la service_role/secret key en la web ni en la APK.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.apc_config (
  id integer primary key default 1 check (id = 1),
  viewer_pin_hash text not null,
  write_key_hash text not null,
  owner_name text not null default 'Raul Smith Luque Chumpitaz',
  owner_dni text not null default '72174739',
  company_name text not null default 'APC CORPORACION S.A.',
  company_ruc text not null default '20102185863',
  default_engineer text not null default 'MUÑOZ QUIJANDRÍA, LUIS GUILLERMO',
  updated_at timestamptz not null default now()
);

create table if not exists public.transport_reports (
  id uuid primary key,
  title text not null default 'Reporte de transporte',
  period_start date not null,
  period_end date,
  status text not null default 'draft' check (status in ('draft','submitted','approved','correction_requested')),
  owner_name text not null,
  owner_dni text not null,
  company_name text not null,
  company_ruc text not null,
  engineer_name text,
  boss_note text not null default '',
  reviewed_by text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transport_entries (
  id uuid primary key,
  report_id uuid not null references public.transport_reports(id) on delete cascade,
  entry_type text not null check (entry_type in ('credit','expense')),
  entry_date date not null,
  direction text,
  origin text,
  destination text,
  detail text not null default '',
  amount numeric(12,2) not null check (amount >= 0),
  issue_time text,
  support_type text not null default 'none' check (support_type in ('none','receipt','declaration','receipt_declaration')),
  declaration_reason text,
  declaration_place_date text,
  engineer_name text,
  receipt_image_base64 text,
  receipt_mime text,
  signature_base64 text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_transport_reports_period on public.transport_reports(period_start desc);
create index if not exists idx_transport_entries_report on public.transport_entries(report_id, entry_date, created_at);

alter table public.apc_config enable row level security;
alter table public.transport_reports enable row level security;
alter table public.transport_entries enable row level security;

-- Bloqueamos el acceso directo a tablas desde clientes. La app y la web trabajan solo mediante RPC.
revoke all on table public.apc_config from anon, authenticated;
revoke all on table public.transport_reports from anon, authenticated;
revoke all on table public.transport_entries from anon, authenticated;

-- Configuración inicial.
-- PIN del ingeniero para la web: 2026
-- Clave interna de sincronización de la APK: se incluye también en SupabaseSync.java.
insert into public.apc_config (
  id, viewer_pin_hash, write_key_hash, owner_name, owner_dni, company_name, company_ruc, default_engineer
) values (
  1,
  extensions.crypt('2026', extensions.gen_salt('bf')),
  extensions.crypt('YP1BO9IZzGgZJtAEfxVhNFFhdEsERMa2_V8lKDDn16c', extensions.gen_salt('bf')),
  'Raul Smith Luque Chumpitaz',
  '72174739',
  'APC CORPORACION S.A.',
  '20102185863',
  'MUÑOZ QUIJANDRÍA, LUIS GUILLERMO'
)
on conflict (id) do update set
  viewer_pin_hash = excluded.viewer_pin_hash,
  write_key_hash = excluded.write_key_hash,
  owner_name = excluded.owner_name,
  owner_dni = excluded.owner_dni,
  company_name = excluded.company_name,
  company_ruc = excluded.company_ruc,
  default_engineer = excluded.default_engineer,
  updated_at = now();

create or replace function public.apc_pin_ok(p_pin text)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.apc_config c
    where c.id = 1
      and c.viewer_pin_hash = extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash)
  );
$$;

create or replace function public.apc_write_key_ok(p_key text)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.apc_config c
    where c.id = 1
      and c.write_key_hash = extensions.crypt(coalesce(p_key,''), c.write_key_hash)
  );
$$;

create or replace function public.apc_login(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id = 1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object(
    'ok', true,
    'owner_name', c.owner_name,
    'company_name', c.company_name,
    'default_engineer', c.default_engineer
  );
end;
$$;

create or replace function public.apc_sync_report(
  p_write_key text,
  p_report jsonb,
  p_entries jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  v_report_id uuid;
  v_entry jsonb;
  v_entry_ids uuid[] := '{}'::uuid[];
begin
  select * into c from public.apc_config where id = 1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave de sincronización inválida';
  end if;

  v_report_id := (p_report->>'id')::uuid;

  insert into public.transport_reports (
    id, title, period_start, period_end, status,
    owner_name, owner_dni, company_name, company_ruc, engineer_name, updated_at
  ) values (
    v_report_id,
    coalesce(nullif(p_report->>'title',''), 'Reporte de transporte'),
    (p_report->>'period_start')::date,
    nullif(p_report->>'period_end','')::date,
    coalesce(nullif(p_report->>'status',''),'draft'),
    coalesce(nullif(p_report->>'owner_name',''), c.owner_name),
    coalesce(nullif(p_report->>'owner_dni',''), c.owner_dni),
    coalesce(nullif(p_report->>'company_name',''), c.company_name),
    coalesce(nullif(p_report->>'company_ruc',''), c.company_ruc),
    coalesce(nullif(p_report->>'engineer_name',''), c.default_engineer),
    now()
  )
  on conflict (id) do update set
    title = excluded.title,
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    status = case
      when public.transport_reports.status = 'approved' and excluded.status = 'draft' then 'approved'
      else excluded.status
    end,
    owner_name = excluded.owner_name,
    owner_dni = excluded.owner_dni,
    company_name = excluded.company_name,
    company_ruc = excluded.company_ruc,
    engineer_name = excluded.engineer_name,
    updated_at = now();

  if jsonb_typeof(coalesce(p_entries,'[]'::jsonb)) = 'array' then
    for v_entry in select * from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb))
    loop
      v_entry_ids := array_append(v_entry_ids, (v_entry->>'id')::uuid);
      insert into public.transport_entries (
        id, report_id, entry_type, entry_date, direction, origin, destination, detail, amount,
        issue_time, support_type, declaration_reason, declaration_place_date, engineer_name,
        receipt_image_base64, receipt_mime, signature_base64, updated_at
      ) values (
        (v_entry->>'id')::uuid,
        v_report_id,
        lower(v_entry->>'entry_type'),
        (v_entry->>'entry_date')::date,
        nullif(v_entry->>'direction',''),
        nullif(v_entry->>'origin',''),
        nullif(v_entry->>'destination',''),
        coalesce(v_entry->>'detail',''),
        coalesce((v_entry->>'amount')::numeric,0),
        nullif(v_entry->>'issue_time',''),
        coalesce(nullif(v_entry->>'support_type',''),'none'),
        nullif(v_entry->>'declaration_reason',''),
        nullif(v_entry->>'declaration_place_date',''),
        nullif(v_entry->>'engineer_name',''),
        nullif(v_entry->>'receipt_image_base64',''),
        nullif(v_entry->>'receipt_mime',''),
        nullif(v_entry->>'signature_base64',''),
        now()
      )
      on conflict (id) do update set
        report_id = excluded.report_id,
        entry_type = excluded.entry_type,
        entry_date = excluded.entry_date,
        direction = excluded.direction,
        origin = excluded.origin,
        destination = excluded.destination,
        detail = excluded.detail,
        amount = excluded.amount,
        issue_time = excluded.issue_time,
        support_type = excluded.support_type,
        declaration_reason = excluded.declaration_reason,
        declaration_place_date = excluded.declaration_place_date,
        engineer_name = excluded.engineer_name,
        receipt_image_base64 = excluded.receipt_image_base64,
        receipt_mime = excluded.receipt_mime,
        signature_base64 = excluded.signature_base64,
        updated_at = now();
    end loop;
  end if;

  if cardinality(v_entry_ids) = 0 then
    delete from public.transport_entries where report_id = v_report_id;
  else
    delete from public.transport_entries
      where report_id = v_report_id
        and not (id = any(v_entry_ids));
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'synced_at', now());
end;
$$;

create or replace function public.apc_list_reports(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  result jsonb;
begin
  select * into c from public.apc_config where id = 1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select coalesce(jsonb_agg(x order by x.period_start desc, x.created_at desc), '[]'::jsonb)
  into result
  from (
    select
      r.id, r.title, r.period_start, r.period_end, r.status,
      r.boss_note, r.reviewed_by, r.reviewed_at, r.created_at, r.updated_at,
      coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) as received,
      coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) as spent,
      (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)
       - coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2) as balance,
      count(e.id)::integer as movement_count
    from public.transport_reports r
    left join public.transport_entries e on e.report_id = r.id
    group by r.id
  ) x;

  return result;
end;
$$;

create or replace function public.apc_get_report(p_pin text, p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  r public.transport_reports%rowtype;
  entries_json jsonb;
  received numeric(12,2);
  spent numeric(12,2);
begin
  select * into c from public.apc_config where id = 1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select * into r from public.transport_reports where id = p_report_id;
  if r.id is null then raise exception 'Reporte no encontrado'; end if;

  select
    coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date, e.created_at), '[]'::jsonb),
    coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0),
    coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)
  into entries_json, received, spent
  from public.transport_entries e
  where e.report_id = p_report_id;

  return jsonb_build_object(
    'report', to_jsonb(r),
    'summary', jsonb_build_object('received', received, 'spent', spent, 'balance', received-spent),
    'entries', entries_json
  );
end;
$$;

create or replace function public.apc_review_report(
  p_pin text,
  p_report_id uuid,
  p_action text,
  p_note text default '',
  p_reviewed_by text default 'Luis Guillermo Muñoz Quijandría'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  new_status text;
begin
  select * into c from public.apc_config where id = 1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  new_status := case lower(p_action)
    when 'approve' then 'approved'
    when 'correction' then 'correction_requested'
    else null
  end;
  if new_status is null then raise exception 'Acción inválida'; end if;

  update public.transport_reports
  set status = new_status,
      boss_note = coalesce(p_note,''),
      reviewed_by = nullif(p_reviewed_by,''),
      reviewed_at = now(),
      updated_at = now()
  where id = p_report_id;

  if not found then raise exception 'Reporte no encontrado'; end if;
  return jsonb_build_object('ok', true, 'status', new_status, 'reviewed_at', now());
end;
$$;

create or replace function public.apc_set_viewer_pin(p_write_key text, p_new_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id = 1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave de sincronización inválida';
  end if;
  if length(coalesce(p_new_pin,'')) < 4 then raise exception 'El PIN debe tener al menos 4 caracteres'; end if;
  update public.apc_config
    set viewer_pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')), updated_at = now()
    where id = 1;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.apc_pin_ok(text) from public;
revoke all on function public.apc_write_key_ok(text) from public;
revoke all on function public.apc_login(text) from public;
revoke all on function public.apc_sync_report(text,jsonb,jsonb) from public;
revoke all on function public.apc_list_reports(text) from public;
revoke all on function public.apc_get_report(text,uuid) from public;
revoke all on function public.apc_review_report(text,uuid,text,text,text) from public;
revoke all on function public.apc_set_viewer_pin(text,text) from public;

grant execute on function public.apc_login(text) to anon, authenticated;
grant execute on function public.apc_sync_report(text,jsonb,jsonb) to anon, authenticated;
grant execute on function public.apc_list_reports(text) to anon, authenticated;
grant execute on function public.apc_get_report(text,uuid) to anon, authenticated;
grant execute on function public.apc_review_report(text,uuid,text,text,text) to anon, authenticated;
grant execute on function public.apc_set_viewer_pin(text,text) to anon, authenticated;

-- Verificación rápida opcional después de ejecutar:
-- select public.apc_login('2026');
-- Debe devolver {"ok": true, ...}


-- ================================================================
-- ACTUALIZACIÓN v1.6
-- ================================================================

-- APC Corporacion · Actualización v1.6
-- Ejecutar UNA VEZ en Supabase > SQL Editor > New query > Run.
-- Añade administración del historial desde la APK, estados de revisión y carga
-- únicamente los 3 reportes históricos entregados por el usuario.

alter table public.transport_entries
  add column if not exists support_note text not null default '';

-- Sincronización normal desde la APK (actualizada para support_note).
create or replace function public.apc_sync_report(
  p_write_key text,
  p_report jsonb,
  p_entries jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  v_report_id uuid;
  v_entry jsonb;
  v_entry_ids uuid[] := '{}'::uuid[];
begin
  select * into c from public.apc_config where id = 1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave de sincronización inválida';
  end if;

  v_report_id := (p_report->>'id')::uuid;

  insert into public.transport_reports (
    id, title, period_start, period_end, status,
    owner_name, owner_dni, company_name, company_ruc, engineer_name, updated_at
  ) values (
    v_report_id,
    coalesce(nullif(p_report->>'title',''), 'Reporte de transporte'),
    (p_report->>'period_start')::date,
    nullif(p_report->>'period_end','')::date,
    coalesce(nullif(p_report->>'status',''),'draft'),
    coalesce(nullif(p_report->>'owner_name',''), c.owner_name),
    coalesce(nullif(p_report->>'owner_dni',''), c.owner_dni),
    coalesce(nullif(p_report->>'company_name',''), c.company_name),
    coalesce(nullif(p_report->>'company_ruc',''), c.company_ruc),
    coalesce(nullif(p_report->>'engineer_name',''), c.default_engineer),
    now()
  )
  on conflict (id) do update set
    title = excluded.title,
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    status = excluded.status,
    owner_name = excluded.owner_name,
    owner_dni = excluded.owner_dni,
    company_name = excluded.company_name,
    company_ruc = excluded.company_ruc,
    engineer_name = excluded.engineer_name,
    updated_at = now();

  if jsonb_typeof(coalesce(p_entries,'[]'::jsonb)) = 'array' then
    for v_entry in select * from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb))
    loop
      v_entry_ids := array_append(v_entry_ids, (v_entry->>'id')::uuid);
      insert into public.transport_entries (
        id, report_id, entry_type, entry_date, direction, origin, destination, detail, amount,
        issue_time, support_type, support_note, declaration_reason, declaration_place_date, engineer_name,
        receipt_image_base64, receipt_mime, signature_base64, updated_at
      ) values (
        (v_entry->>'id')::uuid,
        v_report_id,
        lower(v_entry->>'entry_type'),
        (v_entry->>'entry_date')::date,
        nullif(v_entry->>'direction',''),
        nullif(v_entry->>'origin',''),
        nullif(v_entry->>'destination',''),
        coalesce(v_entry->>'detail',''),
        coalesce((v_entry->>'amount')::numeric,0),
        nullif(v_entry->>'issue_time',''),
        coalesce(nullif(v_entry->>'support_type',''),'none'),
        coalesce(v_entry->>'support_note',''),
        nullif(v_entry->>'declaration_reason',''),
        nullif(v_entry->>'declaration_place_date',''),
        nullif(v_entry->>'engineer_name',''),
        nullif(v_entry->>'receipt_image_base64',''),
        nullif(v_entry->>'receipt_mime',''),
        nullif(v_entry->>'signature_base64',''),
        now()
      )
      on conflict (id) do update set
        report_id = excluded.report_id,
        entry_type = excluded.entry_type,
        entry_date = excluded.entry_date,
        direction = excluded.direction,
        origin = excluded.origin,
        destination = excluded.destination,
        detail = excluded.detail,
        amount = excluded.amount,
        issue_time = excluded.issue_time,
        support_type = excluded.support_type,
        support_note = excluded.support_note,
        declaration_reason = excluded.declaration_reason,
        declaration_place_date = excluded.declaration_place_date,
        engineer_name = excluded.engineer_name,
        receipt_image_base64 = excluded.receipt_image_base64,
        receipt_mime = excluded.receipt_mime,
        signature_base64 = excluded.signature_base64,
        updated_at = now();
    end loop;
  end if;

  if cardinality(v_entry_ids) = 0 then
    delete from public.transport_entries where report_id = v_report_id;
  else
    delete from public.transport_entries
      where report_id = v_report_id
        and not (id = any(v_entry_ids));
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'synced_at', now());
end;
$$;

-- Funciones privadas de propietario usadas solamente por la APK con su write_key.
create or replace function public.apc_owner_list_reports(p_write_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype; result jsonb;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  select coalesce(jsonb_agg(x order by x.period_start desc, x.created_at desc),'[]'::jsonb) into result
  from (
    select r.id,r.title,r.period_start,r.period_end,r.status,r.boss_note,r.reviewed_by,r.reviewed_at,r.created_at,r.updated_at,
      coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) received,
      coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) spent,
      (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)-coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2) balance,
      count(e.id)::integer movement_count
    from public.transport_reports r left join public.transport_entries e on e.report_id=r.id group by r.id
  ) x;
  return result;
end;
$$;

create or replace function public.apc_owner_get_report(p_write_key text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;r public.transport_reports%rowtype;entries_json jsonb;received numeric(12,2);spent numeric(12,2);
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  select * into r from public.transport_reports where id=p_report_id;if r.id is null then raise exception 'Reporte no encontrado';end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date,e.created_at),'[]'::jsonb),
    coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0),
    coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)
  into entries_json,received,spent from public.transport_entries e where e.report_id=p_report_id;
  return jsonb_build_object('report',to_jsonb(r),'summary',jsonb_build_object('received',received,'spent',spent,'balance',received-spent),'entries',entries_json);
end;
$$;

create or replace function public.apc_owner_upsert_entry(p_write_key text,p_report_id uuid,p_entry jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;eid uuid;existing public.transport_entries%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  eid:=(p_entry->>'id')::uuid;select * into existing from public.transport_entries where id=eid;
  if existing.id is null then
    insert into public.transport_entries(id,report_id,entry_type,entry_date,direction,origin,destination,detail,amount,issue_time,support_type,support_note,updated_at)
    values(eid,p_report_id,lower(p_entry->>'entry_type'),(p_entry->>'entry_date')::date,nullif(p_entry->>'direction',''),nullif(p_entry->>'origin',''),nullif(p_entry->>'destination',''),coalesce(p_entry->>'detail',''),coalesce((p_entry->>'amount')::numeric,0),nullif(p_entry->>'issue_time',''),'none','',now());
  else
    update public.transport_entries set
      entry_type=coalesce(nullif(lower(p_entry->>'entry_type'),''),entry_type),
      entry_date=coalesce(nullif(p_entry->>'entry_date','')::date,entry_date),
      direction=case when p_entry ? 'direction' then nullif(p_entry->>'direction','') else direction end,
      origin=case when p_entry ? 'origin' then nullif(p_entry->>'origin','') else origin end,
      destination=case when p_entry ? 'destination' then nullif(p_entry->>'destination','') else destination end,
      detail=case when p_entry ? 'detail' then coalesce(p_entry->>'detail','') else detail end,
      amount=case when p_entry ? 'amount' then coalesce((p_entry->>'amount')::numeric,amount) else amount end,
      issue_time=case when p_entry ? 'issue_time' then nullif(p_entry->>'issue_time','') else issue_time end,
      updated_at=now()
    where id=eid;
  end if;
  update public.transport_reports set status='submitted',boss_note='',reviewed_by=null,reviewed_at=null,updated_at=now() where id=p_report_id;
  return jsonb_build_object('ok',true,'entry_id',eid);
end;
$$;

create or replace function public.apc_owner_delete_entry(p_write_key text,p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;rid uuid;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  select report_id into rid from public.transport_entries where id=p_entry_id;delete from public.transport_entries where id=p_entry_id;
  if rid is not null then update public.transport_reports set status='submitted',boss_note='',reviewed_by=null,reviewed_at=null,updated_at=now() where id=rid;end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.apc_owner_delete_report(p_write_key text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  delete from public.transport_reports where id=p_report_id;return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.apc_owner_update_report(p_write_key text,p_report_id uuid,p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  update public.transport_reports set
    title=coalesce(nullif(p_patch->>'title',''),title),
    period_start=coalesce(nullif(p_patch->>'period_start','')::date,period_start),
    period_end=case when p_patch ? 'period_end' then nullif(p_patch->>'period_end','')::date else period_end end,
    status='submitted',boss_note='',reviewed_by=null,reviewed_at=null,updated_at=now()
  where id=p_report_id;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.apc_owner_resubmit_report(p_write_key text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  update public.transport_reports set status='submitted',boss_note='',reviewed_by=null,reviewed_at=null,updated_at=now() where id=p_report_id;
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.apc_owner_list_reports(text) from public;
revoke all on function public.apc_owner_get_report(text,uuid) from public;
revoke all on function public.apc_owner_upsert_entry(text,uuid,jsonb) from public;
revoke all on function public.apc_owner_delete_entry(text,uuid) from public;
revoke all on function public.apc_owner_delete_report(text,uuid) from public;
revoke all on function public.apc_owner_update_report(text,uuid,jsonb) from public;
revoke all on function public.apc_owner_resubmit_report(text,uuid) from public;
grant execute on function public.apc_owner_list_reports(text) to anon,authenticated;
grant execute on function public.apc_owner_get_report(text,uuid) to anon,authenticated;
grant execute on function public.apc_owner_upsert_entry(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.apc_owner_delete_entry(text,uuid) to anon,authenticated;
grant execute on function public.apc_owner_delete_report(text,uuid) to anon,authenticated;
grant execute on function public.apc_owner_update_report(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.apc_owner_resubmit_report(text,uuid) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- HISTORIAL INICIAL: deja SOLO los 3 reportes que ya fueron enviados.
-- Si ya tienes otro reporte nuevo sincronizado y deseas conservarlo, no ejecutes
-- esta sección DELETE/INSERT; ejecútala antes de agregar el siguiente reporte.
-- ---------------------------------------------------------------------------
delete from public.transport_reports;

insert into public.transport_reports(id,title,period_start,period_end,status,owner_name,owner_dni,company_name,company_ruc,engineer_name,created_at,updated_at)
values
('11111111-1111-4111-8111-111111111111','Reporte enviado · 11–15 septiembre 2026','2026-09-11','2026-09-15','submitted','Raul Smith Luque Chumpitaz','72174739','APC CORPORACION S.A.','20102185863','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO','2026-09-15 20:00:00-05','2026-09-15 20:00:00-05'),
('22222222-2222-4222-8222-222222222222','Reporte enviado · 16–19 septiembre 2026','2026-09-16','2026-09-19','submitted','Raul Smith Luque Chumpitaz','72174739','APC CORPORACION S.A.','20102185863','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO','2026-09-20 20:00:00-05','2026-09-20 20:00:00-05'),
('33333333-3333-4333-8333-333333333333','Reporte enviado · 16–22 septiembre 2026','2026-09-16','2026-09-22','submitted','Raul Smith Luque Chumpitaz','72174739','APC CORPORACION S.A.','20102185863','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO','2026-09-22 07:00:00-05','2026-09-22 07:00:00-05');

-- 11–15 septiembre: recibido S/120, gastado S/67, saldo S/53.
insert into public.transport_entries(id,report_id,entry_type,entry_date,detail,amount,support_note) values
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','credit','2026-09-11','Entrega registrada',20,''),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-11','BARR CHIN/COOP - CRUCE PISCO',5,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','credit','2026-09-12','Entrega registrada',40,''),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-12','CRUCE PISCO - ICA',10,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-12','BARR CHIN/COOP - CRUCE PISCO',5,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-13','SAN CLEMENTE - ICA',10,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-13','BARR CHIN/COOP - CRUCE PISCO',5,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','credit','2026-09-14','Entrega registrada',30,''),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-14','CRUCE PISCO - ICA',12,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-14','BARR CHIN/COOP - CRUCE PISCO',5,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','credit','2026-09-15','Entrega registrada',30,''),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-15','CRUCE PISCO - ICA',10,'Ya mostradas'),
(gen_random_uuid(),'11111111-1111-4111-8111-111111111111','expense','2026-09-15','BARR CHIN/COOP - CRUCE PISCO',5,'Ya mostradas');

-- 16–19 septiembre: recibido S/70, gastado S/54, saldo S/16.
insert into public.transport_entries(id,report_id,entry_type,entry_date,detail,amount,issue_time,support_note) values
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','credit','2026-09-16','Entrega registrada',30,null,''),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-16','BARR CHIN/COOP - CRUCE PISCO',5,'6:37 PM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-17','CRUCE PISCO - ICA',10,'5:58 AM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-17','ICA - SAN CLEMENTE',8,'7:05 PM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','credit','2026-09-18','Entrega registrada',40,null,''),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-18','CRUCE PISCO - ICA',10,'5:32 AM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-18','BARR CHIN/COOP - CRUCE PISCO',5,'3:04 PM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-19','CRUCE PISCO - ICA',10,'5:36 AM','Ya mostradas'),
(gen_random_uuid(),'22222222-2222-4222-8222-222222222222','expense','2026-09-19','ICA - SAN CLEMENTE',6,'6:13 PM','Ya mostradas');

-- 16–22 septiembre: recibido S/70, gastado S/81, saldo S/-11.
insert into public.transport_entries(id,report_id,entry_type,entry_date,detail,amount,issue_time,support_note) values
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','credit','2026-09-16','Entrega registrada',30,null,''),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-16','BARRIO CHINO - CRUCE PISCO',5,'6:37 PM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-17','CRUCE PISCO - ICA',10,'5:58 AM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-17','CRUCE PISCO - SAN CLEMENTE',8,null,'Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','credit','2026-09-18','Entrega registrada',40,null,''),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-18','BARRIO CHINO - CRUCE PISCO',5,'3:04 PM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-18','CRUCE PISCO - ICA',10,'5:32 AM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-19','CRUCE PISCO - ICA',10,'5:36 AM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-19','BARRIO CHINO - SAN CLEMENTE',6,null,'Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-21','CRUCE PISCO - BARRIO CHINO',6,'5:54 PM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-21','CRUCE PISCO - BARRIO CHINO',5,'7:12 PM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-21','CRUCE PISCO - BARRIO CHINO',6,'5:54 AM','Ya mostradas'),
(gen_random_uuid(),'33333333-3333-4333-8333-333333333333','expense','2026-09-22','CRUCE PISCO - ICA',10,'6:09 AM','Ya mostradas');

-- Comprobación:
-- select public.apc_owner_list_reports('YP1BO9IZzGgZJtAEfxVhNFFhdEsERMa2_V8lKDDn16c');


-- ================================================================
-- ACTUALIZACIÓN v1.7 · VISTA UNIFICADA / LIQUIDACIONES / EVIDENCIAS
-- ================================================================

-- APC Corporacion · Actualización v1.7
-- Ejecutar UNA VEZ en Supabase > SQL Editor > New query > Run.
-- Esta migración NO borra el reporte actual. Unifica la presentación de periodos,
-- marca los periodos antiguos como liquidados, elimina el reporte 16–19 duplicado,
-- añade referencias a evidencias históricas y permite restablecer una revisión.

create extension if not exists pgcrypto with schema extensions;

alter table public.transport_reports
  add column if not exists is_closed boolean not null default false,
  add column if not exists closed_at timestamptz,
  add column if not exists closure_note text not null default '';

alter table public.transport_entries
  add column if not exists support_note text not null default '',
  add column if not exists support_asset text not null default '';

-- La sincronización desde la APK mantiene separadas dos ideas: terminar un período
-- y liquidar financieramente la cuenta. Un período enviado NO queda liquidado automáticamente.
create or replace function public.apc_sync_report(
  p_write_key text,
  p_report jsonb,
  p_entries jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  v_report_id uuid;
  v_entry jsonb;
  v_entry_ids uuid[] := '{}'::uuid[];
  v_is_closed boolean;
begin
  select * into c from public.apc_config where id = 1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave de sincronización inválida';
  end if;

  v_report_id := (p_report->>'id')::uuid;
  -- Cerrar un periodo y liquidar la cuenta son cosas distintas.
  -- La APK normal sincroniza reportes como no liquidados; el cierre financiero se hace
  -- desde "Administrar web" cuando realmente se devolvió/regularizó el saldo.
  v_is_closed := case
    when p_report ? 'is_closed' then coalesce((p_report->>'is_closed')::boolean,false)
    else false
  end;

  insert into public.transport_reports (
    id, title, period_start, period_end, status,
    owner_name, owner_dni, company_name, company_ruc, engineer_name,
    is_closed, closed_at, closure_note, updated_at
  ) values (
    v_report_id,
    coalesce(nullif(p_report->>'title',''), 'Reporte de transporte'),
    (p_report->>'period_start')::date,
    nullif(p_report->>'period_end','')::date,
    coalesce(nullif(p_report->>'status',''),'draft'),
    coalesce(nullif(p_report->>'owner_name',''), c.owner_name),
    coalesce(nullif(p_report->>'owner_dni',''), c.owner_dni),
    coalesce(nullif(p_report->>'company_name',''), c.company_name),
    coalesce(nullif(p_report->>'company_ruc',''), c.company_ruc),
    coalesce(nullif(p_report->>'engineer_name',''), c.default_engineer),
    v_is_closed,
    case when v_is_closed then now() else null end,
    case when v_is_closed then 'Cuenta liquidada al cierre del periodo.' else '' end,
    now()
  )
  on conflict (id) do update set
    title = excluded.title,
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    status = excluded.status,
    owner_name = excluded.owner_name,
    owner_dni = excluded.owner_dni,
    company_name = excluded.company_name,
    company_ruc = excluded.company_ruc,
    engineer_name = excluded.engineer_name,
    is_closed = case when public.transport_reports.is_closed then true else excluded.is_closed end,
    closed_at = case
      when public.transport_reports.is_closed then public.transport_reports.closed_at
      when excluded.is_closed then coalesce(public.transport_reports.closed_at,now())
      else null
    end,
    closure_note = case
      when public.transport_reports.is_closed and public.transport_reports.closure_note <> '' then public.transport_reports.closure_note
      else excluded.closure_note
    end,
    updated_at = now();

  if jsonb_typeof(coalesce(p_entries,'[]'::jsonb)) = 'array' then
    for v_entry in select * from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb))
    loop
      v_entry_ids := array_append(v_entry_ids, (v_entry->>'id')::uuid);
      insert into public.transport_entries (
        id, report_id, entry_type, entry_date, direction, origin, destination, detail, amount,
        issue_time, support_type, support_note, support_asset, declaration_reason, declaration_place_date, engineer_name,
        receipt_image_base64, receipt_mime, signature_base64, updated_at
      ) values (
        (v_entry->>'id')::uuid,
        v_report_id,
        lower(v_entry->>'entry_type'),
        (v_entry->>'entry_date')::date,
        nullif(v_entry->>'direction',''),
        nullif(v_entry->>'origin',''),
        nullif(v_entry->>'destination',''),
        coalesce(v_entry->>'detail',''),
        coalesce((v_entry->>'amount')::numeric,0),
        nullif(v_entry->>'issue_time',''),
        coalesce(nullif(v_entry->>'support_type',''),'none'),
        coalesce(v_entry->>'support_note',''),
        coalesce(v_entry->>'support_asset',''),
        nullif(v_entry->>'declaration_reason',''),
        nullif(v_entry->>'declaration_place_date',''),
        nullif(v_entry->>'engineer_name',''),
        nullif(v_entry->>'receipt_image_base64',''),
        nullif(v_entry->>'receipt_mime',''),
        nullif(v_entry->>'signature_base64',''),
        now()
      )
      on conflict (id) do update set
        report_id = excluded.report_id,
        entry_type = excluded.entry_type,
        entry_date = excluded.entry_date,
        direction = excluded.direction,
        origin = excluded.origin,
        destination = excluded.destination,
        detail = excluded.detail,
        amount = excluded.amount,
        issue_time = excluded.issue_time,
        support_type = excluded.support_type,
        support_note = excluded.support_note,
        support_asset = coalesce(nullif(excluded.support_asset,''), public.transport_entries.support_asset),
        declaration_reason = excluded.declaration_reason,
        declaration_place_date = excluded.declaration_place_date,
        engineer_name = excluded.engineer_name,
        receipt_image_base64 = excluded.receipt_image_base64,
        receipt_mime = excluded.receipt_mime,
        signature_base64 = excluded.signature_base64,
        updated_at = now();
    end loop;
  end if;

  if cardinality(v_entry_ids) = 0 then
    delete from public.transport_entries where report_id = v_report_id;
  else
    delete from public.transport_entries
      where report_id = v_report_id
        and not (id = any(v_entry_ids));
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'synced_at', now());
end;
$$;

create or replace function public.apc_list_reports(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype; result jsonb;
begin
  select * into c from public.apc_config where id = 1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then raise exception 'PIN incorrecto'; end if;

  select coalesce(jsonb_agg(x order by x.is_closed asc, x.period_start desc, x.created_at desc),'[]'::jsonb) into result
  from (
    select r.id,r.title,r.period_start,r.period_end,r.status,r.is_closed,r.closed_at,r.closure_note,
      r.boss_note,r.reviewed_by,r.reviewed_at,r.created_at,r.updated_at,
      coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) received,
      coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) spent,
      (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)-coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2) raw_balance,
      case when r.is_closed then 0::numeric(12,2)
           else (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)-coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2)
      end balance,
      count(e.id)::integer movement_count
    from public.transport_reports r left join public.transport_entries e on e.report_id=r.id group by r.id
  ) x;
  return result;
end;
$$;

create or replace function public.apc_get_report(p_pin text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;r public.transport_reports%rowtype;entries_json jsonb;received numeric(12,2);spent numeric(12,2);raw_balance numeric(12,2);
begin
  select * into c from public.apc_config where id=1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then raise exception 'PIN incorrecto'; end if;
  select * into r from public.transport_reports where id=p_report_id;if r.id is null then raise exception 'Reporte no encontrado';end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date,e.created_at),'[]'::jsonb),
    coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0),
    coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)
  into entries_json,received,spent from public.transport_entries e where e.report_id=p_report_id;
  raw_balance:=received-spent;
  return jsonb_build_object('report',to_jsonb(r),'summary',jsonb_build_object(
    'received',received,'spent',spent,'raw_balance',raw_balance,'balance',case when r.is_closed then 0 else raw_balance end,
    'closure_adjustment',case when r.is_closed then abs(raw_balance) else 0 end,
    'closure_kind',case when not r.is_closed then '' when raw_balance>0 then 'returned' when raw_balance<0 then 'regularized' else 'balanced' end
  ),'entries',entries_json);
end;
$$;

-- El ingeniero puede aprobar, pedir corrección o volver el reporte a "En revisión".
create or replace function public.apc_review_report(
  p_pin text,p_report_id uuid,p_action text,p_note text default '',p_reviewed_by text default 'Luis Guillermo Muñoz Quijandría'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;new_status text;
begin
  select * into c from public.apc_config where id=1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then raise exception 'PIN incorrecto'; end if;
  new_status:=case lower(p_action) when 'approve' then 'approved' when 'correction' then 'correction_requested' when 'reset' then 'submitted' else null end;
  if new_status is null then raise exception 'Acción inválida'; end if;
  update public.transport_reports set
    status=new_status,
    boss_note=case when new_status='submitted' then '' else coalesce(p_note,'') end,
    reviewed_by=case when new_status='submitted' then null else nullif(p_reviewed_by,'') end,
    reviewed_at=case when new_status='submitted' then null else now() end,
    updated_at=now()
  where id=p_report_id and is_closed=false;
  if not found then raise exception 'Solo una cuenta no liquidada puede revisarse'; end if;
  return jsonb_build_object('ok',true,'status',new_status,'reviewed_at',case when new_status='submitted' then null else now() end);
end;
$$;

-- Funciones del propietario/APK.
create or replace function public.apc_owner_list_reports(p_write_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype; result jsonb;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  select coalesce(jsonb_agg(x order by x.is_closed asc,x.period_start desc,x.created_at desc),'[]'::jsonb) into result
  from (
    select r.id,r.title,r.period_start,r.period_end,r.status,r.is_closed,r.closed_at,r.closure_note,r.boss_note,r.reviewed_by,r.reviewed_at,r.created_at,r.updated_at,
      coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) received,
      coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) spent,
      (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)-coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2) raw_balance,
      case when r.is_closed then 0::numeric(12,2)
           else (coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0)-coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0))::numeric(12,2) end balance,
      count(e.id)::integer movement_count
    from public.transport_reports r left join public.transport_entries e on e.report_id=r.id group by r.id
  ) x;
  return result;
end;
$$;

create or replace function public.apc_owner_get_report(p_write_key text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;r public.transport_reports%rowtype;entries_json jsonb;received numeric(12,2);spent numeric(12,2);raw_balance numeric(12,2);
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  select * into r from public.transport_reports where id=p_report_id;if r.id is null then raise exception 'Reporte no encontrado';end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date,e.created_at),'[]'::jsonb),coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0),coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)
    into entries_json,received,spent from public.transport_entries e where e.report_id=p_report_id;
  raw_balance:=received-spent;
  return jsonb_build_object('report',to_jsonb(r),'summary',jsonb_build_object('received',received,'spent',spent,'raw_balance',raw_balance,'balance',case when r.is_closed then 0 else raw_balance end),'entries',entries_json);
end;
$$;

create or replace function public.apc_owner_reset_review(p_write_key text,p_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  update public.transport_reports set status='submitted',boss_note='',reviewed_by=null,reviewed_at=null,updated_at=now() where id=p_report_id and is_closed=false;
  if not found then raise exception 'Solo una cuenta no liquidada puede volver a revisión'; end if;
  return jsonb_build_object('ok',true,'status','submitted');
end;
$$;

revoke all on function public.apc_owner_reset_review(text,uuid) from public;
grant execute on function public.apc_owner_reset_review(text,uuid) to anon,authenticated;


create or replace function public.apc_owner_set_closed(p_write_key text,p_report_id uuid,p_closed boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c public.apc_config%rowtype;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then raise exception 'Clave inválida'; end if;
  if p_closed and exists(select 1 from public.transport_reports where id=p_report_id and period_end is null) then
    raise exception 'El reporte actual todavía no tiene fecha de cierre';
  end if;
  update public.transport_reports set
    is_closed=p_closed,
    closed_at=case when p_closed then now() else null end,
    closure_note=case when p_closed then 'Cuenta liquidada al cierre del periodo.' else '' end,
    updated_at=now()
  where id=p_report_id;
  if not found then raise exception 'Reporte no encontrado'; end if;
  return jsonb_build_object('ok',true,'is_closed',p_closed);
end;
$$;

revoke all on function public.apc_owner_set_closed(text,uuid,boolean) from public;
grant execute on function public.apc_owner_set_closed(text,uuid,boolean) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- HISTORIAL CONSOLIDADO Y SIN DUPLICADOS
-- Se eliminan SOLO los periodos históricos conocidos. El reporte actual (desde
-- 22/09/2026, sin fecha final) se conserva exactamente como está en Supabase.
-- ---------------------------------------------------------------------------
delete from public.transport_reports
where (period_start='2026-09-11' and period_end='2026-09-15')
   or (period_start='2026-09-16' and period_end in ('2026-09-19','2026-09-22'));

-- 11–15 septiembre: S/120 recibido, S/67 gastado. S/53 devuelto al cierre.
insert into public.transport_reports(
  id,title,period_start,period_end,status,is_closed,closed_at,closure_note,
  owner_name,owner_dni,company_name,company_ruc,engineer_name,created_at,updated_at
) values (
  '11111111-1111-4111-8111-111111111111','Cuenta liquidada · 11–15 septiembre 2026','2026-09-11','2026-09-15','submitted',true,'2026-09-15 21:00:00-05',
  'Saldo sobrante devuelto al finalizar el período.',
  'Raul Smith Luque Chumpitaz','72174739','APC CORPORACION S.A.','20102185863','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO','2026-09-15 20:00:00-05','2026-09-15 21:00:00-05'
);

insert into public.transport_entries(id,report_id,entry_type,entry_date,direction,origin,destination,detail,amount,issue_time,support_type,support_note,support_asset) values
('11000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','credit','2026-09-11','','','','Entrega registrada',20,null,'none','',''),
('11000000-0000-4000-8000-000000000002','11111111-1111-4111-8111-111111111111','expense','2026-09-11','RETORNO','BARR CHIN/COOP','CRUCE PISCO','BARR CHIN/COOP - CRUCE PISCO',5,null,'receipt','','historical/2026-09-11_ret_s5.jpg'),
('11000000-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111','credit','2026-09-12','','','','Entrega registrada',40,null,'none','',''),
('11000000-0000-4000-8000-000000000004','11111111-1111-4111-8111-111111111111','expense','2026-09-12','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,null,'receipt','','historical/2026-09-12_ida_s10.jpg'),
('11000000-0000-4000-8000-000000000005','11111111-1111-4111-8111-111111111111','expense','2026-09-12','RETORNO','BARR CHIN/COOP','CRUCE PISCO','BARR CHIN/COOP - CRUCE PISCO',5,null,'receipt','','historical/2026-09-12_ret_s5.jpg'),
('11000000-0000-4000-8000-000000000006','11111111-1111-4111-8111-111111111111','expense','2026-09-13','IDA','SAN CLEMENTE','ICA','SAN CLEMENTE - ICA',10,null,'none','Boleta extraviada',''),
('11000000-0000-4000-8000-000000000007','11111111-1111-4111-8111-111111111111','expense','2026-09-13','RETORNO','BARR CHIN/COOP','CRUCE PISCO','BARR CHIN/COOP - CRUCE PISCO',5,null,'receipt','','historical/2026-09-13_ret_s5.jpg'),
('11000000-0000-4000-8000-000000000008','11111111-1111-4111-8111-111111111111','credit','2026-09-14','','','','Entrega registrada',30,null,'none','',''),
('11000000-0000-4000-8000-000000000009','11111111-1111-4111-8111-111111111111','expense','2026-09-14','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',12,null,'receipt','','historical/2026-09-14_ida_s12.jpg'),
('11000000-0000-4000-8000-000000000010','11111111-1111-4111-8111-111111111111','expense','2026-09-14','RETORNO','BARR CHIN/COOP','CRUCE PISCO','BARR CHIN/COOP - CRUCE PISCO',5,null,'receipt','','historical/2026-09-14_ret_s5.jpg'),
('11000000-0000-4000-8000-000000000011','11111111-1111-4111-8111-111111111111','credit','2026-09-15','','','','Entrega registrada',30,null,'none','',''),
('11000000-0000-4000-8000-000000000012','11111111-1111-4111-8111-111111111111','expense','2026-09-15','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,null,'receipt','','historical/2026-09-15_ida_s10.jpg'),
('11000000-0000-4000-8000-000000000013','11111111-1111-4111-8111-111111111111','expense','2026-09-15','RETORNO','BARR CHIN/COOP','CRUCE PISCO','BARR CHIN/COOP - CRUCE PISCO',5,null,'receipt','','historical/2026-09-15_ret_s5.jpg');

-- 16–22 septiembre: S/70 recibido, S/81 gastado. Diferencia de S/11 regularizada al cierre.
insert into public.transport_reports(
  id,title,period_start,period_end,status,is_closed,closed_at,closure_note,
  owner_name,owner_dni,company_name,company_ruc,engineer_name,created_at,updated_at
) values (
  '33333333-3333-4333-8333-333333333333','Cuenta liquidada · 16–22 septiembre 2026','2026-09-16','2026-09-22','submitted',true,'2026-09-22 07:30:00-05',
  'La diferencia pendiente quedó regularizada al finalizar el período.',
  'Raul Smith Luque Chumpitaz','72174739','APC CORPORACION S.A.','20102185863','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO','2026-09-22 07:00:00-05','2026-09-22 07:30:00-05'
);

insert into public.transport_entries(id,report_id,entry_type,entry_date,direction,origin,destination,detail,amount,issue_time,support_type,support_note,support_asset,declaration_reason,declaration_place_date,engineer_name) values
('16000000-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333','credit','2026-09-16','','','','Entrega registrada',30,null,'none','','','','','',''),
('16000000-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333','expense','2026-09-16','RETORNO','BARRIO CHINO','CRUCE PISCO','BARRIO CHINO - CRUCE PISCO',5,'6:37 PM','receipt','','historical/2026-09-16_ret_s5.jpg','','',''),
('16000000-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333','expense','2026-09-17','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,'5:58 AM','receipt','','historical/2026-09-17_ida_s10.jpg','','',''),
('16000000-0000-4000-8000-000000000004','33333333-3333-4333-8333-333333333333','expense','2026-09-17','RETORNO','CRUCE PISCO','SAN CLEMENTE','CRUCE PISCO - SAN CLEMENTE',8,null,'declaration','','historical/2026-09-17_declaracion_s8.jpg','Falta de disponibilidad de transporte público regular debido al horario tardío.','San Clemente, 20 de setiembre de 2026','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO'),
('16000000-0000-4000-8000-000000000005','33333333-3333-4333-8333-333333333333','credit','2026-09-18','','','','Entrega registrada',40,null,'none','','','','','',''),
('16000000-0000-4000-8000-000000000006','33333333-3333-4333-8333-333333333333','expense','2026-09-18','RETORNO','BARRIO CHINO','CRUCE PISCO','BARRIO CHINO - CRUCE PISCO',5,'3:04 PM','receipt','','historical/2026-09-18_ret_s5.jpg','','',''),
('16000000-0000-4000-8000-000000000007','33333333-3333-4333-8333-333333333333','expense','2026-09-18','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,'5:32 AM','receipt','','historical/2026-09-18_ida_s10.jpg','','',''),
('16000000-0000-4000-8000-000000000008','33333333-3333-4333-8333-333333333333','expense','2026-09-19','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,'5:36 AM','receipt','','historical/2026-09-19_ida_s10.jpg','','',''),
('16000000-0000-4000-8000-000000000009','33333333-3333-4333-8333-333333333333','expense','2026-09-19','RETORNO','BARRIO CHINO','SAN CLEMENTE','BARRIO CHINO - SAN CLEMENTE',6,null,'declaration','','historical/2026-09-19_declaracion_s6.jpg','Falta de disponibilidad de transporte público regular debido al horario tardío.','San Clemente, 20 de setiembre de 2026','MUÑOZ QUIJANDRÍA, LUIS GUILLERMO'),
('16000000-0000-4000-8000-000000000010','33333333-3333-4333-8333-333333333333','expense','2026-09-21','','CRUCE PISCO','BARRIO CHINO','CRUCE PISCO - BARRIO CHINO',6,'5:54 PM','none','Ya mostrada','','','',''),
('16000000-0000-4000-8000-000000000011','33333333-3333-4333-8333-333333333333','expense','2026-09-21','','CRUCE PISCO','BARRIO CHINO','CRUCE PISCO - BARRIO CHINO',5,'7:12 PM','receipt','','historical/2026-09-21_ret_s5_1912.jpg','','',''),
('16000000-0000-4000-8000-000000000012','33333333-3333-4333-8333-333333333333','expense','2026-09-21','','CRUCE PISCO','BARRIO CHINO','CRUCE PISCO - BARRIO CHINO',6,'5:54 AM','receipt','','historical/2026-09-21_s6_0554.jpg','','',''),
('16000000-0000-4000-8000-000000000013','33333333-3333-4333-8333-333333333333','expense','2026-09-22','IDA','CRUCE PISCO','ICA','CRUCE PISCO - ICA',10,'6:09 AM','receipt','','historical/2026-09-22_ida_s10.jpg','','','');

-- Asegurar que cualquier reporte actual sin fecha final siga abierto.
update public.transport_reports
set is_closed=false, closed_at=null, closure_note=''
where period_end is null;

-- Comprobación rápida opcional:
-- select public.apc_list_reports('2026');
