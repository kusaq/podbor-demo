-- Apply after domain.sql, contacts.sql and bot.sql.
create table if not exists public.supplier_terms (
 company_id uuid not null references public.app_companies(id),
 supplier_id bigint not null references public.app_users(tg_id) on update cascade,
 revision integer not null, currency text not null check(currency in ('RUB','CNY','JPY','USD','EUR')),
 fees jsonb not null, primary key(company_id,supplier_id)
);
create table if not exists public.workflow_policy (
 company_id uuid primary key references public.app_companies(id), revision integer not null,
 supplier_hours integer not null check(supplier_hours between 1 and 168),
 escalation_hours integer not null check(escalation_hours between supplier_hours and 336),
 client_days integer not null check(client_days between 1 and 30)
);
create table if not exists public.workflow_creates (
 actor_id bigint not null references public.app_users(tg_id) on update cascade,
 token uuid not null, request_id uuid not null references public.crm_requests(id),
 payload jsonb not null, primary key(actor_id,token)
);
alter table public.bot_messages add column if not exists album text;
alter table public.bot_messages add column if not exists option_id uuid references public.request_options(id);
create unique index if not exists bot_album on public.bot_messages(actor_id,album) where album is not null;
create table if not exists public.supplier_photos (
 id uuid primary key default gen_random_uuid(), message_id uuid not null references public.bot_messages(id),
 job_id bigint unique not null references public.bot_jobs(id),
 jpeg text not null check(octet_length(jpeg) between 4 and 360000)
);
create table if not exists public.supplier_input_refs (
 actor_id bigint not null references public.app_users(tg_id) on update cascade,
 telegram_id bigint not null,message_id uuid not null references public.bot_messages(id),
 primary key(actor_id,telegram_id)
);
alter table public.supplier_input_refs enable row level security;
revoke all on public.supplier_input_refs from public,anon,authenticated;
grant select,insert on public.supplier_input_refs to service_role;
create index if not exists supplier_photo_message on public.supplier_photos(message_id);
alter table public.bot_outbox add column if not exists delivered_at timestamptz;
alter table public.bot_outbox add column if not exists reminder text;
create table if not exists public.request_listings (
 request_id uuid not null references public.crm_requests(id), url text not null check(length(url)<=1000 and url ~ '^https://[^[:space:]]+$'),
 title text not null check(length(title) between 1 and 200), purchase numeric check(purchase>0 and purchase<=100000000000),
 term text not null check(length(term)<=180), primary key(request_id,url)
);
alter table public.request_listings enable row level security;
revoke all on public.request_listings from public,anon,authenticated;
grant select,insert,update on public.request_listings to service_role;
create table if not exists public.search_sources (
 request_id uuid not null references public.crm_requests(id), source text not null check(source in ('stock','market')),
 state text not null default 'pending' check(state in ('pending','running','ready','unconfigured','failed')),
 results jsonb not null default '[]', claimed_at timestamptz, attempt integer not null default 0,
 primary key(request_id,source)
);
create index if not exists search_sources_pending on public.search_sources(state,claimed_at);
alter table public.supplier_terms enable row level security;
alter table public.workflow_policy enable row level security;
alter table public.workflow_creates enable row level security;
alter table public.supplier_photos enable row level security;
alter table public.search_sources enable row level security;
revoke all on public.supplier_terms,public.workflow_policy,public.workflow_creates,public.supplier_photos,public.search_sources from public,anon,authenticated;
grant select,insert,update on public.supplier_terms,public.workflow_policy,public.workflow_creates,public.supplier_photos,public.search_sources to service_role;

create or replace function public.workflow_start_sources() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into search_sources(request_id,source) values(new.request_id,'stock'),(new.request_id,'market') on conflict do nothing;
 return new;
end $$;
create or replace trigger workflow_start_sources after insert on public.bot_request_specs
 for each row execute function public.workflow_start_sources();

create or replace function public.workflow_dispatch(p_actor bigint,p_request uuid,p_brand text,p_color text,p_trim text)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare r crm_requests; t bot_threads; supplier bigint; mid uuid; body text; n integer:=0; brand text:=lower(trim(p_brand)); v text;
begin
 perform crm_request_detail(p_actor,p_request);
 select * into strict r from crm_requests where id=p_request for update;
 if r.archived_at is not null or r.status not in ('search','think') then raise exception 'backend_closed'; end if;
 if nullif(brand,'') is null then
  select b into brand from bot_supplier_profiles sp cross join unnest(sp.brands) b where sp.active and
   (lower(r.model)=b or starts_with(lower(r.model),b||' ')) order by length(b) desc limit 1;
  brand:=coalesce(brand,lower(split_part(trim(r.model),' ',1)));
 end if;
 if nullif(brand,'') is null or length(brand)>80 or length(p_trim)>160 or length(p_color)>100 then raise exception 'backend_bad_data'; end if;
 -- Only the public vehicle fields ever go into the supplier request. Reject contact-like input.
 foreach v in array array[brand,r.model,r.generation,r.years,p_color,p_trim] loop
  if v ~* '(@|https?://|www\.|t\.me/|[[:cntrl:]]|[+]?[0-9][0-9 ()-]{8,}[0-9])' or
    length(trim(r.client_name))>=3 and strpos(lower(v),lower(trim(r.client_name)))>0 then raise exception 'backend_bad_data'; end if;
 end loop;
 insert into bot_request_specs(request_id,company_id,brand,model_at_selection,color,trim)
 values(r.id,r.company_id,brand,r.model,p_color,p_trim)
 on conflict(request_id) do update set brand=excluded.brand,model_at_selection=excluded.model_at_selection,color=excluded.color,trim=excluded.trim;
 for supplier in select u.tg_id from app_users u join bot_supplier_profiles p on p.user_id=u.tg_id where
  u.active and u.role='supplier' and p.active and brand=any(p.brands) loop
  insert into bot_threads(company_id,request_id,supplier_id) values(r.company_id,r.id,supplier)
  on conflict(request_id,supplier_id) do nothing returning * into t;
  if not found then continue; end if;
  body:=concat_ws(E'\n','Запрос № '||t.code,'Марка: '||brand,'Модель: '||r.model,
   'Поколение: '||coalesce(nullif(r.generation,''),'не указано'),'Годы: '||coalesce(nullif(r.years,''),'не указаны'),
   'Пробег до, км: '||coalesce(r.mileage::text,'не указан'),'Цвет: '||coalesce(nullif(p_color,''),'не указан'),
   'Комплектация: '||coalesce(nullif(p_trim,''),'не указана'),
   'Ответьте на это сообщение. Укажите модель, год, пробег, цену, валюту и срок. Фото одной машины можно отправить альбомом.');
  insert into bot_messages(thread_id,actor_id,sanitized_text) values(t.id,p_actor,body) returning id into mid;
  insert into bot_outbox(chat_id,actor_id,thread_id,message_id,dedupe_key,body) values(supplier,p_actor,t.id,mid,'dispatch:'||t.id,
   jsonb_build_object('text',body,'reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Открыть диалог','callback_data','thread:'||t.id))))));
  n:=n+1;
 end loop;
 return n;
end $$;

create or replace function public.workflow_create(p_actor bigint,p_token uuid,p_data jsonb,p_search jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare saved workflow_creates; r jsonb; n integer; payload jsonb:=jsonb_build_array(p_data-'consent_at',p_search);
begin
 if p_token is null or p_data->>'consent_at' is null then raise exception 'crm_consent_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||p_token::text,0));
 select * into saved from workflow_creates where actor_id=p_actor and token=p_token;
 if found then
  if saved.payload<>payload then raise exception 'crm_conflict'; end if;
  return jsonb_build_object('request',crm_request_detail(p_actor,saved.request_id)->'request',
    'queued',(select count(*) from bot_threads where request_id=saved.request_id));
 end if;
 r:=crm_save_request(p_actor,null,0,p_data);
 n:=workflow_dispatch(p_actor,(r->>'id')::uuid,p_search->>'brand',coalesce(p_search->>'color',''),coalesce(p_search->>'trim',''));
 insert into workflow_creates values(p_actor,p_token,(r->>'id')::uuid,payload);
 return jsonb_build_object('request',r,'queued',n);
end $$;

create or replace function public.workflow_receive(p_actor bigint,p_thread uuid,p_job bigint,p_album text,p_text text,p_parsed jsonb,p_jpeg text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare t bot_threads; m bot_messages; manager bigint; group_key text:=nullif(p_album,''); inbound jsonb; prior bot_messages;
begin
 perform bot_thread_access(p_actor,p_thread);
 select * into strict t from bot_threads where id=p_thread and supplier_id=p_actor for update;
 if not exists(select 1 from bot_jobs where id=p_job and actor_id=p_actor) then raise exception 'crm_forbidden'; end if;
 select payload->'message' into inbound from bot_jobs where id=p_job;
 if group_key is null and p_jpeg is not null then group_key:='image:'||p_job; end if;
 if group_key is null and inbound->'reply_to_message'->'from'->>'id'=p_actor::text then
  select bm.* into prior from supplier_input_refs ref join bot_messages bm on bm.id=ref.message_id
   where ref.actor_id=p_actor and ref.telegram_id=(inbound->'reply_to_message'->>'message_id')::bigint and bm.thread_id=t.id;
  if prior.sanitized_text='' and prior.option_id is null then group_key:=prior.album; end if;
 end if;
 if length(p_text)>4000 or length(group_key)>100 then raise exception 'backend_bad_data'; end if;
 select * into m from bot_messages where actor_id=p_actor and (job_id=p_job or album=group_key) for update;
 if found and m.thread_id<>p_thread then raise exception 'crm_conflict'; end if;
 if m.id is null then
  insert into bot_messages(thread_id,actor_id,job_id,album,sanitized_text,parsed)
  values(t.id,p_actor,p_job,group_key,p_text,p_parsed) returning * into m;
 elsif group_key is not null and length(p_text)>0 and length(m.sanitized_text)=0 then
  update bot_messages set sanitized_text=p_text,parsed=p_parsed where id=m.id returning * into m;
 end if;
 if inbound->>'message_id' is not null then
  insert into supplier_input_refs values(p_actor,(inbound->>'message_id')::bigint,m.id) on conflict do nothing;
 end if;
 if p_jpeg is not null then
  insert into supplier_photos(message_id,job_id,jpeg) values(m.id,p_job,p_jpeg) on conflict(job_id) do nothing;
 end if;
 select assigned_to into manager from crm_requests where id=t.request_id;
 if manager is not null then
  insert into bot_outbox(chat_id,actor_id,thread_id,dedupe_key,body) values(manager,p_actor,t.id,'received:'||m.id,
   jsonb_build_object('text','Ответ поставщика по запросу '||t.code||E'\n'||coalesce(nullif(m.sanitized_text,''),'Получены фотографии. Откройте подбор в CRM.'),
    'reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Открыть диалог','callback_data','thread:'||t.id)))))) on conflict(dedupe_key) do nothing;
 end if;
 return jsonb_build_object('id',m.id,'thread_id',t.id);
end $$;

create or replace function public.crm_workflow(p_actor bigint,p_action text,p jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare a app_users; r crm_requests; t bot_threads; m bot_messages; u app_users; terms supplier_terms; pol workflow_policy;
 photos uuid[]; photo uuid; result jsonb; k text; fees jsonb; brands text[]; body text; dest bigint; rev int; oldrev int;
begin
 select * into a from app_users where tg_id=p_actor and active and role in ('manager','owner','admin');
 if not found then raise exception 'crm_forbidden'; end if;
 if p_action in ('network','terms.save','policy.save') then
  if a.role='manager' then raise exception 'crm_forbidden'; end if;
  if p_action='network' then
   return jsonb_build_object('suppliers',coalesce((select jsonb_agg(x order by x.name) from (
    select case when u1.company_id=a.company_id then u1.tg_id::text else md5(a.company_id::text||':'||u1.tg_id) end as id, case when u1.company_id=a.company_id then u1.name else 'Поставщик '||right(md5(u1.tg_id::text),6) end as name,
     u1.company_id=a.company_id as owned, p1.brands,coalesce(p1.active,false) as enabled,u1.active,
     coalesce(s.revision,0) as revision,coalesce(s.currency,'RUB') as currency,coalesce(s.fees,'{}') as fees
    from app_users u1 left join bot_supplier_profiles p1 on p1.user_id=u1.tg_id
    left join supplier_terms s on s.company_id=a.company_id and s.supplier_id=u1.tg_id
    where u1.role='supplier' and (u1.company_id=a.company_id or u1.active and p1.active)) x),'[]'),
    'policy',coalesce((select to_jsonb(w) from workflow_policy w where company_id=a.company_id),
     '{"revision":0,"supplier_hours":2,"escalation_hours":6,"client_days":2}'::jsonb));
  end if;
  perform pg_advisory_xact_lock(hashtextextended(a.company_id::text||p_action||coalesce(p->>'id',''),0));
  if p_action='policy.save' then
   select * into pol from workflow_policy where company_id=a.company_id;
   if coalesce(pol.revision,0) is distinct from (p->>'revision')::int then raise exception 'crm_conflict'; end if;
   insert into workflow_policy values(a.company_id,coalesce(pol.revision,0)+1,(p->>'supplier_hours')::int,(p->>'escalation_hours')::int,(p->>'client_days')::int)
    on conflict(company_id) do update set revision=excluded.revision,supplier_hours=excluded.supplier_hours,escalation_hours=excluded.escalation_hours,client_days=excluded.client_days;
   return '{"ok":true}';
  end if;
  select * into u from app_users where (case when company_id=a.company_id then tg_id::text else md5(a.company_id::text||':'||tg_id) end)=p->>'id' and role='supplier' and
   (company_id=a.company_id or active and exists(select 1 from bot_supplier_profiles where user_id=tg_id and active));
  if not found then raise exception 'crm_not_found'; end if;
  select revision into rev from supplier_terms where supplier_id=u.tg_id and company_id=a.company_id;
  if coalesce(rev,0) is distinct from (p->>'revision')::int then raise exception 'crm_conflict'; end if;
  fees:=p->'fees';
  foreach k in array array['logistics','commission','duty','recycling','documents'] loop
   if jsonb_typeof(fees->k) is distinct from 'number' or (fees->>k)::numeric not between 0 and 1000000000 then raise exception 'backend_bad_data'; end if;
  end loop;
  if u.company_id=a.company_id then
   if jsonb_typeof(p->'brands') is distinct from 'array' or jsonb_typeof(p->'enabled') is distinct from 'boolean' then raise exception 'backend_bad_data'; end if;
   select array(select distinct lower(trim(value)) from jsonb_array_elements_text(p->'brands') where trim(value)<>'') into brands;
   if cardinality(brands)>100 or exists(select 1 from unnest(brands) b where length(b)>80) or (p->>'enabled')::boolean and cardinality(brands)=0 then raise exception 'backend_bad_data'; end if;
   insert into bot_supplier_profiles(user_id,brands,active) values(u.tg_id,brands,(p->>'enabled')::boolean)
    on conflict(user_id) do update set brands=excluded.brands,active=excluded.active;
  end if;
  insert into supplier_terms values(a.company_id,u.tg_id,coalesce(rev,0)+1,p->>'currency',fees)
   on conflict(company_id,supplier_id) do update set revision=excluded.revision,currency=excluded.currency,fees=excluded.fees;
  return '{"ok":true}';
 end if;
 perform crm_request_detail(p_actor,(p->>'request_id')::uuid);
 select * into strict r from crm_requests where id=(p->>'request_id')::uuid for update;
 if p_action='inbox' then
  return jsonb_build_object('spec',(select to_jsonb(b)-'company_id' from bot_request_specs b where b.request_id=r.id),
   'listings',coalesce((select jsonb_agg(jsonb_build_object('title',l.title,'purchase',l.purchase,'currency','RUB','term',l.term,'link',l.url) order by l.title) from request_listings l where l.request_id=r.id),'[]'),
   'sources',coalesce((select jsonb_agg(to_jsonb(s)-'request_id') from search_sources s where s.request_id=r.id),'[]'),
   'threads',coalesce((select jsonb_agg(jsonb_build_object('id',th.id,'code',th.code,
    'name',case when su.company_id=a.company_id then su.name else 'Поставщик '||right(md5(su.tg_id::text),6) end,
    'terms',to_jsonb(tr)-'company_id'-'supplier_id',
    'delivery',(select b.state from bot_outbox b where b.thread_id=th.id and b.chat_id=th.supplier_id order by created_at,id limit 1),
    'messages',coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'incoming',z.actor_id=th.supplier_id,'text',z.sanitized_text,
     'parsed',z.parsed,'at',z.created_at,'option_id',z.option_id,
     'delivery',(select b.state from bot_outbox b where b.message_id=z.id),
     'photos',coalesce((select jsonb_agg(f.id order by f.job_id) from supplier_photos f where f.message_id=z.id),'[]')) order by z.created_at,z.id)
     from bot_messages z where z.thread_id=th.id),'[]')) order by th.code)
    from bot_threads th join app_users su on su.tg_id=th.supplier_id left join supplier_terms tr on tr.supplier_id=su.tg_id and tr.company_id=r.company_id
    where th.request_id=r.id),'[]'));
 end if;
 if p_action='photo' then
  select jsonb_build_object('data','data:image/jpeg;base64,'||f.jpeg) into result from supplier_photos f
   join bot_messages m1 on m1.id=f.message_id join bot_threads t1 on t1.id=m1.thread_id where f.id=(p->>'id')::uuid and t1.request_id=r.id;
  if not found then raise exception 'crm_not_found'; end if;
  return result;
 end if;
 if r.archived_at is not null or r.status not in ('search','think') then raise exception 'backend_closed'; end if;
 if p_action='dispatch' then return jsonb_build_object('queued',workflow_dispatch(p_actor,r.id,p->>'brand',coalesce(p->>'color',''),coalesce(p->>'trim',''))); end if;
 if p_action='listing.save' then
  insert into request_listings values(r.id,p->>'url',trim(p->>'title'),nullif(p->>'purchase','')::numeric,coalesce(p->>'term',''))
   on conflict(request_id,url) do update set title=excluded.title,purchase=excluded.purchase,term=excluded.term;
  return '{"ok":true}';
 end if;
 if p_action='search.retry' then
  update search_sources set state='pending',attempt=attempt+1 where request_id=r.id and state in ('unconfigured','ready','failed');
  return '{"ok":true}';
 end if;
 if p_action='reply' then
  select * into t from bot_threads where id=(p->>'thread_id')::uuid and request_id=r.id;
  if not found then raise exception 'crm_not_found'; end if;
  perform bot_thread_access(p_actor,t.id);
  body:=trim(p->>'text');
  if length(body) not between 1 and 2500 or body is null or p->>'token' is null then raise exception 'backend_bad_data'; end if;
  k:='reply:'||p_actor||':'||(p->>'token')::uuid;
  if exists(select 1 from bot_outbox where dedupe_key=k and (thread_id<>t.id or bot_outbox.body->>'text'<>('Запрос '||t.code||E'\n'||trim(p->>'text')))) then raise exception 'crm_conflict'; end if;
  insert into bot_outbox(chat_id,actor_id,thread_id,dedupe_key,body) values(t.supplier_id,p_actor,t.id,k,
   jsonb_build_object('text','Запрос '||t.code||E'\n'||body)) on conflict(dedupe_key) do nothing;
  if found then
   insert into bot_messages(thread_id,actor_id,sanitized_text) values(t.id,p_actor,body) returning * into m;
   update bot_outbox set message_id=m.id where dedupe_key=k;
  end if;
  return '{"ok":true}';
 end if;
 if p_action='option.fromReply' then
  select z.* into m from bot_messages z join bot_threads th on th.id=z.thread_id and th.supplier_id=z.actor_id
   where z.id=(p->>'message_id')::uuid and th.request_id=r.id for update of z;
  if not found then raise exception 'crm_not_found'; end if;
  if m.option_id is distinct from nullif(p->'option'->>'id','')::uuid then raise exception 'crm_conflict'; end if;
  select * into t from bot_threads where id=m.thread_id;
  select * into terms from supplier_terms where company_id=a.company_id and supplier_id=t.supplier_id for share;
  if m.option_id is null and coalesce(terms.revision,0) is distinct from (p->>'terms_revision')::int then raise exception 'crm_conflict'; end if;
  select array(select value::uuid from jsonb_array_elements_text(p->'photos')) into photos;
  if cardinality(photos)>10 or cardinality(photos)<>(select count(distinct i) from unnest(photos) i) then raise exception 'backend_bad_data'; end if;
  foreach photo in array photos loop
   if not exists(select 1 from supplier_photos f join bot_messages bm on bm.id=f.message_id where f.id=photo and bm.thread_id=t.id) then raise exception 'crm_not_found'; end if;
  end loop;
  result:=crm_backend(p_actor,'option.save',(p->'option')||
   jsonb_build_object('request_id',r.id,'source_name','Запрос '||t.code));
  update request_options set photo_ids=photos,calculation=case when m.option_id is not null then calculation else calculation||jsonb_build_object('supplier_thread',t.id,'terms_revision',coalesce(terms.revision,0),'supplier_fees',terms.fees) end
   where id=(result->'option'->>'id')::uuid;
  update bot_messages set option_id=(result->'option'->>'id')::uuid where id=m.id;
  return jsonb_build_object('id',result->'option'->>'id');
 end if;
 raise exception 'backend_bad_action';
end $$;

create or replace function public.workflow_claim_sources() returns setof jsonb language sql security invoker set search_path=public,pg_temp as $$
 with todo as (select s.request_id,s.source from search_sources s join crm_requests r on r.id=s.request_id
 where r.archived_at is null and r.status in ('search','think') and (state='pending' or state='running' and claimed_at<now()-interval '3 minutes')
 order by s.claimed_at nulls first,s.request_id,s.source limit 6 for update of s skip locked),
 claimed as (update search_sources s set state='running',claimed_at=now(),attempt=attempt+1 from todo
 where (s.request_id,s.source)=(todo.request_id,todo.source) returning s.*)
 select jsonb_build_object('request_id',c.request_id,'source',c.source,'attempt',c.attempt,'company',r.company_id,'model',r.model)
 from claimed c join crm_requests r on r.id=c.request_id;
$$;

create or replace function public.workflow_sent_clock() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if new.state='sent' and old.state<>'sent' then new.delivered_at:=coalesce(new.delivered_at,now()); end if;
 return new;
end $$;
create or replace trigger workflow_sent_clock before update of state on public.bot_outbox for each row execute function public.workflow_sent_clock();

create or replace function public.workflow_contact_due() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if new.sent_at is not null and old.sent_at is null then
  update crm_requests set next_contact_at=case when next_contact_at>new.sent_at then next_contact_at else
   new.sent_at+make_interval(days=>coalesce((select client_days from workflow_policy where company_id=new.company_id),2)) end where id=new.request_id;
 end if;
 return new;
end $$;
create or replace trigger workflow_offer_due after update of sent_at on public.request_offers for each row execute function public.workflow_contact_due();

create or replace view public.workflow_due with (security_invoker=true) as
 with waiting as (
 select th.id thread_id,r.id request_id,r.company_id,th.supplier_id,r.assigned_to,th.code,
  first_send.delivered_at, coalesce(pol.supplier_hours,2) supplier_hours,coalesce(pol.escalation_hours,6) escalation_hours
 from bot_threads th join crm_requests r on r.id=th.request_id join bot_supplier_profiles sp on sp.user_id=th.supplier_id and sp.active
 join app_users su on su.tg_id=th.supplier_id and su.active and su.role='supplier'
 left join workflow_policy pol on pol.company_id=r.company_id
 cross join lateral (select min(b.delivered_at) delivered_at from bot_outbox b where b.thread_id=th.id and b.chat_id=th.supplier_id and b.reminder is null and b.state='sent') first_send
 where first_send.delivered_at is not null and r.archived_at is null and r.status in ('search','think')
 and not exists(select 1 from bot_messages m where m.thread_id=th.id and m.actor_id=th.supplier_id)
 )
 select 'supplier:'||thread_id as key,'supplier' as kind,supplier_id as recipient, supplier_id as actor,thread_id,request_id,company_id,
  'Запрос '||code||'. Есть ли подходящая машина? Ответьте на это сообщение.' as message from waiting
 where delivered_at+make_interval(hours=>supplier_hours)<=now()
 union all
 select 'escalation:'||thread_id||':'||assigned_to,'escalation',assigned_to,assigned_to,thread_id,request_id,company_id,
  'По запросу '||code||' поставщик ещё не ответил. Проверьте подбор в CRM.' from waiting
 where assigned_to is not null and delivered_at+make_interval(hours=>escalation_hours)<=now()
 union all
 select 'feedback:'||f.id||':'||r.assigned_to||':'||extract(epoch from r.next_contact_at),'feedback',r.assigned_to,r.assigned_to,null::uuid,r.id,r.company_id,
  'Что ответил клиент по КП №'||f.number||' ('||r.model||')? Запишите результат в карточке клиента и обновите статус.'
 from crm_requests r cross join lateral (select o.id,o.number,o.sent_at from request_offers o where o.request_id=r.id and o.sent_at is not null order by o.sent_at desc,o.number desc limit 1) f
 where r.archived_at is null and r.status='think' and r.assigned_to is not null and r.next_contact_at<=now()
 and not exists(select 1 from crm_activity c where c.request_id=r.id and c.kind='contact' and c.data->>'result'='connected' and c.created_at>f.sent_at and (c.data->'submitted_data'->>'next_contact_at' is null or r.next_contact_at<=c.created_at));
revoke all on public.workflow_due from public,anon,authenticated;
grant select on public.workflow_due to service_role;
create or replace function public.workflow_queue_due() returns void language sql security invoker set search_path=public,pg_temp as $$
 insert into bot_outbox(chat_id,actor_id,scope_company_id,request_id,thread_id,reminder,dedupe_key,body)
 select d.recipient,d.actor,d.company_id,d.request_id,d.thread_id,d.kind,d.key,jsonb_build_object('text',d.message)
 from workflow_due d where not exists(select 1 from bot_outbox b where b.dedupe_key=d.key)
 order by d.key limit 200 on conflict(dedupe_key) do nothing;
$$;
revoke all on function public.workflow_start_sources(),public.workflow_dispatch(bigint,uuid,text,text,text),public.workflow_create(bigint,uuid,jsonb,jsonb),public.workflow_receive(bigint,uuid,bigint,text,text,jsonb,text),public.crm_workflow(bigint,text,jsonb),public.workflow_claim_sources(),public.workflow_sent_clock(),public.workflow_contact_due(),public.workflow_queue_due() from public,anon,authenticated;
grant execute on function public.workflow_start_sources(),public.workflow_dispatch(bigint,uuid,text,text,text),public.workflow_create(bigint,uuid,jsonb,jsonb),public.workflow_receive(bigint,uuid,bigint,text,text,jsonb,text),public.crm_workflow(bigint,text,jsonb),public.workflow_claim_sources(),public.workflow_sent_clock(),public.workflow_contact_due(),public.workflow_queue_due() to service_role;
