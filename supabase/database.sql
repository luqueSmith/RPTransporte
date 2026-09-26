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
