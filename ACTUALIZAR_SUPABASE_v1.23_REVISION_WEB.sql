-- ============================================================================
-- APC Transporte v1.23 · Revisión de movimientos SOLO PARA LA WEB
-- ============================================================================
-- Ejecutar UNA sola vez en Supabase > SQL Editor > New query > Run.
--
-- Qué hace:
--   1) Añade 3 campos de revisión a transport_entries.
--   2) Crea una función exclusiva de la WEB para "Quitar del cálculo" / restaurar.
--   3) Hace que los totales que ve la WEB ignoren los movimientos quitados.
--   4) Recarga el schema cache de Supabase/PostgREST para evitar el error
--      "Could not find the function ... in the schema cache".
--
-- Qué NO hace:
--   - No borra movimientos.
--   - No cambia la APK.
--   - No modifica apc_owner_list_reports, apc_owner_get_report ni apc_sync_report.
--   - No cambia los cálculos locales de la aplicación.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

alter table public.transport_entries
  add column if not exists is_excluded boolean not null default false,
  add column if not exists excluded_at timestamptz,
  add column if not exists excluded_by text;

create index if not exists idx_transport_entries_web_review
  on public.transport_entries(report_id, is_excluded, entry_date desc);

-- Limpiar la función antigua si existiera. La v1.23 usa un nombre nuevo para
-- evitar cualquier referencia vieja en la caché de PostgREST.
drop function if exists public.apc_set_entry_excluded(text, uuid, boolean);
drop function if exists public.apc_web_set_entry_excluded(text, uuid, boolean);

create function public.apc_web_set_entry_excluded(
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
  v_is_excluded boolean;
  v_excluded_at timestamptz;
  v_excluded_by text;
begin
  select * into c
  from public.apc_config
  where id = 1;

  if c.id is null then
    raise exception 'Configuración APC no encontrada';
  end if;

  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select e.report_id, coalesce(r.is_closed,false)
    into v_report_id, v_is_closed
  from public.transport_entries e
  join public.transport_reports r on r.id = e.report_id
  where e.id = p_entry_id;

  if v_report_id is null then
    raise exception 'Movimiento no encontrado';
  end if;

  if v_is_closed then
    raise exception 'Una cuenta liquidada no puede modificarse';
  end if;

  update public.transport_entries
     set is_excluded = coalesce(p_excluded,false),
         excluded_at = case when coalesce(p_excluded,false) then now() else null end,
         excluded_by = case
           when coalesce(p_excluded,false)
             then coalesce(nullif(c.default_engineer,''),'Administrador')
           else null
         end
   where id = p_entry_id
   returning is_excluded, excluded_at, excluded_by
        into v_is_excluded, v_excluded_at, v_excluded_by;

  return jsonb_build_object(
    'ok', true,
    'entry_id', p_entry_id,
    'report_id', v_report_id,
    'is_excluded', v_is_excluded,
    'excluded_at', v_excluded_at,
    'excluded_by', v_excluded_by
  );
end;
$$;

revoke all on function public.apc_web_set_entry_excluded(text,uuid,boolean) from public;
grant execute on function public.apc_web_set_entry_excluded(text,uuid,boolean) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- LISTA PARA LA WEB
-- Solo la web usa apc_list_reports con el PIN del administrador.
-- Los movimientos is_excluded=true siguen existiendo, pero no entran al total.
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
  select * into c from public.apc_config where id = 1;

  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select coalesce(
    jsonb_agg(x order by x.is_closed asc, x.period_start desc, x.created_at desc),
    '[]'::jsonb
  )
  into result
  from (
    select
      r.id,
      r.title,
      r.period_start,
      r.period_end,
      r.status,
      r.is_closed,
      r.closed_at,
      r.closure_note,
      r.boss_note,
      r.reviewed_by,
      r.reviewed_at,
      r.created_at,
      r.updated_at,
      coalesce(sum(case
        when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount
        else 0 end),0)::numeric(12,2) as received,
      coalesce(sum(case
        when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount
        else 0 end),0)::numeric(12,2) as spent,
      (
        coalesce(sum(case
          when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount
          else 0 end),0)
        -
        coalesce(sum(case
          when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount
          else 0 end),0)
      )::numeric(12,2) as raw_balance,
      case
        when r.is_closed then 0::numeric(12,2)
        else (
          coalesce(sum(case
            when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount
            else 0 end),0)
          -
          coalesce(sum(case
            when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount
            else 0 end),0)
        )::numeric(12,2)
      end as balance,
      count(e.id) filter (where coalesce(e.is_excluded,false)=false)::integer as movement_count,
      count(e.id) filter (where coalesce(e.is_excluded,false)=true)::integer as excluded_count
    from public.transport_reports r
    left join public.transport_entries e on e.report_id = r.id
    group by r.id
  ) x;

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- DETALLE PARA LA WEB
-- Devuelve TODOS los movimientos para que un movimiento quitado pueda verse y
-- restaurarse. Los totales superiores solo cuentan los movimientos incluidos.
-- ---------------------------------------------------------------------------
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
  raw_balance numeric(12,2);
  excluded_count integer;
begin
  select * into c from public.apc_config where id = 1;

  if c.viewer_pin_hash <> extensions.crypt(coalesce(p_pin,''), c.viewer_pin_hash) then
    raise exception 'PIN incorrecto';
  end if;

  select * into r
  from public.transport_reports
  where id = p_report_id;

  if r.id is null then
    raise exception 'Reporte no encontrado';
  end if;

  select
    coalesce(
      jsonb_agg(to_jsonb(e) order by e.entry_date desc, e.created_at desc),
      '[]'::jsonb
    ),
    coalesce(sum(case
      when coalesce(e.is_excluded,false)=false and e.entry_type='credit' then e.amount
      else 0 end),0),
    coalesce(sum(case
      when coalesce(e.is_excluded,false)=false and e.entry_type='expense' then e.amount
      else 0 end),0),
    count(e.id) filter (where coalesce(e.is_excluded,false)=true)::integer
  into entries_json, received, spent, excluded_count
  from public.transport_entries e
  where e.report_id = p_report_id;

  raw_balance := received - spent;

  return jsonb_build_object(
    'report', to_jsonb(r),
    'summary', jsonb_build_object(
      'received', received,
      'spent', spent,
      'raw_balance', raw_balance,
      'balance', case when r.is_closed then 0 else raw_balance end,
      'closure_adjustment', case when r.is_closed then abs(raw_balance) else 0 end,
      'closure_kind', case
        when not r.is_closed then ''
        when raw_balance > 0 then 'returned'
        when raw_balance < 0 then 'regularized'
        else 'balanced'
      end,
      'excluded_count', coalesce(excluded_count,0)
    ),
    'entries', entries_json
  );
end;
$$;

-- Asegurar permisos de lectura por RPC para la web.
revoke all on function public.apc_list_reports(text) from public;
revoke all on function public.apc_get_report(text,uuid) from public;
grant execute on function public.apc_list_reports(text) to anon, authenticated;
grant execute on function public.apc_get_report(text,uuid) to anon, authenticated;

-- IMPORTANTE: fuerza a Supabase/PostgREST a detectar inmediatamente la nueva
-- función y elimina el error "Could not find the function ... in schema cache".
notify pgrst, 'reload schema';

-- Verificación final. Si todo salió bien verás 1 fila con el nombre de la función.
select
  p.proname as funcion,
  pg_get_function_identity_arguments(p.oid) as parametros
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'apc_web_set_entry_excluded';
