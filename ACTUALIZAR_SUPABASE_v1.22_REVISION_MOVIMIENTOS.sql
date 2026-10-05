-- APC Transporte v1.22 · Revisión de movimientos
-- Ejecutar UNA VEZ en Supabase > SQL Editor > New query > Run.
-- NO borra reportes ni movimientos.
-- Permite al administrador marcar un gasto/crédito como "No considerado"
-- y restaurarlo después. Los totales se recalculan ignorando esos movimientos.
-- Compatible con la APK v2.5: no es necesario actualizar la app.

create extension if not exists pgcrypto with schema extensions;

alter table public.transport_entries
  add column if not exists is_excluded boolean not null default false,
  add column if not exists excluded_at timestamptz,
  add column if not exists excluded_by text;

create index if not exists idx_transport_entries_excluded
  on public.transport_entries(report_id, is_excluded, entry_date desc);

-- ---------------------------------------------------------------------------
-- El ingeniero puede sacar/reponer un movimiento del cálculo.
-- Los periodos ya liquidados quedan protegidos.
-- ---------------------------------------------------------------------------
create or replace function public.apc_set_entry_excluded(
  p_pin text,
  p_entry_id uuid,
  p_excluded boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  v_report_id uuid;
  v_is_closed boolean;
  v_excluded boolean := coalesce(p_excluded,false);
begin
  select * into c from public.apc_config where id=1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select e.report_id, r.is_closed
    into v_report_id, v_is_closed
  from public.transport_entries e
  join public.transport_reports r on r.id=e.report_id
  where e.id=p_entry_id;

  if v_report_id is null then
    raise exception 'Movimiento no encontrado';
  end if;

  if coalesce(v_is_closed,false) then
    raise exception 'Una cuenta liquidada no puede modificarse';
  end if;

  update public.transport_entries
  set is_excluded=v_excluded,
      excluded_at=case when v_excluded then now() else null end,
      excluded_by=case when v_excluded then coalesce(nullif(c.default_engineer,''),'Administrador') else null end,
      updated_at=now()
  where id=p_entry_id;

  update public.transport_reports
  set updated_at=now()
  where id=v_report_id;

  return jsonb_build_object(
    'ok',true,
    'entry_id',p_entry_id,
    'report_id',v_report_id,
    'is_excluded',v_excluded,
    'excluded_at',case when v_excluded then now() else null end,
    'excluded_by',case when v_excluded then coalesce(nullif(c.default_engineer,''),'Administrador') else null end
  );
end;
$$;

revoke all on function public.apc_set_entry_excluded(text,uuid,boolean) from public;
grant execute on function public.apc_set_entry_excluded(text,uuid,boolean) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- Listado para la WEB: totales = SOLO movimientos considerados.
-- excluded_count permite saber cuántos quedaron fuera del cálculo.
-- ---------------------------------------------------------------------------
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
  select * into c from public.apc_config where id=1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select coalesce(jsonb_agg(x order by x.is_closed asc,x.period_start desc,x.created_at desc),'[]'::jsonb)
  into result
  from (
    select
      r.id,r.title,r.period_start,r.period_end,r.status,r.is_closed,r.closed_at,r.closure_note,
      r.boss_note,r.reviewed_by,r.reviewed_at,r.created_at,r.updated_at,
      coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) received,
      coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) spent,
      (
        coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)
        - coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)
      )::numeric(12,2) raw_balance,
      case when r.is_closed then 0::numeric(12,2) else (
        coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)
        - coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)
      )::numeric(12,2) end balance,
      count(e.id) filter (where coalesce(e.is_excluded,false)=false)::integer movement_count,
      count(e.id) filter (where coalesce(e.is_excluded,false)=true)::integer excluded_count
    from public.transport_reports r
    left join public.transport_entries e on e.report_id=r.id
    group by r.id
  ) x;

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reporte para la WEB: devuelve TODOS los movimientos para que el ingeniero
-- pueda ver y restaurar los no considerados, pero los totales los ignoran.
-- ---------------------------------------------------------------------------
create or replace function public.apc_get_report(p_pin text,p_report_id uuid)
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
  raw_balance numeric(12,2);
  excluded_count integer;
begin
  select * into c from public.apc_config where id=1;
  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select * into r from public.transport_reports where id=p_report_id;
  if r.id is null then raise exception 'Reporte no encontrado'; end if;

  select
    coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date,e.created_at),'[]'::jsonb),
    coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0),
    coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0),
    count(e.id) filter (where coalesce(e.is_excluded,false)=true)::integer
  into entries_json,received,spent,excluded_count
  from public.transport_entries e
  where e.report_id=p_report_id;

  raw_balance:=received-spent;

  return jsonb_build_object(
    'report',to_jsonb(r),
    'summary',jsonb_build_object(
      'received',received,
      'spent',spent,
      'raw_balance',raw_balance,
      'balance',case when r.is_closed then 0 else raw_balance end,
      'closure_adjustment',case when r.is_closed then abs(raw_balance) else 0 end,
      'closure_kind',case when not r.is_closed then '' when raw_balance>0 then 'returned' when raw_balance<0 then 'regularized' else 'balanced' end,
      'excluded_count',coalesce(excluded_count,0)
    ),
    'entries',entries_json
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Listado de la APK: los totales también ignoran movimientos no considerados.
-- Así "Administrar web" de la APK v2.5 mostrará exactamente el mismo saldo.
-- ---------------------------------------------------------------------------
create or replace function public.apc_owner_list_reports(p_write_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  result jsonb;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave inválida';
  end if;

  select coalesce(jsonb_agg(x order by x.is_closed asc,x.period_start desc,x.created_at desc),'[]'::jsonb)
  into result
  from (
    select
      r.id,r.title,r.period_start,r.period_end,r.status,r.is_closed,r.closed_at,r.closure_note,
      r.boss_note,r.reviewed_by,r.reviewed_at,r.created_at,r.updated_at,
      coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)::numeric(12,2) received,
      coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)::numeric(12,2) spent,
      (
        coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)
        - coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)
      )::numeric(12,2) raw_balance,
      case when r.is_closed then 0::numeric(12,2) else (
        coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount else 0 end),0)
        - coalesce(sum(case when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount else 0 end),0)
      )::numeric(12,2) end balance,
      count(e.id) filter (where coalesce(e.is_excluded,false)=false)::integer movement_count,
      count(e.id) filter (where coalesce(e.is_excluded,false)=true)::integer excluded_count
    from public.transport_reports r
    left join public.transport_entries e on e.report_id=r.id
    group by r.id
  ) x;

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reporte para la APK v2.5: NO devuelve movimientos excluidos porque la app
-- antigua no conoce is_excluded. Así su actualización automática del reporte
-- local adopta el cálculo revisado sin requerir una nueva versión de la APK.
-- ---------------------------------------------------------------------------
create or replace function public.apc_owner_get_report(p_write_key text,p_report_id uuid)
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
  raw_balance numeric(12,2);
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave inválida';
  end if;

  select * into r from public.transport_reports where id=p_report_id;
  if r.id is null then raise exception 'Reporte no encontrado'; end if;

  select
    coalesce(jsonb_agg(to_jsonb(e) order by e.entry_date,e.created_at),'[]'::jsonb),
    coalesce(sum(case when e.entry_type='credit' then e.amount else 0 end),0),
    coalesce(sum(case when e.entry_type='expense' then e.amount else 0 end),0)
  into entries_json,received,spent
  from public.transport_entries e
  where e.report_id=p_report_id
    and coalesce(e.is_excluded,false)=false;

  raw_balance:=received-spent;

  return jsonb_build_object(
    'report',to_jsonb(r),
    'summary',jsonb_build_object(
      'received',received,
      'spent',spent,
      'raw_balance',raw_balance,
      'balance',case when r.is_closed then 0 else raw_balance end
    ),
    'entries',entries_json
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Compatibilidad con la APK v2.5.
-- IMPORTANTE: la APK puede volver a sincronizar el reporte completo. Esta versión
-- de apc_sync_report conserva is_excluded y NO borra los movimientos excluidos
-- aunque la app ya no los tenga en su copia local.
-- ---------------------------------------------------------------------------
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
        receipt_image_base64, receipt_mime, signature_base64,
        receipt_delivered, receipt_delivered_at, updated_at
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
        case
          when (position('receipt' in coalesce(v_entry->>'support_type','')) > 0 or lower(coalesce(v_entry->>'support_note','')) like '%ya mostr%')
               and v_entry ? 'receipt_delivered'
            then coalesce((v_entry->>'receipt_delivered')::boolean,false)
          else false
        end,
        case
          when (position('receipt' in coalesce(v_entry->>'support_type','')) > 0 or lower(coalesce(v_entry->>'support_note','')) like '%ya mostr%')
               and v_entry ? 'receipt_delivered' and coalesce((v_entry->>'receipt_delivered')::boolean,false)
            then coalesce(nullif(v_entry->>'receipt_delivered_at','')::timestamptz,now())
          else null
        end,
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
        receipt_delivered = case
          when v_entry ? 'receipt_delivered' then excluded.receipt_delivered
          else public.transport_entries.receipt_delivered
        end,
        receipt_delivered_at = case
          when not (v_entry ? 'receipt_delivered') then public.transport_entries.receipt_delivered_at
          when excluded.receipt_delivered then coalesce(excluded.receipt_delivered_at, public.transport_entries.receipt_delivered_at, now())
          else null
        end,
        -- is_excluded / excluded_at / excluded_by NO se tocan aquí.
        -- Esa decisión pertenece al administrador de la web.
        updated_at = now();
    end loop;
  end if;

  if cardinality(v_entry_ids) = 0 then
    delete from public.transport_entries
    where report_id = v_report_id
      and coalesce(is_excluded,false)=false;
  else
    delete from public.transport_entries
    where report_id = v_report_id
      and coalesce(is_excluded,false)=false
      and not (id = any(v_entry_ids));
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'synced_at', now());
end;
$$;

revoke all on function public.apc_sync_report(text,jsonb,jsonb) from public;
grant execute on function public.apc_sync_report(text,jsonb,jsonb) to anon,authenticated;

-- Asegura permisos de las funciones reemplazadas.
revoke all on function public.apc_list_reports(text) from public;
revoke all on function public.apc_get_report(text,uuid) from public;
revoke all on function public.apc_owner_list_reports(text) from public;
revoke all on function public.apc_owner_get_report(text,uuid) from public;
grant execute on function public.apc_list_reports(text) to anon,authenticated;
grant execute on function public.apc_get_report(text,uuid) to anon,authenticated;
grant execute on function public.apc_owner_list_reports(text) to anon,authenticated;
grant execute on function public.apc_owner_get_report(text,uuid) to anon,authenticated;

-- Comprobación opcional:
-- select id, entry_date, entry_type, amount, is_excluded, excluded_at, excluded_by
-- from public.transport_entries
-- order by entry_date desc, created_at desc;
