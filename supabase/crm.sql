-- Shared CRM for a company. All access goes through the authenticated Edge Function.
create table if not exists public.app_companies (
 id uuid primary key default gen_random_uuid(),
 slug text not null unique,
 name text not null,
 created_at timestamptz not null default now()
);
insert into public.app_companies(slug,name) values ('podbor-demo','Основная компания') on conflict(slug) do nothing;
alter table public.app_users add column if not exists company_id uuid references public.app_companies(id);
update public.app_users set company_id=(select id from public.app_companies where slug='podbor-demo') where company_id is null;
alter table public.app_users alter column company_id set not null;

create table if not exists public.crm_requests (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.app_companies(id),
 created_by bigint references public.app_users(tg_id) on delete set null on update cascade,
 assigned_to bigint references public.app_users(tg_id) on delete set null on update cascade,
 source_user_id bigint references public.app_users(tg_id) on delete set null on update cascade,
 source_key text,
 client_name text not null check(length(client_name) between 1 and 160),
 phone text not null check(phone ~ '^[0-9]{10,15}$'),
 model text not null check(length(model) between 1 and 200),
 budget numeric not null check(budget > 0 and budget <= 100000000000),
 generation text not null default '', years text not null default '',
 mileage integer check(mileage >= 0), spec text not null default '',
 city text not null default '', payment text not null default '', legal text not null default '', purchase_time text not null default '',
 source_text text not null default '', consent_at timestamptz not null,
 status text not null default 'search' check(status in ('search','think','lost','won')),
 reasons jsonb not null default '[]' check(jsonb_typeof(reasons)='array'),
 main_reason text not null default '', note text not null default '',
 next_contact_at timestamptz, archived_at timestamptz,
 version integer not null default 1 check(version>0),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(company_id,source_user_id,source_key)
);
create index if not exists crm_company_updated on public.crm_requests(company_id,updated_at desc);
create index if not exists crm_assigned on public.crm_requests(assigned_to,company_id);
create unique index if not exists crm_active_phone on public.crm_requests(company_id,phone) where status in ('search','think') and archived_at is null;
create table if not exists public.crm_activity (
 id bigint generated always as identity primary key,
 company_id uuid not null references public.app_companies(id),
 request_id uuid not null references public.crm_requests(id) on delete cascade,
 actor_id bigint references public.app_users(tg_id) on delete set null on update cascade,
 kind text not null, data jsonb not null default '{}', created_at timestamptz not null default now()
);
create index if not exists crm_activity_request on public.crm_activity(request_id,created_at desc);
create table if not exists public.desktop_login_codes (
 code_hash text primary key, user_id bigint not null references public.app_users(tg_id) on delete cascade on update cascade,
 expires_at timestamptz not null, created_at timestamptz not null default now()
);
create index if not exists desktop_codes_user on public.desktop_login_codes(user_id);
create table if not exists public.desktop_sessions (
 token_hash text primary key, user_id bigint not null references public.app_users(tg_id) on delete cascade on update cascade,
 expires_at timestamptz not null, created_at timestamptz not null default now()
);
create index if not exists desktop_sessions_user on public.desktop_sessions(user_id);

alter table public.app_companies enable row level security;
alter table public.crm_requests enable row level security;
alter table public.crm_activity enable row level security;
alter table public.desktop_login_codes enable row level security;
alter table public.desktop_sessions enable row level security;
revoke all on public.app_companies,public.crm_requests,public.crm_activity,public.desktop_login_codes,public.desktop_sessions from public,anon,authenticated;
grant select,insert,update on public.app_companies,public.crm_requests to service_role;
grant select,insert on public.crm_activity to service_role;
grant select,insert,delete on public.desktop_login_codes,public.desktop_sessions to service_role;
grant usage,select on sequence public.crm_activity_id_seq to service_role;

create or replace function public.crm_save_request(p_actor bigint,p_id uuid,p_version integer,p_data jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare
 actor public.app_users%rowtype; current_row public.crm_requests%rowtype; saved public.crm_requests%rowtype;
 assignee bigint; new_status text; r jsonb; main text; comment text;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 if p_id is not null then
  select * into current_row from public.crm_requests where id=p_id and company_id=actor.company_id for update;
  if not found or (actor.role='manager' and current_row.assigned_to is distinct from p_actor) then raise exception 'crm_not_found'; end if;
  if current_row.version <> p_version then raise exception 'crm_conflict'; end if;
 end if;
 assignee := case when p_data ? 'assigned_to' then nullif(p_data->>'assigned_to','')::bigint when p_id is null then p_actor else current_row.assigned_to end;
 if actor.role='manager' and ((p_id is null and assignee is distinct from p_actor) or (p_id is not null and assignee is distinct from current_row.assigned_to)) then raise exception 'crm_forbidden'; end if;
 if assignee is not null and not exists(select 1 from public.app_users where tg_id=assignee and active and company_id=actor.company_id and role in ('manager','owner','admin')) then raise exception 'crm_bad_assignee'; end if;
 new_status := coalesce(p_data->>'status',case when p_id is null then 'search' else current_row.status end);
 if new_status not in ('search','think','lost','won') then raise exception 'crm_bad_status'; end if;
 r := coalesce(p_data->'reasons',current_row.reasons,'[]'::jsonb);
 main := coalesce(p_data->>'main_reason',current_row.main_reason,'');
 comment := coalesce(p_data->>'note',current_row.note,'');
 if new_status='lost' then
  if jsonb_typeof(r)<>'array' or jsonb_array_length(r)=0 or jsonb_array_length(r)>20 then raise exception 'crm_reason_required'; end if;
  if not r ? main then main := r->>0; end if;
  if r ? 'Другое' and length(trim(comment))=0 then raise exception 'crm_comment_required'; end if;
 else r:='[]'; main:=''; end if;
 if p_id is null then
  if p_data->>'consent_at' is null then raise exception 'crm_consent_required'; end if;
  insert into public.crm_requests(company_id,created_by,assigned_to,client_name,phone,model,budget,generation,years,mileage,spec,city,payment,legal,purchase_time,source_text,consent_at,status,reasons,main_reason,note,next_contact_at)
  values(actor.company_id,p_actor,assignee,trim(p_data->>'client_name'),p_data->>'phone',trim(p_data->>'model'),(p_data->>'budget')::numeric,
   coalesce(p_data->>'generation',''),coalesce(p_data->>'years',''),nullif(p_data->>'mileage','')::integer,coalesce(p_data->>'spec',''),coalesce(p_data->>'city',''),coalesce(p_data->>'payment',''),coalesce(p_data->>'legal',''),coalesce(p_data->>'purchase_time',''),coalesce(p_data->>'source_text',''),(p_data->>'consent_at')::timestamptz,new_status,r,main,comment,nullif(p_data->>'next_contact_at','')::timestamptz)
  returning * into saved;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(actor.company_id,saved.id,p_actor,'created',jsonb_build_object('assigned_to',assignee,'status',new_status));
 else
  if p_data ? 'archived' and actor.role not in ('admin','owner') then raise exception 'crm_forbidden'; end if;
  update public.crm_requests set
   assigned_to=assignee,client_name=coalesce(trim(p_data->>'client_name'),client_name),phone=coalesce(p_data->>'phone',phone),model=coalesce(trim(p_data->>'model'),model),budget=coalesce((p_data->>'budget')::numeric,budget),
   generation=coalesce(p_data->>'generation',generation),years=coalesce(p_data->>'years',years),mileage=case when p_data ? 'mileage' then nullif(p_data->>'mileage','')::integer else mileage end,
   spec=coalesce(p_data->>'spec',spec),city=coalesce(p_data->>'city',city),payment=coalesce(p_data->>'payment',payment),legal=coalesce(p_data->>'legal',legal),purchase_time=coalesce(p_data->>'purchase_time',purchase_time),source_text=coalesce(p_data->>'source_text',source_text),
   status=new_status,reasons=r,main_reason=main,note=comment,
   next_contact_at=case when p_data ? 'next_contact_at' then nullif(p_data->>'next_contact_at','')::timestamptz else next_contact_at end,
   archived_at=case when p_data ? 'archived' then case when (p_data->>'archived')::boolean then now() else null end else archived_at end,
   version=version+1,updated_at=now()
  where id=p_id returning * into saved;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(actor.company_id,saved.id,p_actor,'updated',jsonb_build_object('from_status',current_row.status,'status',new_status,'from_assigned_to',current_row.assigned_to,'assigned_to',assignee,'archived',saved.archived_at is not null));
 end if;
 return to_jsonb(saved);
end $$;
revoke all on function public.crm_save_request(bigint,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.crm_save_request(bigint,uuid,integer,jsonb) to service_role;

alter table public.user_workspaces add column if not exists source_company_id uuid references public.app_companies(id);
update public.user_workspaces w set source_company_id=u.company_id from public.app_users u where w.user_id=u.tg_id and w.source_company_id is null;

-- Import only genuine custom requests from the existing personal spaces. Existing source records are never overwritten.
create or replace function public.crm_import_workspace(p_actor bigint)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare actor public.app_users%rowtype; state jsonb; item jsonb; client jsonb; imported integer:=0; changed integer; st text;
begin
 select * into actor from public.app_users where tg_id=p_actor;
 if not found or actor.role not in ('admin','owner','manager') then return 0; end if;
 select w.state into state from public.user_workspaces w where user_id=p_actor and w.source_company_id=actor.company_id;
 if state is null or jsonb_typeof(state->'requests')<>'array' then return 0; end if;
 for item in select value from jsonb_array_elements(state->'requests') loop
  client:=state->'clients'->(item->>'key');
  if item->>'crmId' is not null or client is null or coalesce(item->>'custom','false')<>'true' or coalesce(client->>'phone','') !~ '^[0-9]{10,15}$' or coalesce(item->>'title','')='' or coalesce(client->>'name','')='' then continue; end if;
  st:=coalesce(client->>'status','search');
  begin
   insert into public.crm_requests(company_id,created_by,assigned_to,source_user_id,source_key,client_name,phone,model,budget,generation,years,mileage,spec,city,payment,legal,purchase_time,source_text,consent_at,status,reasons,main_reason,note)
   values(actor.company_id,p_actor,p_actor,p_actor,item->>'key',client->>'name',client->>'phone',item->>'title',(item->>'budget')::numeric,coalesce(item->>'generation',''),coalesce(item->>'years',''),nullif(item->>'mileage','')::integer,coalesce(item->>'spec',''),coalesce(client->>'city',''),coalesce(client->>'payment',''),coalesce(client->>'legal',''),coalesce(client->>'purchaseTime',''),coalesce(item->>'sourceText',''),(client->>'consentAt')::timestamptz,st,coalesce(client->'reasons','[]'),coalesce(client->>'main',''),coalesce(client->>'note','')) on conflict do nothing;
   get diagnostics changed=row_count; imported:=imported+changed;
  exception when invalid_text_representation or check_violation or not_null_violation or datetime_field_overflow or invalid_datetime_format then continue;
  end;
 end loop;
 return imported;
end $$;
revoke all on function public.crm_import_workspace(bigint) from public,anon,authenticated;
grant execute on function public.crm_import_workspace(bigint) to service_role;
create index if not exists app_users_company on public.app_users(company_id);

create or replace function public.crm_list_requests(p_actor bigint,p_query text default '',p_status text default '',p_assignee text default '',p_archived boolean default false,p_page integer default 0)
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare actor public.app_users%rowtype; result jsonb;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 with base as (
  select r.*,u.name as assigned_name,u.active as assigned_active from public.crm_requests r left join public.app_users u on u.tg_id=r.assigned_to
  where r.company_id=actor.company_id and (actor.role in ('admin','owner') or r.assigned_to=p_actor)
   and ((p_archived and r.archived_at is not null) or (not p_archived and r.archived_at is null))
 ), filtered as (
  select * from base where (p_query='' or client_name ilike '%'||p_query||'%' or phone ilike '%'||p_query||'%' or model ilike '%'||p_query||'%')
   and (p_status='' or status=p_status or (p_status='overdue' and next_contact_at<now() and status in ('search','think'))) and (p_assignee='' or (p_assignee='unassigned' and assigned_to is null) or assigned_to::text=p_assignee)
 ), paged as (select * from filtered order by updated_at desc,id limit 100 offset greatest(0,p_page)*100)
 select jsonb_build_object(
  'requests',coalesce((select jsonb_agg(to_jsonb(paged)) from paged),'[]'::jsonb),
  'total',(select count(*) from filtered),
  'summary',(select jsonb_build_object('total',count(*),'search',count(*) filter(where status='search'),'think',count(*) filter(where status='think'),'lost',count(*) filter(where status='lost'),'won',count(*) filter(where status='won'),'unassigned',count(*) filter(where assigned_to is null),'overdue',count(*) filter(where next_contact_at<now() and status in ('search','think'))) from base),
  'workload',coalesce((select jsonb_agg(x) from (select assigned_to,assigned_name,assigned_active,count(*) as total,count(*) filter(where status in ('search','think')) as active_count from base group by assigned_to,assigned_name,assigned_active order by active_count desc) x),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function public.crm_list_requests(bigint,text,text,text,boolean,integer) from public,anon,authenticated;
grant execute on function public.crm_list_requests(bigint,text,text,text,boolean,integer) to service_role;

create or replace function public.crm_request_detail(p_actor bigint,p_id uuid)
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare actor public.app_users%rowtype; r public.crm_requests%rowtype;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 select * into r from public.crm_requests where id=p_id and company_id=actor.company_id;
 if not found or (actor.role='manager' and r.assigned_to is distinct from p_actor) then raise exception 'crm_not_found'; end if;
 return jsonb_build_object('request',to_jsonb(r),'activity',coalesce((select jsonb_agg(x) from (select a.id,a.kind,a.data,a.created_at,a.actor_id,u.name as actor_name from public.crm_activity a left join public.app_users u on u.tg_id=a.actor_id where a.request_id=p_id order by a.created_at desc,a.id desc limit 100) x),'[]'::jsonb));
end $$;
revoke all on function public.crm_request_detail(bigint,uuid) from public,anon,authenticated;
grant execute on function public.crm_request_detail(bigint,uuid) to service_role;

create or replace function public.crm_add_comment(p_actor bigint,p_id uuid,p_text text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare actor public.app_users%rowtype; r public.crm_requests%rowtype; saved public.crm_activity%rowtype;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 select * into r from public.crm_requests where id=p_id and company_id=actor.company_id for share;
 if not found or (actor.role='manager' and r.assigned_to is distinct from p_actor) then raise exception 'crm_not_found'; end if;
 if length(trim(p_text)) not between 1 and 4000 then raise exception 'crm_bad_comment'; end if;
 insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(actor.company_id,p_id,p_actor,'comment',jsonb_build_object('text',trim(p_text))) returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.crm_add_comment(bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.crm_add_comment(bigint,uuid,text) to service_role;
-- Preserve the original personal state before migrating its genuine requests.
alter table public.user_workspaces add column if not exists legacy_backup jsonb;
create or replace function public.crm_import_company(p_actor bigint)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare actor public.app_users%rowtype; target record; total integer:=0;
begin
 select * into actor from public.app_users where tg_id=p_actor and active;
 if not found or actor.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 for target in select tg_id from public.app_users where company_id=actor.company_id and role in ('admin','owner','manager') and (actor.role in ('admin','owner') or tg_id=p_actor) loop
  update public.user_workspaces set legacy_backup=state where user_id=target.tg_id and legacy_backup is null;
  total:=total+public.crm_import_workspace(target.tg_id);
 end loop;
 return total;
end $$;
revoke all on function public.crm_import_company(bigint) from public,anon,authenticated;
grant execute on function public.crm_import_company(bigint) to service_role;

create index if not exists crm_created_by on public.crm_requests(created_by);
create index if not exists crm_source_user on public.crm_requests(source_user_id);
create index if not exists crm_activity_actor on public.crm_activity(actor_id);
create index if not exists crm_activity_company on public.crm_activity(company_id);
create index if not exists workspace_source_company on public.user_workspaces(source_company_id);
