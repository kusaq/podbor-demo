create table if not exists public.dealer_assets (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id),
 name text not null check(length(name) between 1 and 200), content_type text not null check(content_type in ('application/pdf','image/png','image/jpeg')),
 data_url text not null check(octet_length(data_url)<=2800000), created_by bigint references public.app_users(tg_id) on delete set null on update cascade,
 created_at timestamptz not null default now()
);
create table if not exists public.dealer_settings (
 company_id uuid primary key references public.app_companies(id), revision integer not null default 1,
 dealer jsonb not null default '{"name":"","inn":"","address":"","phone":""}',
 pricing jsonb not null default '{"median_enabled":true,"median_pct":5,"margin_enabled":true,"margin_pct":3}',
 exchange jsonb not null default '{"mode":"percent","percent":2,"add":0,"fixed":1}',
 valid_days integer not null default 7 check(valid_days between 1 and 60),
 letterhead_id uuid references public.dealer_assets(id), updated_at timestamptz not null default now()
);
create table if not exists public.request_options (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.crm_requests(id), company_id uuid not null references public.app_companies(id),
 title text not null check(length(title) between 1 and 200), description text not null default '' check(length(description)<=2000),
 scenario text not null check(scenario in ('rf','import')), currency text not null check(currency in ('RUB','CNY','JPY','USD','EUR')),
 input jsonb not null, calculation jsonb not null, purchase_rub numeric not null check(purchase_rub>0), total_cost numeric not null check(total_cost>0),
 client_price numeric not null check(client_price>=total_cost and client_price<=100000000000), market_median numeric check(market_median>0), term text not null default '',
 source_name text not null default '' check(length(source_name)<=200),
 approval text not null default 'none' check(approval in ('none','pending','approved','rejected')),
 approved_fingerprint text, archived boolean not null default false, version integer not null default 1,
 created_by bigint references public.app_users(tg_id) on delete set null on update cascade, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.request_options add column if not exists photo_ids uuid[] not null default '{}';
create table if not exists public.price_decisions (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id), request_id uuid not null references public.crm_requests(id),
 option_id uuid not null references public.request_options(id), actor_id bigint references public.app_users(tg_id) on delete set null on update cascade,
 actor_name text not null, decision text not null check(decision in ('requested','approved','rejected')), note text not null default '', snapshot jsonb not null, created_at timestamptz not null default now()
);
create table if not exists public.request_offers (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id), request_id uuid not null references public.crm_requests(id),
 number integer not null, model jsonb not null, validation jsonb not null, option_ids uuid[] not null, actor_id bigint references public.app_users(tg_id) on delete set null on update cascade,
 letterhead_id uuid references public.dealer_assets(id), created_at timestamptz not null default now(), sent_at timestamptz,
 sent_by bigint references public.app_users(tg_id) on delete set null on update cascade, unique(request_id,number)
);
create table if not exists public.dealer_events (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.app_companies(id),actor_id bigint references public.app_users(tg_id) on delete set null on update cascade,
 kind text not null, data jsonb not null default '{}', created_at timestamptz not null default now()
);
create index if not exists dealer_assets_company on public.dealer_assets(company_id);
create index if not exists dealer_assets_creator on public.dealer_assets(created_by);
create index if not exists dealer_settings_asset on public.dealer_settings(letterhead_id);
create index if not exists request_options_request on public.request_options(request_id,updated_at desc);
create index if not exists request_options_company on public.request_options(company_id);
create index if not exists request_options_creator on public.request_options(created_by);
create index if not exists decisions_request on public.price_decisions(request_id,created_at desc);
create index if not exists decisions_option on public.price_decisions(option_id);
create index if not exists decisions_company on public.price_decisions(company_id);
create index if not exists decisions_actor on public.price_decisions(actor_id);
create index if not exists offers_company on public.request_offers(company_id);
create index if not exists offers_actor on public.request_offers(actor_id);
create index if not exists offers_sender on public.request_offers(sent_by);
create index if not exists offers_asset on public.request_offers(letterhead_id);
create index if not exists dealer_events_company on public.dealer_events(company_id,created_at desc);
create index if not exists dealer_events_actor on public.dealer_events(actor_id);
alter table public.dealer_assets enable row level security;
alter table public.dealer_settings enable row level security;
alter table public.request_options enable row level security;
alter table public.price_decisions enable row level security;
alter table public.request_offers enable row level security;
alter table public.dealer_events enable row level security;
revoke all on public.dealer_assets,public.dealer_settings,public.request_options,public.price_decisions,public.request_offers,public.dealer_events from public,anon,authenticated;
grant select,insert on public.dealer_assets,public.price_decisions,public.dealer_events to service_role;
grant select,insert,update on public.dealer_settings,public.request_options,public.request_offers to service_role;

create or replace function public.option_evaluation(o public.request_options,s public.dealer_settings)
returns jsonb language plpgsql immutable security invoker set search_path=public,pg_temp as $$
declare reasons jsonb:='[]'; fingerprint text; margin numeric;
begin
 margin:=round((o.client_price-o.total_cost)/o.purchase_rub*100,2);
 if coalesce((s.pricing->>'median_enabled')::boolean,true) then
  if o.market_median is null then reasons:=reasons||'"Медиана рынка не указана"'::jsonb;
  elsif o.client_price<o.market_median*(1-(s.pricing->>'median_pct')::numeric/100) then reasons:=reasons||'"Цена ниже порога рынка"'::jsonb; end if;
 end if;
 if coalesce((s.pricing->>'margin_enabled')::boolean,true) and margin<(s.pricing->>'margin_pct')::numeric then reasons:=reasons||'"Маржа ниже порога"'::jsonb; end if;
 fingerprint:=md5(jsonb_build_array(o.title,o.description,o.scenario,o.currency,o.input,o.calculation,o.client_price,o.market_median,o.term,s.pricing)::text);
 if cardinality(o.photo_ids)>0 then fingerprint:=md5(fingerprint||o.photo_ids::text); end if;
 return jsonb_build_object('margin_pct',margin,'reasons',reasons,'fingerprint',fingerprint,'needs_approval',jsonb_array_length(reasons)>0,
  'can_send',not o.archived and o.client_price>=o.total_cost and ((o.approval='none' and jsonb_array_length(reasons)=0) or (o.approval='approved' and o.approved_fingerprint=fingerprint)));
end $$;
revoke all on function public.option_evaluation(public.request_options,public.dealer_settings) from public,anon,authenticated;
grant execute on function public.option_evaluation(public.request_options,public.dealer_settings) to service_role;

create or replace function public.crm_backend(p_actor bigint,p_action text,p jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare
 a public.app_users%rowtype; r public.crm_requests%rowtype; s public.dealer_settings%rowtype; o public.request_options%rowtype; old public.request_options%rowtype;
 f public.request_offers%rowtype; asset public.dealer_assets%rowtype;
 calc jsonb; inp jsonb; item text; n numeric; purchase numeric; rate numeric; cost numeric; price numeric; median numeric; reasons jsonb;
 evaluation jsonb; validation jsonb:='{}'; ids uuid[]; cars jsonb:='[]'; num integer; rid uuid; decision text; note text; amount integer; out jsonb;
begin
 select * into a from public.app_users where tg_id=p_actor and active;
 if not found or a.role not in ('admin','owner','manager') then raise exception 'crm_forbidden'; end if;
 insert into public.dealer_settings(company_id) values(a.company_id) on conflict do nothing;
 select * into s from public.dealer_settings where company_id=a.company_id;
 if p_action='settings.get' then return jsonb_build_object('settings',to_jsonb(s)); end if;
 if p_action='settings.save' then
  if a.role not in ('admin','owner') then raise exception 'crm_forbidden'; end if;
  select * into s from public.dealer_settings where company_id=a.company_id for update;
  if p->>'revision' is null or s.revision<>(p->>'revision')::integer then raise exception 'crm_conflict'; end if;
  if jsonb_typeof(p->'dealer')<>'object' or jsonb_typeof(p->'pricing')<>'object' or jsonb_typeof(p->'exchange')<>'object' then raise exception 'backend_bad_data'; end if;
  if length(p->'dealer'->>'name')>160 or length(p->'dealer'->>'phone')>80 or length(p->'dealer'->>'inn')>32 or length(p->'dealer'->>'address')>500 then raise exception 'backend_bad_data'; end if;
  foreach item in array array['median_pct','margin_pct'] loop n:=(p->'pricing'->>item)::numeric; if n is null or n<0 or n>100 or n='NaN'::numeric then raise exception 'backend_bad_data'; end if; end loop;
  if jsonb_typeof(p->'pricing'->'median_enabled') is distinct from 'boolean' or jsonb_typeof(p->'pricing'->'margin_enabled') is distinct from 'boolean' then raise exception 'backend_bad_data'; end if;
  if coalesce(p->'exchange'->>'mode','') not in ('percent','add','fixed') then raise exception 'backend_bad_data'; end if;
  foreach item in array array['percent','add','fixed'] loop n:=(p->'exchange'->>item)::numeric; if n is null or n<0 or n>100000 or n='NaN'::numeric then raise exception 'backend_bad_data'; end if; end loop;
  if (p->'exchange'->>'fixed')::numeric<=0 then raise exception 'backend_bad_data'; end if;
  if (p->>'valid_days')::integer not between 1 and 60 then raise exception 'backend_bad_data'; end if;
  if nullif(p->>'letterhead_id','') is not null and not exists(select 1 from public.dealer_assets where id=(p->>'letterhead_id')::uuid and company_id=a.company_id) then raise exception 'crm_not_found'; end if;
  update public.dealer_settings set dealer=p->'dealer',pricing=p->'pricing',exchange=p->'exchange',valid_days=(p->>'valid_days')::integer,letterhead_id=nullif(p->>'letterhead_id','')::uuid,revision=revision+1,updated_at=now() where company_id=a.company_id returning * into s;
  insert into public.dealer_events(company_id,actor_id,kind,data) values(a.company_id,p_actor,'settings.updated',jsonb_build_object('revision',s.revision));
  return jsonb_build_object('settings',to_jsonb(s));
 end if;
 if p_action='asset.save' then
  if a.role not in ('admin','owner') then raise exception 'crm_forbidden'; end if;
  insert into public.dealer_assets(company_id,name,content_type,data_url,created_by) values(a.company_id,p->>'name',p->>'content_type',p->>'data_url',p_actor) returning * into asset;
  insert into public.dealer_events(company_id,actor_id,kind,data) values(a.company_id,p_actor,'asset.created',jsonb_build_object('id',asset.id));
  return jsonb_build_object('asset',jsonb_build_object('id',asset.id,'name',asset.name));
 end if;
 if p_action='asset.get' then
  select * into asset from public.dealer_assets where id=(p->>'id')::uuid and company_id=a.company_id;
  if not found then raise exception 'crm_not_found'; end if;
  return jsonb_build_object('asset',jsonb_build_object('name',asset.name,'type',asset.content_type,'data',asset.data_url));
 end if;
 if p_action='offer.get' or p_action='offer.sent' then
  select * into f from public.request_offers where id=(p->>'id')::uuid and company_id=a.company_id;
  if not found then raise exception 'crm_not_found'; end if; rid:=f.request_id;
 else rid:=(p->>'request_id')::uuid; end if;
 select * into r from public.crm_requests where id=rid and company_id=a.company_id for update;
 if not found or (a.role='manager' and r.assigned_to is distinct from p_actor) then raise exception 'crm_not_found'; end if;
 select * into s from public.dealer_settings where company_id=a.company_id for share;
 if p_action in ('offer.get','offer.sent') then select * into f from public.request_offers where id=f.id for update; end if;
 if p_action='request.get' then
  select coalesce(jsonb_agg(to_jsonb(q)),'[]') into out from (select o2.*,public.option_evaluation(o2,s) as evaluation from public.request_options o2 where o2.request_id=r.id order by o2.created_at) q;
  return jsonb_build_object('options',out,'settings',to_jsonb(s),'offers',coalesce((select jsonb_agg(x) from (select id,number,created_at,sent_at from public.request_offers where request_id=r.id order by number desc limit 20 offset greatest(0,coalesce((p->>'page')::integer,0))*20) x),'[]'::jsonb),'offer_count',(select count(*) from public.request_offers where request_id=r.id));
 end if;
 if p_action='offer.get' then return jsonb_build_object('offer',to_jsonb(f)); end if;
 if r.archived_at is not null then raise exception 'backend_archived'; end if;
 if p_action='option.save' then
  if nullif(p->>'id','') is not null then select * into old from public.request_options where id=(p->>'id')::uuid and request_id=r.id for update; if not found then raise exception 'crm_not_found'; end if; if p->>'version' is null or old.version<>(p->>'version')::integer then raise exception 'crm_conflict'; end if;
  elsif (select count(*) from public.request_options where request_id=r.id)>=100 then raise exception 'backend_limit'; end if;
  if coalesce(p->>'scenario','') not in ('rf','import') or length(coalesce(trim(p->>'title'),'')) not between 1 and 200 then raise exception 'backend_bad_data'; end if;
  inp:=p->'input'; if jsonb_typeof(inp)<>'object' then raise exception 'backend_bad_data'; end if;
  if coalesce(inp->>'quote_mode','itemized') not in ('itemized','turnkey') or jsonb_typeof(coalesce(inp->'vehicle','{}'))<>'object' or length(coalesce(inp->'vehicle','{}')::text)>1600 then raise exception 'backend_bad_data'; end if;
  foreach item in array array['purchase','logistics','duty','recycling','documents','commission'] loop n:=coalesce((inp->>item)::numeric,0); if n<0 or n>100000000000 or n='NaN'::numeric then raise exception 'backend_bad_data'; end if; end loop;
  purchase:=(inp->>'purchase')::numeric; if purchase is null or purchase<=0 then raise exception 'backend_bad_data'; end if;
  if p->>'scenario'='import' then
   if coalesce(p->>'currency','') not in ('CNY','JPY','USD','EUR') then raise exception 'backend_bad_data'; end if;
   rate:=(inp->>'base_rate')::numeric;
   if rate is null or rate<=0 or rate>100000 or rate='NaN'::numeric then raise exception 'backend_bad_data'; end if;
   rate:=case s.exchange->>'mode' when 'fixed' then (s.exchange->>'fixed')::numeric when 'add' then rate+(s.exchange->>'add')::numeric else rate*(1+(s.exchange->>'percent')::numeric/100) end;
  else rate:=1; end if;
  purchase:=round(purchase*rate,2);
  cost:=round(purchase+coalesce((inp->>'logistics')::numeric,0)+coalesce((inp->>'commission')::numeric,0)+case when p->>'scenario'='import' then coalesce((inp->>'duty')::numeric,0)+coalesce((inp->>'recycling')::numeric,0)+coalesce((inp->>'documents')::numeric,0) else 0 end,2);
  if inp->>'quote_mode'='turnkey' then cost:=purchase; end if;
  price:=(p->>'client_price')::numeric; median:=nullif(p->>'market_median','')::numeric;
  if price is null or price<cost or price>100000000000 or price='NaN'::numeric then raise exception 'backend_price_below_cost'; end if;
  if median is not null and (median<=0 or median>100000000000 or median='NaN'::numeric) then raise exception 'backend_bad_data'; end if;
  calc:=jsonb_build_object('purchase_rub',purchase,'effective_rate',rate,'exchange_rule',s.exchange,'input',inp,'total_cost',cost,'calculated_at',now(),'rate_source','manual');
  if old.id is null then
   insert into public.request_options(request_id,company_id,title,description,scenario,currency,input,calculation,purchase_rub,total_cost,client_price,market_median,term,source_name,created_by)
   values(r.id,a.company_id,trim(p->>'title'),coalesce(p->>'description',''),p->>'scenario',case when p->>'scenario'='rf' then 'RUB' else p->>'currency' end,inp,calc,purchase,cost,price,median,coalesce(p->>'term',''),coalesce(p->>'source_name',''),p_actor) returning * into o;
  else
   update public.request_options set title=trim(p->>'title'),description=coalesce(p->>'description',''),scenario=p->>'scenario',currency=case when p->>'scenario'='rf' then 'RUB' else p->>'currency' end,input=inp,calculation=(old.calculation-'input'-'total_cost')||calc,purchase_rub=purchase,total_cost=cost,client_price=price,market_median=median,term=coalesce(p->>'term',''),source_name=coalesce(p->>'source_name',''),approval='none',approved_fingerprint=null,version=version+1,updated_at=now() where id=old.id returning * into o;
  end if;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(a.company_id,r.id,p_actor,'option.saved',jsonb_build_object('option_id',o.id,'price',price,'cost',cost));
  update public.crm_requests set updated_at=now() where id=r.id;
  return jsonb_build_object('option',to_jsonb(o),'evaluation',public.option_evaluation(o,s));
 end if;
 if p_action='option.archive' then
  select * into o from public.request_options where id=(p->>'id')::uuid and request_id=r.id for update;
  if not found then raise exception 'crm_not_found'; end if;
  if p->>'version' is null or o.version<>(p->>'version')::integer then raise exception 'crm_conflict'; end if;
  if jsonb_typeof(p->'archived') is distinct from 'boolean' then raise exception 'backend_bad_data'; end if;
  update public.request_options set archived=(p->>'archived')::boolean,approval='none',approved_fingerprint=null,version=version+1,updated_at=now() where id=o.id returning * into o;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(a.company_id,r.id,p_actor,'option.archived',jsonb_build_object('option_id',o.id,'archived',o.archived));
  update public.crm_requests set updated_at=now() where id=r.id;
  return jsonb_build_object('option',to_jsonb(o));
 end if;
 if p_action='option.review' then
  select * into o from public.request_options where id=(p->>'id')::uuid and request_id=r.id for update;
  if not found or o.archived then raise exception 'crm_not_found'; end if;
  if p->>'version' is null or o.version<>(p->>'version')::integer then raise exception 'crm_conflict'; end if;
  decision:=p->>'decision';note:=coalesce(p->>'note','');
  if decision not in ('requested','approved','rejected') or length(note)>2000 then raise exception 'backend_bad_data'; end if;
  if decision in ('approved','rejected') and a.role not in ('admin','owner') then raise exception 'crm_forbidden'; end if;
  evaluation:=public.option_evaluation(o,s);
  insert into public.price_decisions(company_id,request_id,option_id,actor_id,actor_name,decision,note,snapshot) values(a.company_id,r.id,o.id,p_actor,a.name,decision,note,to_jsonb(o)||jsonb_build_object('evaluation',evaluation,'pricing',s.pricing));
  update public.request_options set approval=case when decision='requested' then 'pending' else decision end,approved_fingerprint=case when decision='approved' then evaluation->>'fingerprint' else null end,version=version+1,updated_at=now() where id=o.id returning * into o;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(a.company_id,r.id,p_actor,'price.'||decision,jsonb_build_object('option_id',o.id,'price',o.client_price,'note',note));
  update public.crm_requests set updated_at=now() where id=r.id;
  return jsonb_build_object('option',to_jsonb(o),'evaluation',public.option_evaluation(o,s));
 end if;
 if p_action='offer.create' then
  if r.status not in ('search','think') then raise exception 'backend_closed'; end if;
  if jsonb_typeof(p->'option_ids')<>'array' or jsonb_array_length(p->'option_ids') not between 1 and 30 then raise exception 'backend_bad_data'; end if;
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(p->'option_ids');
  if cardinality(ids)<>(select count(distinct v) from unnest(ids) v) then raise exception 'backend_bad_data'; end if;
  foreach rid in array ids loop
   select * into o from public.request_options where id=rid and request_id=r.id;
   if not found then raise exception 'crm_not_found'; end if;
   evaluation:=public.option_evaluation(o,s);
   if not (evaluation->>'can_send')::boolean then raise exception 'backend_approval_required'; end if;
   validation:=validation||jsonb_build_object(o.id::text,evaluation->>'fingerprint');
   cars:=cars||jsonb_build_object('title',regexp_replace(o.title,'(https?://[^ ]+|[[:alnum:]_.+-]+@[[:alnum:].-]+|@[[:alnum:]_]+|[+]?[0-9][0-9 ()-]{8,}[0-9])','[контакты удалены]','gi'),'description',regexp_replace(o.description,'(https?://[^ ]+|[[:alnum:]_.+-]+@[[:alnum:].-]+|@[[:alnum:]_]+|[+]?[0-9][0-9 ()-]{8,}[0-9])','[контакты удалены]','gi'),'price',o.client_price,'photo_ids',to_jsonb(o.photo_ids),'term',regexp_replace(o.term,'(https?://[^ ]+|[[:alnum:]_.+-]+@[[:alnum:].-]+|@[[:alnum:]_]+|[+]?[0-9][0-9 ()-]{8,}[0-9])','[контакты удалены]','gi'));
  end loop;
  select coalesce(max(number),0)+1 into num from public.request_offers where request_id=r.id;
  insert into public.request_offers(company_id,request_id,number,model,validation,option_ids,actor_id,letterhead_id)
  values(a.company_id,r.id,num,jsonb_build_object('createdAt',now(),'validUntil',now()+s.valid_days*interval '1 day','client',r.client_name,'manager',a.name,'dealer',s.dealer,'cars',cars),validation,ids,p_actor,s.letterhead_id) returning * into f;
  insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(a.company_id,r.id,p_actor,'offer.created',jsonb_build_object('offer_id',f.id,'number',num));
  update public.crm_requests set updated_at=now() where id=r.id;
  return jsonb_build_object('offer',to_jsonb(f));
 end if;
 if p_action='offer.sent' then
  if f.sent_at is null then
   if (f.model->>'validUntil')::timestamptz<now() then raise exception 'backend_offer_expired'; end if;
   foreach rid in array f.option_ids loop
    select * into o from public.request_options where id=rid and request_id=r.id;
    if not found then raise exception 'backend_offer_stale'; end if;
    evaluation:=public.option_evaluation(o,s);
    if not (evaluation->>'can_send')::boolean or evaluation->>'fingerprint' is distinct from f.validation->>o.id::text then raise exception 'backend_offer_stale'; end if;
   end loop;
   if r.status not in ('search','think') then raise exception 'backend_closed'; end if;
   update public.request_offers set sent_at=now(),sent_by=p_actor where id=f.id returning * into f;
   update public.crm_requests set status='think',version=version+1,updated_at=now() where id=r.id;
   insert into public.crm_activity(company_id,request_id,actor_id,kind,data) values(a.company_id,r.id,p_actor,'offer.sent',jsonb_build_object('offer_id',f.id,'number',f.number));
  end if;
  return jsonb_build_object('offer',to_jsonb(f));
 end if;
 raise exception 'backend_bad_action';
end $$;
revoke all on function public.crm_backend(bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.crm_backend(bigint,text,jsonb) to service_role;
