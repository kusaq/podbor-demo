-- Apply locally after contacts.sql and domain.sql. No public Data API access.
create table if not exists public.bot_supplier_profiles (
 user_id bigint primary key references public.app_users(tg_id) on update cascade on delete cascade,
 brands text[] not null default '{}', active boolean not null default true
);
create table if not exists public.bot_request_specs (
 request_id uuid primary key references public.crm_requests(id),company_id uuid not null references public.app_companies(id),brand text not null,model_at_selection text not null,color text not null default '',trim text not null default ''
);
create index if not exists bot_specs_company on public.bot_request_specs(company_id);
alter table public.bot_request_specs enable row level security;
revoke all on public.bot_request_specs from public,anon,authenticated;
grant select,insert,update on public.bot_request_specs to service_role;
create table if not exists public.bot_jobs (
 id bigint primary key, actor_id bigint not null, payload jsonb not null,
 state text not null default 'pending' check(state in ('pending','running','done','failed')),
 lease_until timestamptz, attempts integer not null default 0, transcript text, error_code text, created_at timestamptz not null default now()
);
create table if not exists public.bot_threads (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id),
 request_id uuid not null references public.crm_requests(id), supplier_id bigint not null references public.app_users(tg_id) on update cascade,
 code text not null default substr(replace(gen_random_uuid()::text,'-',''),1,12), unique(request_id,supplier_id),unique(code)
);
create table if not exists public.bot_context (
 user_id bigint primary key references public.app_users(tg_id) on update cascade on delete cascade,
 request_id uuid references public.crm_requests(id), thread_id uuid references public.bot_threads(id),
 company_id uuid references public.app_companies(id), offer_id uuid references public.request_offers(id), dialogue jsonb not null default '[]'
);
create table if not exists public.bot_proposals (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id), actor_id bigint not null references public.app_users(tg_id) on update cascade,
 request_id uuid references public.crm_requests(id), request_version integer, job_id bigint unique references public.bot_jobs(id), action text not null,
 data jsonb not null, transcript text not null, preview text not null, state text not null default 'pending',
 expires_at timestamptz not null default now()+interval '30 minutes', result jsonb, created_at timestamptz not null default now()
);
create table if not exists public.bot_messages (
 id uuid primary key default gen_random_uuid(),thread_id uuid not null references public.bot_threads(id), actor_id bigint not null references public.app_users(tg_id) on update cascade,
 job_id bigint unique references public.bot_jobs(id), parsed jsonb, sanitized_text text not null, redactions jsonb not null default '[]',created_at timestamptz not null default now()
);
create table if not exists public.bot_outbox (
 id uuid primary key default gen_random_uuid(), chat_id bigint not null references public.app_users(tg_id) on update cascade,
 actor_id bigint references public.app_users(tg_id) on update cascade, scope_company_id uuid references public.app_companies(id), request_id uuid references public.crm_requests(id), thread_id uuid references public.bot_threads(id), proposal_id uuid references public.bot_proposals(id),
 dedupe_key text unique, body jsonb not null, state text not null default 'pending' check(state in ('pending','sending','sent','failed','uncertain')),
 telegram_message_id bigint, error_code text,created_at timestamptz not null default now()
);
alter table public.bot_outbox add column if not exists message_id uuid references public.bot_messages(id);
create unique index if not exists bot_outbox_message on public.bot_outbox(message_id) where message_id is not null;
create index if not exists bot_jobs_pending on public.bot_jobs(state,lease_until,created_at);
create index if not exists bot_threads_supplier on public.bot_threads(supplier_id);
create index if not exists bot_threads_company on public.bot_threads(company_id);
create index if not exists bot_context_offer on public.bot_context(offer_id);
create index if not exists bot_context_request on public.bot_context(request_id);
create index if not exists bot_context_thread on public.bot_context(thread_id);
create index if not exists bot_proposal_actor on public.bot_proposals(actor_id,created_at);
create index if not exists bot_proposal_request on public.bot_proposals(request_id);
create index if not exists bot_messages_thread on public.bot_messages(thread_id,created_at);
create index if not exists bot_messages_actor on public.bot_messages(actor_id);
create index if not exists bot_outbox_pending on public.bot_outbox(state,created_at);
create index if not exists bot_outbox_thread on public.bot_outbox(thread_id,chat_id,telegram_message_id);
create index if not exists bot_outbox_proposal on public.bot_outbox(proposal_id);
create index if not exists bot_outbox_request on public.bot_outbox(request_id);
create index if not exists bot_outbox_scope on public.bot_outbox(scope_company_id);
create index if not exists bot_outbox_actor on public.bot_outbox(actor_id);
alter table public.bot_supplier_profiles enable row level security;
alter table public.bot_jobs enable row level security;
alter table public.bot_threads enable row level security;
alter table public.bot_context enable row level security;
alter table public.bot_proposals enable row level security;
alter table public.bot_messages enable row level security;
alter table public.bot_outbox enable row level security;
revoke all on public.bot_supplier_profiles,public.bot_jobs,public.bot_threads,public.bot_context,public.bot_proposals,public.bot_messages,public.bot_outbox from public,anon,authenticated;
grant select,insert,update on public.bot_supplier_profiles,public.bot_jobs,public.bot_threads,public.bot_context,public.bot_proposals,public.bot_messages,public.bot_outbox to service_role;

create or replace function public.bot_claim_job()
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare j public.bot_jobs%rowtype;
begin
 perform pg_advisory_xact_lock(710230191);
 update public.bot_jobs set state='failed',error_code='attempts_exhausted',lease_until=null where state='running' and lease_until<now() and attempts>=3;
 select * into j from public.bot_jobs where (state='pending' or state='running' and lease_until<now()) and attempts<3 and not exists(select 1 from public.bot_jobs active where active.actor_id=bot_jobs.actor_id and active.id<>bot_jobs.id and active.state='running' and active.lease_until>now()) order by created_at,id for update skip locked limit 1;
 if not found then return null;end if;
 update public.bot_jobs set state='running',lease_until=now()+interval '5 minutes',attempts=attempts+1 where id=j.id returning * into j;
 return to_jsonb(j);
end $$;
create or replace function public.bot_thread_access(p_actor bigint,p_thread uuid)
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare a public.app_users%rowtype;t public.bot_threads%rowtype;r public.crm_requests%rowtype;
begin
 select * into a from public.app_users where tg_id=p_actor and active;if not found then raise exception 'crm_forbidden';end if;
 select * into t from public.bot_threads where id=p_thread;select * into r from public.crm_requests where id=t.request_id;
 if t.id is null or r.archived_at is not null then raise exception 'crm_not_found';end if;
 if a.role='supplier' then
  if t.supplier_id<>p_actor then raise exception 'crm_not_found';end if;
 else
  perform public.crm_request_detail(p_actor,r.id);
 end if;
 return jsonb_build_object('thread',to_jsonb(t),'model',r.model,'manager',r.assigned_to);
end $$;
create or replace function public.bot_confirm(p_actor bigint,p_id uuid,p_accept boolean)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare a public.app_users%rowtype;q public.bot_proposals%rowtype;r public.crm_requests%rowtype;out jsonb;d jsonb;item jsonb;tid uuid;dest bigint;queued integer:=0;mid uuid;
begin
 select * into a from public.app_users where tg_id=p_actor and active and role in ('admin','owner','manager');if not found then raise exception 'crm_forbidden';end if;
 select * into q from public.bot_proposals where id=p_id and actor_id=p_actor and company_id=a.company_id for update;if not found then raise exception 'crm_not_found';end if;
 if q.request_id is not null then
  perform public.crm_request_detail(p_actor,q.request_id);
  select * into r from public.crm_requests where id=q.request_id for update;
  if r.archived_at is not null then raise exception 'backend_archived';end if;
 end if;
 if q.state='executed' then return q.result;end if;
 if q.state<>'pending' or q.expires_at<now() then raise exception 'crm_conflict';end if;
 if not p_accept then update public.bot_proposals set state='cancelled' where id=q.id;return '{"cancelled":true}';end if;
 if q.request_id is not null and r.version<>q.request_version then raise exception 'crm_conflict';end if;
 d:=q.data;
 if q.action='create_request' then
  if exists(select 1 from jsonb_object_keys(d->'fields') k where k not in ('client_name','phone','model','budget','generation','years','mileage','spec','city','purchase_time')) then raise exception 'crm_bad_data';end if;
  out:=public.crm_save_request(p_actor,null,0,(d->'fields')||jsonb_build_object('consent_at',now(),'source_text',q.transcript));
  update public.bot_proposals set request_id=(out->>'id')::uuid where id=q.id;
  select * into r from public.crm_requests where id=(out->>'id')::uuid;
  insert into public.bot_request_specs(request_id,company_id,brand,model_at_selection,color,trim)values(r.id,a.company_id,d->>'brand',r.model,coalesce(d->'supplier_fields'->>'color',''),coalesce(d->'supplier_fields'->>'trim',''));
 elsif q.action='update_request' then
  if exists(select 1 from jsonb_object_keys(d->'fields') k where k not in ('model','budget','generation','years','mileage','spec','status','reasons','main_reason','note','next_contact_at')) then raise exception 'crm_bad_data';end if;
  out:=public.crm_save_request(p_actor,r.id,r.version,d->'fields');
  if nullif(d->>'brand','') is not null then update public.bot_request_specs set brand=d->>'brand',model_at_selection=out->>'model' where request_id=r.id;end if;
 elsif q.action='add_note' then
  out:=public.crm_add_comment(p_actor,r.id,d->>'text');
 elsif q.action='mark_offer_sent' then
  if not exists(select 1 from public.request_offers where id=(d->>'offer_id')::uuid and request_id=r.id) then raise exception 'crm_not_found';end if;
  out:=public.crm_backend(p_actor,'offer.sent',jsonb_build_object('id',d->>'offer_id'));
 elsif q.action='supplier_option' then
  out:=public.crm_backend(p_actor,'option.save',(d->'option')||jsonb_build_object('request_id',r.id));
 elsif q.action='create_offer' then
  for item in select value from jsonb_array_elements(d->'options') loop
   if not exists(select 1 from public.request_options where id=(item->>'id')::uuid and request_id=r.id and version=(item->>'version')::integer) then raise exception 'crm_conflict';end if;
  end loop;
  out:=public.crm_backend(p_actor,'offer.create',jsonb_build_object('request_id',r.id,'option_ids',(select jsonb_agg(value->'id') from jsonb_array_elements(d->'options'))));
 elsif q.action in ('send_supplier_request','reply_supplier') then out:='{}';
 else raise exception 'backend_bad_action';end if;
 if q.action in ('send_supplier_request','reply_supplier','create_request') and jsonb_array_length(coalesce(d->'deliveries','[]'))>0 then
  for item in select value from jsonb_array_elements(d->'deliveries') loop
   dest:=(item->>'supplier_id')::bigint;
   if q.action<>'reply_supplier' and to_regprocedure('public.workflow_routes(uuid,text)') is not null then
    if not exists(select 1 from public.workflow_routes(r.company_id,d->>'brand') w where w.supplier=dest) then raise exception 'crm_bad_assignee';end if;
   elsif not exists(select 1 from public.app_users u join public.bot_supplier_profiles p on p.user_id=u.tg_id where u.tg_id=dest and u.active and u.role='supplier' and p.active and (d->>'brand')=any(p.brands)) then raise exception 'crm_bad_assignee';end if;
   if q.action='reply_supplier' then
    select id into tid from public.bot_threads where request_id=r.id and supplier_id=dest;
    if not found then raise exception 'crm_not_found'; end if;
   else
    insert into public.bot_threads(company_id,request_id,supplier_id,code)
    values(a.company_id,r.id,dest,coalesce(item->>'code',substr(replace(gen_random_uuid()::text,'-',''),1,12)))
    on conflict(request_id,supplier_id) do nothing returning id into tid;
    if not found then continue; end if;
   end if;
   queued:=queued+1;
   insert into public.bot_messages(thread_id,actor_id,sanitized_text,redactions) values(tid,p_actor,item->>'text',coalesce(item->'redactions','[]')) returning id into mid;
   insert into public.bot_outbox(chat_id,actor_id,thread_id,proposal_id,message_id,body) values(dest,p_actor,tid,q.id,mid,jsonb_build_object('text',item->>'text','reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Открыть диалог','callback_data','thread:'||tid::text))))));
  end loop;
  out:=out||jsonb_build_object('queued',queued);
 end if;
 update public.bot_proposals set state='executed',result=out where id=q.id;
 return out;
end $$;
revoke all on function public.bot_claim_job(),public.bot_thread_access(bigint,uuid),public.bot_confirm(bigint,uuid,boolean) from public,anon,authenticated;
grant execute on function public.bot_claim_job(),public.bot_thread_access(bigint,uuid),public.bot_confirm(bigint,uuid,boolean) to service_role;
