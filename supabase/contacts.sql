-- История контактов. Применять после crm.sql. Клиент не задаёт автора и время.
create unique index if not exists crm_contact_token on public.crm_activity(request_id,actor_id,(data->>'token')) where kind='contact';
create or replace function public.crm_client_detail(p_actor bigint,p_id uuid)
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare detail jsonb;
begin
 detail:=public.crm_request_detail(p_actor,p_id);
 return detail || jsonb_build_object('last_contact',(select jsonb_build_object('at',created_at,'actor_id',actor_id,'note',data->>'note') from public.crm_activity where request_id=p_id and kind='contact' and data->>'result'='connected' order by created_at desc,id desc limit 1));
end $$;
create or replace function public.crm_log_contact(p_actor bigint,p_id uuid,p_version integer,p_token uuid,p_result text,p_note text,p_data jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.crm_requests%rowtype; actor public.app_users%rowtype; saved jsonb; event public.crm_activity%rowtype;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 select * into r from public.crm_requests where id=p_id and company_id=actor.company_id for update;
 if not found or (actor.role='manager' and r.assigned_to is distinct from p_actor) then raise exception 'crm_not_found'; end if;
 if r.archived_at is not null then raise exception 'backend_archived'; end if;
 if p_token is null or p_result is null or p_result not in ('connected','no_answer','busy','wrong_number') or p_note is null or length(p_note)>2000 or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'crm_bad_data'; end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('status','reasons','main_reason','note','next_contact_at')) then raise exception 'crm_bad_data'; end if;
 select * into event from public.crm_activity where request_id=p_id and actor_id=p_actor and kind='contact' and data->>'token'=p_token::text;
 if found then
  if event.data->>'result' is distinct from p_result or event.data->>'note' is distinct from trim(p_note) or event.data->'submitted_data' is distinct from p_data then raise exception 'crm_conflict'; end if;
  return jsonb_build_object('request',to_jsonb(r),'contact',to_jsonb(event));
 end if;
 saved:=public.crm_save_request(p_actor,p_id,p_version,p_data);
 insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(actor.company_id,p_id,p_actor,'contact',jsonb_build_object('token',p_token,'result',p_result,'note',trim(p_note),'status',saved->>'status','submitted_data',p_data)) returning * into event;
 return jsonb_build_object('request',saved,'contact',to_jsonb(event));
end $$;
revoke all on function public.crm_client_detail(bigint,uuid),public.crm_log_contact(bigint,uuid,integer,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.crm_client_detail(bigint,uuid),public.crm_log_contact(bigint,uuid,integer,uuid,text,text,jsonb) to service_role;
