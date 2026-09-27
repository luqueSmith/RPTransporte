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
