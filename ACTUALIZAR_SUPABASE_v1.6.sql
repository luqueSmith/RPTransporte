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
