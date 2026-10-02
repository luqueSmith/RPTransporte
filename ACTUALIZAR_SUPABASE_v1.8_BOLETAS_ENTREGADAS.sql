-- APC Corporacion · Actualización v1.8 · Estado de entrega de boletas
-- Ejecutar UNA VEZ en Supabase > SQL Editor > New query > Run.
-- No borra reportes ni movimientos.
-- Añade un estado para indicar si una BOLETA física ya fue entregada al administrador.
-- Las declaraciones juradas no usan este estado.

create extension if not exists pgcrypto with schema extensions;

alter table public.transport_entries
  add column if not exists receipt_delivered boolean not null default false,
  add column if not exists receipt_delivered_at timestamptz;

-- Los registros históricos rotulados como "Ya mostrada" ya fueron presentados.
update public.transport_entries
set receipt_delivered = true,
    receipt_delivered_at = coalesce(receipt_delivered_at, updated_at, created_at, now())
where entry_type = 'expense'
  and lower(coalesce(support_note,'')) like '%ya mostr%';

-- Sincronización desde la APK. Es compatible con APK antiguas: si una versión vieja
-- no envía receipt_delivered, NO modifica el estado que ya exista en Supabase.
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

revoke all on function public.apc_sync_report(text,jsonb,jsonb) from public;
grant execute on function public.apc_sync_report(text,jsonb,jsonb) to anon,authenticated;

-- Permite corregir el estado directamente desde "Administrar web" de la APK.
create or replace function public.apc_owner_set_receipt_delivered(
  p_write_key text,
  p_entry_id uuid,
  p_delivered boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c public.apc_config%rowtype;
  v_support text;
  v_note text;
begin
  select * into c from public.apc_config where id=1;
  if c.write_key_hash <> extensions.crypt(coalesce(p_write_key,''), c.write_key_hash) then
    raise exception 'Clave inválida';
  end if;

  select support_type, support_note into v_support, v_note
  from public.transport_entries
  where id=p_entry_id and entry_type='expense';

  if not found then raise exception 'Boleta no encontrada'; end if;
  if position('receipt' in coalesce(v_support,'')) = 0
     and lower(coalesce(v_note,'')) not like '%ya mostr%' then
    raise exception 'Este movimiento no corresponde a una boleta';
  end if;

  update public.transport_entries
  set receipt_delivered = coalesce(p_delivered,false),
      receipt_delivered_at = case when coalesce(p_delivered,false) then now() else null end,
      updated_at = now()
  where id=p_entry_id;

  update public.transport_reports r
  set updated_at=now()
  where r.id=(select report_id from public.transport_entries where id=p_entry_id);

  return jsonb_build_object(
    'ok',true,
    'entry_id',p_entry_id,
    'receipt_delivered',coalesce(p_delivered,false),
    'receipt_delivered_at',case when coalesce(p_delivered,false) then now() else null end
  );
end;
$$;

revoke all on function public.apc_owner_set_receipt_delivered(text,uuid,boolean) from public;
grant execute on function public.apc_owner_set_receipt_delivered(text,uuid,boolean) to anon,authenticated;

-- Comprobación opcional después de ejecutar:
-- select id, entry_date, amount, support_type, receipt_delivered, receipt_delivered_at
-- from public.transport_entries
-- where entry_type='expense'
-- order by entry_date desc, created_at desc;
