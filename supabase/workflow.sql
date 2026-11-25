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
alter table public.workflow_policy add column if not exists year_slack integer not null default 0 check(year_slack between 0 and 10);
alter table public.workflow_policy add column if not exists km_slack integer not null default 0 check(km_slack between 0 and 1000000);
alter table public.workflow_policy add column if not exists budget_pct numeric not null default 0 check(budget_pct between 0 and 100);
alter table public.workflow_policy
 alter column revision set default 0,
 alter column supplier_hours set default 2,
 alter column escalation_hours set default 6,
 alter column client_days set default 2;
create or replace function public.workflow_init_policy() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into workflow_policy(company_id) values(new.id) on conflict do nothing;
 return new;
end $$;
create or replace trigger workflow_company_policy after insert on public.app_companies
 for each row execute function public.workflow_init_policy();
insert into public.workflow_policy(company_id) select id from public.app_companies on conflict do nothing;
revoke all on function public.workflow_init_policy() from public,anon,authenticated;
grant execute on function public.workflow_init_policy() to service_role;
alter table public.request_listings add column if not exists currency text not null default 'RUB' check(currency in ('RUB','CNY','JPY','USD','EUR'));
alter table public.request_listings add column if not exists phone text not null default '' check(phone='' or phone ~ '^[+]?[0-9]{10,15}$');
alter table public.request_listings add column if not exists vehicle jsonb not null default '{}';
alter table public.request_listings add column if not exists quote_mode text not null default 'itemized' check(quote_mode in ('itemized','turnkey'));
create table if not exists public.listing_calls (
 id uuid primary key, request_id uuid not null, url text not null,
 actor_id bigint not null references public.app_users(tg_id) on update cascade,
 result text not null check(result in ('fit','reject','retry')), check(result<>'retry' or next_call is not null), actual_price numeric check(actual_price>0 and actual_price<=100000000000),
 note text not null default '' check(length(note)<=1600), next_call timestamptz, created_at timestamptz not null default clock_timestamp(),
 foreign key(request_id,url) references public.request_listings(request_id,url)
);
create index if not exists listing_calls_latest on public.listing_calls(request_id,url,created_at desc);
create index if not exists listing_calls_due on public.listing_calls(next_call) where result='retry';
create table if not exists public.crm_orders (
 id uuid primary key default gen_random_uuid(), request_id uuid unique not null references public.crm_requests(id),
 snapshot jsonb not null, created_at timestamptz not null default now()
);
alter table public.listing_calls enable row level security;
alter table public.crm_orders enable row level security;
revoke all on public.listing_calls,public.crm_orders from public,anon,authenticated;
grant select,insert on public.listing_calls to service_role;
grant select,insert,update on public.crm_orders to service_role;

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

create or replace function public.workflow_market_calls() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into request_listings(request_id,url,title,purchase,currency,term,vehicle,phone,quote_mode)
 select distinct on (v->>'link') new.request_id,v->>'link',v->>'title',(v->>'purchase')::numeric,coalesce(v->>'currency','RUB'),
  coalesce(v->>'term',''),coalesce(v->'vehicle','{}'),coalesce(v->>'phone',''),coalesce(v->>'quote_mode','itemized')
 from jsonb_array_elements(new.results) v where v->>'link' ~ '^https://[^[:space:]]+$'
 on conflict(request_id,url) do nothing;
 return new;
end $$;
create or replace trigger workflow_market_calls after insert or update of results on public.search_sources
 for each row when (new.source='market' and new.state='ready') execute function public.workflow_market_calls();
-- Materialize previously received listings when installing on an existing dealer.
update public.search_sources s set results=s.results where s.source='market' and s.state='ready' and exists(
 select 1 from jsonb_array_elements(s.results) v where v->>'link' ~ '^https://[^[:space:]]+$'
 and not exists(select 1 from public.request_listings l where l.request_id=s.request_id and l.url=v->>'link'));
revoke all on function public.workflow_market_calls() from public,anon,authenticated;
grant execute on function public.workflow_market_calls() to service_role;

alter table public.request_offers add column if not exists internal_quotes jsonb not null default '{}';
create or replace function public.workflow_snapshot_quotes() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 select coalesce(jsonb_object_agg(o.id,jsonb_build_object('source',o.source_name,'currency',o.currency,
  'cost',o.total_cost,'quote',o.input,'calculation',o.calculation)),'{}') into new.internal_quotes
 from request_options o where o.request_id=new.request_id and o.id=any(new.option_ids);
 return new;
end $$;
create or replace trigger workflow_snapshot_quotes before insert on public.request_offers for each row execute function public.workflow_snapshot_quotes();
revoke all on function public.workflow_snapshot_quotes() from public,anon,authenticated;
grant execute on function public.workflow_snapshot_quotes() to service_role;
create or replace function public.workflow_record_order() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into crm_orders(request_id,snapshot,created_at)
 select r.id,jsonb_build_object('client',r.client_name,'phone',r.phone,'city',r.city,'manager',u.name,'choice',new.data->'choice',
  'car',car)||coalesce(f.internal_quotes->(new.data->'choice'->>'option'),'{}'::jsonb),new.created_at
 from crm_requests r left join app_users u on u.tg_id=r.assigned_to
 join request_offers f on f.id=(new.data->'choice'->>'offer')::uuid and f.request_id=r.id
 cross join lateral generate_subscripts(f.option_ids,1) n
 cross join lateral (select f.model->'cars'->(n-1) as car) snap
 join request_options o on o.id=f.option_ids[n] and o.request_id=r.id
 where r.id=new.request_id and o.id=(new.data->'choice'->>'option')::uuid
 on conflict(request_id) do update set snapshot=excluded.snapshot where not (crm_orders.snapshot?'choice');
 if not exists(select 1 from crm_orders where request_id=new.request_id) then raise exception 'crm_conflict'; end if;
 return new;
end $$;
create or replace trigger workflow_record_order after insert on public.crm_activity for each row when(new.kind='car.chosen') execute function public.workflow_record_order();
revoke all on function public.workflow_record_order() from public,anon,authenticated;
grant execute on function public.workflow_record_order() to service_role;
-- Reconstruct historical choices only from their immutable, sent offer.
insert into public.crm_orders(request_id,snapshot,created_at)
select distinct on (r.id) r.id,jsonb_build_object('client',f.model->>'client','choice',a.data->'choice','car',f.model->'cars'->(n-1)),a.created_at
from public.crm_activity a join public.crm_requests r on r.id=a.request_id
join public.request_offers f on f.id=(a.data->'choice'->>'offer')::uuid and f.request_id=r.id
cross join lateral generate_subscripts(f.option_ids,1) n where a.kind='car.chosen' and f.option_ids[n]::text=a.data->'choice'->>'option'
order by r.id,a.created_at desc on conflict(request_id) do nothing;

-- Requests closed directly from a client card still need an order and an explicit vehicle choice.
create or replace function public.workflow_open_order() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into crm_orders(request_id,snapshot) values(new.id,jsonb_build_object('client',new.client_name,'phone',new.phone,'city',new.city,
  'manager',(select name from app_users where tg_id=new.assigned_to))) on conflict(request_id) do nothing;
 return new;
end $$;
create or replace trigger workflow_open_order after insert or update of status on public.crm_requests
 for each row when(new.status='won') execute function public.workflow_open_order();
revoke all on function public.workflow_open_order() from public,anon,authenticated;
grant execute on function public.workflow_open_order() to service_role;
insert into public.crm_orders(request_id,snapshot,created_at)
 select r.id,jsonb_build_object('client',r.client_name,'phone',r.phone,'city',r.city,'manager',u.name),coalesce(
 (select max(c.created_at) from public.crm_activity c where c.request_id=r.id and c.data->>'status'='won'),r.updated_at)
 from public.crm_requests r left join public.app_users u on u.tg_id=r.assigned_to where r.status='won' on conflict(request_id) do nothing;

create or replace function public.workflow_start_sources() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 insert into search_sources(request_id,source) values(new.request_id,'stock'),(new.request_id,'market') on conflict do nothing;
 return new;
end $$;
create or replace trigger workflow_start_sources after insert on public.bot_request_specs
 for each row execute function public.workflow_start_sources();

alter table public.supplier_terms add column if not exists routing_enabled boolean not null default true;
alter table public.bot_request_specs add column if not exists filters jsonb not null default '{}';
create or replace function public.workflow_filters(filters jsonb) returns jsonb language plpgsql immutable as $$
declare k text; v text; f jsonb:='{}'; n numeric;
begin
 if jsonb_typeof(filters) is distinct from 'object' then raise exception 'backend_bad_data'; end if;
 for k,v in select key,value from jsonb_each_text(filters) loop
  if nullif(trim(v),'') is null then continue; end if;
  case k
   when 'price_from' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 0 and 100000000000 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'price_to' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 0 and 100000000000 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'year_from' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 1900 and 2100 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'year_to' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 1900 and 2100 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'mileage_from' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 0 and 20000000 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'mileage_to' then if v !~ '^[0-9]{1,12}$' or v::numeric not between 0 and 20000000 then raise exception 'backend_bad_data';end if;f:=f||jsonb_build_object(k,v::bigint);
   when 'color' then if v not in ('Белый','Чёрный','Серый','Серебристый','Синий','Красный','Зелёный','Коричневый','Бежевый','Другой') then raise exception 'backend_bad_data'; end if; f:=f||jsonb_build_object(k,v);
   when 'body' then if v not in ('Седан','Хэтчбек','Универсал','Лифтбек','Внедорожник','Кроссовер','Купе','Кабриолет','Минивэн','Пикап','Фургон') then raise exception 'backend_bad_data'; end if; f:=f||jsonb_build_object(k,v);
   when 'gearbox' then if v not in ('Автомат','Механика','Робот','Вариатор') then raise exception 'backend_bad_data'; end if; f:=f||jsonb_build_object(k,v);
   when 'fuel' then if v not in ('Бензин','Дизель','Гибрид','Электро','Газ') then raise exception 'backend_bad_data'; end if; f:=f||jsonb_build_object(k,v);
   when 'drive' then if v not in ('Передний','Задний','Полный') then raise exception 'backend_bad_data'; end if; f:=f||jsonb_build_object(k,v);
   else raise exception 'backend_bad_data'; end case;
 end loop;
 foreach k in array array['price','year','mileage'] loop
  if (f->>(k||'_from'))::numeric>(f->>(k||'_to'))::numeric then raise exception 'backend_bad_data'; end if;
 end loop;
 return f;
end $$;
revoke all on function public.workflow_filters(jsonb) from public,anon,authenticated;
grant execute on function public.workflow_filters(jsonb) to service_role;
create or replace function public.workflow_brand(value text) returns text language sql immutable strict as $$
 select case lower(trim(value)) when 'тойота' then 'toyota' when 'тоёта' then 'toyota' when 'тоета' then 'toyota'
 when 'лексус' then 'lexus' when 'ниссан' then 'nissan' when 'мазда' then 'mazda' when 'бмв' then 'bmw' when 'киа' then 'kia'
 when 'хонда' then 'honda' when 'ауди' then 'audi' when 'хендай' then 'hyundai' when 'хёндэ' then 'hyundai'
 when 'фольксваген' then 'volkswagen' when 'мерседес' then 'mercedes-benz' else lower(trim(value)) end
$$;
create or replace function public.workflow_route_brand(brand text,model text) returns text language sql stable security invoker set search_path=public,pg_temp as $$
 select workflow_brand(coalesce(nullif(trim(brand),''),(select b from bot_supplier_profiles sp cross join unnest(sp.brands) b
 where sp.active and (lower(trim(model))=lower(b) or starts_with(lower(trim(model)),lower(b)||' ')) order by length(b) desc limit 1),split_part(trim(model),' ',1)))
$$;
create or replace function public.workflow_routes(company uuid,brand text) returns table(supplier bigint,key text,name text)
 language sql stable security invoker set search_path=public,pg_temp as $$
 select u.tg_id,md5(company::text||':'||u.tg_id),case when company=u.company_id then u.name else 'Поставщик '||right(md5(u.tg_id::text),6) end
 from app_users u join bot_supplier_profiles s on s.user_id=u.tg_id left join supplier_terms st on st.company_id=company and st.supplier_id=u.tg_id
 where u.role='supplier' and u.active and s.active and coalesce(st.routing_enabled,true) and exists(select 1 from unnest(s.brands) b where workflow_brand(b)=workflow_brand(brand))
 order by 3,2
$$;
create or replace function public.workflow_bot_routes(p_company uuid,p_brand text) returns jsonb language sql stable security invoker set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object('user_id',supplier)),'[]') from workflow_routes(p_company,p_brand)
$$;
create or replace function public.workflow_delivery_route(p_thread uuid) returns boolean language sql stable security invoker set search_path=public,pg_temp as $$
 select exists(select 1 from bot_threads t join bot_request_specs s on s.request_id=t.request_id cross join lateral workflow_routes(t.company_id,s.brand) w where t.id=p_thread and t.supplier_id=w.supplier)
$$;
revoke all on function public.workflow_bot_routes(uuid,text),public.workflow_delivery_route(uuid) from public,anon,authenticated;
grant execute on function public.workflow_bot_routes(uuid,text),public.workflow_delivery_route(uuid) to service_role;
revoke all on function public.workflow_routes(uuid,text),public.workflow_brand(text),public.workflow_route_brand(text,text) from public,anon,authenticated;
grant execute on function public.workflow_routes(uuid,text),public.workflow_brand(text),public.workflow_route_brand(text,text) to service_role;

create or replace function public.workflow_dispatch_selected(p_actor bigint,p_request uuid,p_brand text,p_color text,p_trim text,p_recipients jsonb,p_filters jsonb)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare r crm_requests; t bot_threads; supplier bigint; mid uuid; body text; n integer:=0; filter_data jsonb; previous_filters jsonb; brand text:=lower(trim(p_brand)); v text;
begin
 perform crm_request_detail(p_actor,p_request);
 select * into strict r from crm_requests where id=p_request for update;
 if r.archived_at is not null or r.status not in ('search','think') then raise exception 'backend_closed'; end if;
 brand:=workflow_route_brand(p_brand,r.model);
 if p_recipients is not null and jsonb_typeof(p_recipients)<>'array' then raise exception 'backend_bad_data'; end if;
 if nullif(brand,'') is null or length(brand)>80 or length(p_trim)>160 or length(p_color)>100 then raise exception 'backend_bad_data'; end if;
 -- Only the public vehicle fields ever go into the supplier request. Reject contact-like input.
 foreach v in array array[brand,r.model,r.generation,r.years,p_color,p_trim] loop
  if v ~* '(@|https?://|www\.|t\.me/|[[:cntrl:]]|[+]?[0-9][0-9 ()-]{8,}[0-9])' or
    length(trim(r.client_name))>=3 and strpos(lower(v),lower(trim(r.client_name)))>0 then raise exception 'backend_bad_data'; end if;
 end loop;
 select filters into previous_filters from bot_request_specs where request_id=r.id;
 filter_data:=workflow_filters(coalesce(p_filters,previous_filters,'{}'));
 insert into bot_request_specs(request_id,company_id,brand,model_at_selection,color,trim,filters)
 values(r.id,r.company_id,brand,r.model,p_color,p_trim,filter_data)
 on conflict(request_id) do update set brand=excluded.brand,model_at_selection=excluded.model_at_selection,color=excluded.color,trim=excluded.trim,filters=excluded.filters;
 if previous_filters is not null and previous_filters<>filter_data then
  update search_sources set state='pending',attempt=attempt+1 where request_id=r.id;
 end if;
 for supplier in select w.supplier from workflow_routes(r.company_id,brand) w where p_recipients is null or p_recipients ? w.key loop
  insert into bot_threads(company_id,request_id,supplier_id) values(r.company_id,r.id,supplier)
  on conflict(request_id,supplier_id) do nothing returning * into t;
  if not found then continue; end if;
  body:=concat_ws(E'\n','Запрос № '||t.code,'Марка: '||brand,'Модель: '||r.model,
   'Поколение: '||nullif(r.generation,''),'Годы: '||nullif(r.years,''),
   'Пробег до, км: '||case when filter_data->>'mileage_to' is null then r.mileage::text end,'Цвет: '||coalesce(nullif(filter_data->>'color',''),nullif(p_color,'')),
   'Комплектация: '||nullif(p_trim,''),
   'Кузов: '||(filter_data->>'body'),'Коробка: '||(filter_data->>'gearbox'),'Топливо: '||(filter_data->>'fuel'),'Привод: '||(filter_data->>'drive'),
   'Год от: '||(filter_data->>'year_from'),'Год до: '||(filter_data->>'year_to'),'Пробег от, км: '||(filter_data->>'mileage_from'),'Пробег до, км: '||(filter_data->>'mileage_to'),
   E'\n'||(select operations->>'supplier_instruction' from app_companies where id=r.company_id));
  insert into bot_messages(thread_id,actor_id,sanitized_text) values(t.id,p_actor,body) returning id into mid;
  insert into bot_outbox(chat_id,actor_id,thread_id,message_id,dedupe_key,body) values(supplier,p_actor,t.id,mid,'dispatch:'||t.id,
   jsonb_build_object('text',body,'reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Ответить по машине','style','primary','callback_data','thread:'||t.id))))));
  n:=n+1;
 end loop;
 return n;
end $$;

revoke all on function public.workflow_dispatch_selected(bigint,uuid,text,text,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.workflow_dispatch_selected(bigint,uuid,text,text,text,jsonb,jsonb) to service_role;
create or replace function public.workflow_dispatch(p_actor bigint,p_request uuid,p_brand text,p_color text,p_trim text)
returns integer language sql security invoker set search_path=public,pg_temp as $$
 select workflow_dispatch_selected(p_actor,p_request,p_brand,p_color,p_trim,null,null)
$$;
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
 n:=workflow_dispatch_selected(p_actor,(r->>'id')::uuid,p_search->>'brand',coalesce(p_search->>'color',''),coalesce(p_search->>'trim',''),p_search->'recipients',p_search->'filters');
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
 if m.id is null and p_jpeg is not null and coalesce(p_text,'')='' then
  if inbound?'reply_to_message' then
   select bm.* into m from bot_messages bm where bm.thread_id=t.id and bm.actor_id=p_actor and bm.id in
    (select ref.message_id from supplier_input_refs ref where inbound->'reply_to_message'->'from'->>'id'=p_actor::text and ref.actor_id=p_actor and ref.telegram_id=(inbound->'reply_to_message'->>'message_id')::bigint
     union all select substring(b.body#>>'{reply_markup,inline_keyboard,0,0,callback_data}' from 8)::uuid from bot_outbox b
      where b.chat_id=p_actor and b.thread_id=t.id and b.telegram_message_id=(inbound->'reply_to_message'->>'message_id')::bigint and b.body#>>'{reply_markup,inline_keyboard,0,0,callback_data}' ~ '^addpic:[0-9a-f-]{36}$')
    limit 1 for update;
  else
   select bm.* into m from bot_context c join bot_messages bm on bm.id::text=c.dialogue->0->>'message_id'
    where c.user_id=p_actor and c.thread_id=t.id and c.dialogue->0->>'role'='attach_photos' and bm.thread_id=t.id and bm.actor_id=p_actor for update of bm;
  end if;
 end if;
 if nullif(p_text,'') is not null then update bot_context set dialogue='[]' where user_id=p_actor and dialogue->0->>'role'='attach_photos'; end if;
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
 if manager is not null and not (select (operations->'muted_events') ? 'reply' from app_companies where id=t.company_id) then
  insert into bot_outbox(chat_id,actor_id,thread_id,request_id,dedupe_key,body) values(manager,p_actor,t.id,t.request_id,'received:'||m.id,
   jsonb_build_object('text','Ответ поставщика по запросу '||t.code||E'\n'||coalesce(nullif(m.sanitized_text,''),'Получены фотографии. Откройте подбор в CRM.'),
    'reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Открыть диалог','callback_data','thread:'||t.id)))))) on conflict(dedupe_key) do nothing;
 end if;
 return jsonb_build_object('id',m.id,'thread_id',t.id);
end $$;

create table if not exists public.option_uploads (
 id uuid primary key, request_id uuid not null references public.crm_requests(id),
 jpeg text not null check(length(jpeg) between 8 and 350000)
);
create index if not exists option_uploads_request on public.option_uploads(request_id);
create table if not exists public.option_photo_writes (
 actor_id bigint not null, token uuid not null, request_id uuid not null references public.crm_requests(id),
 option_id uuid not null references public.request_options(id), fingerprint text not null, primary key(actor_id,token)
);
alter table public.option_uploads enable row level security;
alter table public.option_photo_writes enable row level security;
revoke all on public.option_uploads,public.option_photo_writes from public,anon,authenticated;
grant select,insert on public.option_uploads,public.option_photo_writes to service_role;
create or replace function public.crm_workflow(p_actor bigint,p_action text,p jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare a app_users; r crm_requests; t bot_threads; m bot_messages; u app_users; terms supplier_terms;
 photos uuid[]; photo uuid; result jsonb; k text; fees jsonb; brands text[]; body text; dest bigint; rev int; oldrev int; previous_choice jsonb;
begin
 select * into a from app_users where tg_id=p_actor and active and role in ('manager','owner','admin');
 if not found then raise exception 'crm_forbidden'; end if;
 if p_action='recipients' then
  if p->>'request_id' is not null then perform crm_request_detail(p_actor,(p->>'request_id')::uuid); end if;
  k:=workflow_route_brand(p->>'brand',p->>'model');
  return jsonb_build_object('brand',k,'recipients',coalesce((select jsonb_agg(jsonb_build_object('key',w.key,'name',w.name) order by w.name,w.key)
   from workflow_routes(a.company_id,k) w where not exists(select 1 from bot_threads t2 where t2.request_id=(p->>'request_id')::uuid and t2.supplier_id=w.supplier)),'[]'));
 end if;
 if p_action in ('network','terms.save','policy.save') then
  if a.role='manager' then raise exception 'crm_forbidden'; end if;
  if p_action='network' then
   return jsonb_build_object('schema_version',2,'suppliers',coalesce((select jsonb_agg(x order by x.name) from (
    select case when u1.company_id=a.company_id then u1.tg_id::text else md5(a.company_id::text||':'||u1.tg_id) end as id, case when u1.company_id=a.company_id then u1.name else 'Поставщик '||right(md5(u1.tg_id::text),6) end as name,
     u1.company_id=a.company_id as owned, p1.brands,coalesce(p1.active,false) as enabled,u1.active,
     coalesce(s.revision,0) as revision,coalesce(s.currency,'RUB') as currency,coalesce(s.fees,'{}') as fees,coalesce(s.routing_enabled,true) as routing_enabled
    from app_users u1 left join bot_supplier_profiles p1 on p1.user_id=u1.tg_id
    left join supplier_terms s on s.company_id=a.company_id and s.supplier_id=u1.tg_id
    where u1.role='supplier' and (u1.company_id=a.company_id or u1.active and p1.active)) x),'[]'),
    'policy',(select to_jsonb(w) from workflow_policy w where company_id=a.company_id));
  end if;
  perform pg_advisory_xact_lock(hashtextextended(a.company_id::text||p_action||coalesce(p->>'id',''),0));
  if p_action='policy.save' then
   update workflow_policy set revision=revision+1, supplier_hours=(p->>'supplier_hours')::int,
    escalation_hours=(p->>'escalation_hours')::int, client_days=(p->>'client_days')::int,
    year_slack=coalesce((p->>'year_slack')::integer,year_slack), km_slack=coalesce((p->>'km_slack')::integer,km_slack),
    budget_pct=coalesce((p->>'budget_pct')::numeric,budget_pct)
   where company_id=a.company_id and revision=(p->>'revision')::int;
   if not found then raise exception 'crm_conflict'; end if;
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
  if p?'routing_enabled' then update supplier_terms set routing_enabled=(p->>'routing_enabled')::boolean where supplier_id=u.tg_id and company_id=a.company_id; end if;
  return '{"ok":true}';
 end if;
 perform crm_request_detail(p_actor,(p->>'request_id')::uuid);
 select * into strict r from crm_requests where id=(p->>'request_id')::uuid for update;
 if p_action='inbox' then
  return jsonb_build_object(
   'lot_media',true,'loss_reasons',(select operations->'loss_reasons' from app_companies where id=r.company_id),
   'tolerances',(select jsonb_build_object('years',year_slack,'km',km_slack,'pct',budget_pct) from workflow_policy where company_id=r.company_id),
   'sent_cars',coalesce((select jsonb_agg(jsonb_build_object('offer',f.id,'number',f.number,'option',f.option_ids[n],'title',f.model->'cars'->(n-1)->>'title','price',f.model->'cars'->(n-1)->'price') order by f.number desc,n)
     from request_offers f cross join lateral generate_subscripts(f.option_ids,1) n where f.request_id=r.id and f.sent_at is not null),'[]'),
   'choice',(select data->'choice' from crm_activity where request_id=r.id and kind='car.chosen' order by created_at desc,id desc limit 1),
   'spec',(select to_jsonb(b)-'company_id' from bot_request_specs b where b.request_id=r.id),
   'order',(select to_jsonb(o)-'request_id' from crm_orders o where o.request_id=r.id),
   'listings',coalesce((select jsonb_agg((to_jsonb(l)-'request_id'-'url')||jsonb_build_object('link',l.url,'calls',
    coalesce((select jsonb_agg((to_jsonb(c)-'request_id'-'url'-'actor_id')||jsonb_build_object('actor',au.name) order by c.created_at desc,c.id)
    from listing_calls c left join app_users au on au.tg_id=c.actor_id where c.request_id=l.request_id and c.url=l.url),'[]'::jsonb)) order by l.title,l.url)
    from request_listings l where l.request_id=r.id),'[]'),
   'sources',coalesce((select jsonb_agg((to_jsonb(s)-'request_id') || case when (co.operations->'active_sources') ? s.source then '{}'::jsonb else '{"state":"disabled"}'::jsonb end) from search_sources s join app_companies co on co.id=r.company_id where s.request_id=r.id),'[]'),
   'threads',coalesce((select jsonb_agg(jsonb_build_object('id',th.id,'code',th.code,
    'name',case when su.company_id=a.company_id then su.name else 'Поставщик '||right(md5(su.tg_id::text),6) end,
    'terms',to_jsonb(tr)-'company_id'-'supplier_id',
    'delivery',(select b.state from bot_outbox b where b.thread_id=th.id and b.chat_id=th.supplier_id order by created_at,id limit 1),
    'messages',coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'incoming',z.actor_id=th.supplier_id,'text',z.sanitized_text,
     'parsed',z.parsed,'at',z.created_at,'option_id',z.option_id,
     'delivery',(select b.state from bot_outbox b where b.message_id=z.id order by b.created_at desc,b.id limit 1),
     'photos',coalesce((select jsonb_agg(f.id order by f.job_id) from supplier_photos f where f.message_id=z.id),'[]')) order by z.created_at,z.id)
     from bot_messages z where z.thread_id=th.id),'[]')) order by th.code)
    from bot_threads th join app_users su on su.tg_id=th.supplier_id left join supplier_terms tr on tr.supplier_id=su.tg_id and tr.company_id=r.company_id
    where th.request_id=r.id),'[]'));
 end if;
 if p_action='choose_car' then
  select jsonb_build_object('offer',f.id,'option',f.option_ids[n],'number',f.number,'title',f.model->'cars'->(n-1)->>'title','price',f.model->'cars'->(n-1)->'price')
    into result from request_offers f cross join lateral generate_subscripts(f.option_ids,1) n
    where f.id=(p->>'offer')::uuid and f.request_id=r.id and f.sent_at is not null and f.option_ids[n]=(p->>'option')::uuid;
  if not found then raise exception 'crm_bad_data'; end if;
  select data->'choice' into previous_choice from crm_activity where request_id=r.id and actor_id=p_actor and kind='car.chosen' and data->>'token'=p->>'token';
  if found then
   if previous_choice is distinct from result then raise exception 'crm_conflict'; end if;
  elsif r.archived_at is not null or (r.status<>'think' and not (r.status='won' and exists(
    select 1 from crm_orders where request_id=r.id and not(snapshot?'choice')))) or exists(select 1 from crm_orders where request_id=r.id and snapshot?'choice') then raise exception 'backend_closed'; end if;
  perform crm_log_contact(p_actor,r.id,(p->>'version')::integer,(p->>'token')::uuid,'connected',coalesce(p->>'note',''),'{"status":"won","next_contact_at":null}');
  if previous_choice is null then
   insert into crm_activity(company_id,request_id,actor_id,kind,data) values(r.company_id,r.id,p_actor,'car.chosen',jsonb_build_object('token',p->>'token','choice',result));
  end if;
  return jsonb_build_object('choice',result);
 end if;
 if p_action='photo' then
  select jsonb_build_object('data','data:image/jpeg;base64,'||f.jpeg) into result from supplier_photos f
   join bot_messages m1 on m1.id=f.message_id join bot_threads t1 on t1.id=m1.thread_id where f.id=(p->>'id')::uuid and t1.request_id=r.id;
  if not found then select jsonb_build_object('data','data:image/jpeg;base64,'||f.jpeg) into result from option_uploads f where f.id=(p->>'id')::uuid and f.request_id=r.id; end if;
  if not found then raise exception 'crm_not_found'; end if;
  return result;
 end if;
 if r.archived_at is not null or r.status not in ('search','think') then raise exception 'backend_closed'; end if;
 if p_action='dispatch' then return jsonb_build_object('queued',workflow_dispatch_selected(p_actor,r.id,p->>'brand',coalesce(p->>'color',''),coalesce(p->>'trim',''),p->'recipients',p->'filters')); end if;
 if p_action='listing.save' then
  insert into request_listings(request_id,url,title,purchase,term,currency,vehicle,phone,quote_mode)
   values(r.id,p->>'url',trim(p->>'title'),nullif(p->>'purchase','')::numeric,coalesce(p->>'term',''),
    coalesce(p->>'currency','RUB'),coalesce(p->'vehicle','{}'),coalesce(p->>'phone',''),coalesce(p->>'quote_mode','itemized'))
   on conflict(request_id,url) do update set title=excluded.title,purchase=excluded.purchase,term=excluded.term,currency=excluded.currency,
    vehicle=case when p?'vehicle' then excluded.vehicle else request_listings.vehicle end,
    phone=case when p?'phone' then excluded.phone else request_listings.phone end,quote_mode=case when p?'quote_mode' then excluded.quote_mode else request_listings.quote_mode end;
  return '{"ok":true}';
 end if;
 if p_action='listing.call' then
  select to_jsonb(c) into result from listing_calls c where c.id=(p->>'token')::uuid;
  if found then
   if result->>'request_id'<>r.id::text or result->>'url'<>p->>'url' or result->>'actor_id'<>p_actor::text
    or result->>'result' is distinct from p->>'result' or result->>'note' is distinct from coalesce(p->>'note','')
    or (result->>'actual_price')::numeric is distinct from nullif(p->>'actual_price','')::numeric
    or (result->>'next_call')::timestamptz is distinct from nullif(p->>'next_call','')::timestamptz then raise exception 'crm_conflict'; end if;
   return '{"ok":true}';
  end if;
  if (select id::text from listing_calls where request_id=r.id and url=p->>'url' order by created_at desc,id limit 1) is distinct from p->>'previous' then raise exception 'crm_conflict'; end if;
  insert into listing_calls(id,request_id,url,actor_id,result,actual_price,note,next_call)
  values((p->>'token')::uuid,r.id,p->>'url',p_actor,p->>'result',nullif(p->>'actual_price','')::numeric,coalesce(p->>'note',''),nullif(p->>'next_call','')::timestamptz);
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
 if p_action='option.withPhotos' then
  declare upload jsonb; old_write option_photo_writes; supplier_ids uuid[]; option_id uuid; signature text:=md5(p::text); raw bytea;
  begin
   if p->>'token' is null or jsonb_typeof(p->'photos') is distinct from 'array' or jsonb_typeof(p->'uploads') is distinct from 'array'
    or jsonb_array_length(p->'photos')>10 or jsonb_array_length(p->'uploads')>10 then raise exception 'backend_bad_data'; end if;
   select * into old_write from option_photo_writes where actor_id=p_actor and token=(p->>'token')::uuid;
   if found then
    if old_write.fingerprint<>signature then raise exception 'crm_conflict'; end if;
    return jsonb_build_object('id',old_write.option_id);
   end if;
   select array(select value::uuid from jsonb_array_elements_text(p->'photos')) into photos;
   if cardinality(photos)<>(select count(distinct pid) from unnest(photos) pid) then raise exception 'backend_bad_data'; end if;
   for upload in select value from jsonb_array_elements(p->'uploads') loop
    if not ((upload->>'id')::uuid=any(photos)) or length(upload->>'jpeg') not between 8 and 350000 then raise exception 'backend_bad_data'; end if;
    raw:=decode(upload->>'jpeg','base64');
    if substring(raw from 1 for 3)<>decode('ffd8ff','hex') or substring(raw from greatest(length(raw)-1,1))<>decode('ffd9','hex') then raise exception 'backend_bad_data'; end if;
    insert into option_uploads values((upload->>'id')::uuid,r.id,upload->>'jpeg') on conflict(id) do nothing;
    if not exists(select 1 from option_uploads f where f.id=(upload->>'id')::uuid and f.request_id=r.id and f.jpeg=upload->>'jpeg') then raise exception 'crm_conflict'; end if;
   end loop;
   select array(select x from unnest(photos) x where not exists(select 1 from option_uploads f where f.id=x and f.request_id=r.id)) into supplier_ids;
   if p->>'message_id' is not null then
    result:=crm_workflow(p_actor,'option.fromReply',(p-'uploads')||jsonb_build_object('photos',to_jsonb(supplier_ids)));
    option_id:=(result->>'id')::uuid;
   else
    if cardinality(supplier_ids)>0 then raise exception 'crm_not_found'; end if;
    result:=crm_backend(p_actor,'option.save',(p->'option')||jsonb_build_object('request_id',r.id));
    option_id:=(result->'option'->>'id')::uuid;
   end if;
   update request_options set photo_ids=photos where id=option_id and request_id=r.id;
   insert into option_photo_writes values(p_actor,(p->>'token')::uuid,r.id,option_id,signature);
   return jsonb_build_object('id',option_id);
  end;
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

-- Invalidate leases when a salon changes sources. Existing comparison and call records remain accessible.
create or replace function public.workflow_refresh_sources() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 update search_sources s set attempt=s.attempt+1, state='pending', claimed_at=null
 from crm_requests r where r.id=s.request_id and r.company_id=new.id and r.archived_at is null and r.status in ('search','think')
 and ((old.operations->'active_sources') ? s.source) is distinct from ((new.operations->'active_sources') ? s.source);
 return new;
end $$;
create or replace trigger workflow_source_policy after update of operations on public.app_companies
 for each row when ((old.operations->'active_sources') is distinct from (new.operations->'active_sources')) execute function public.workflow_refresh_sources();
revoke all on function public.workflow_refresh_sources() from public,anon,authenticated;
grant execute on function public.workflow_refresh_sources() to service_role;
create or replace function public.workflow_claim_sources() returns setof jsonb language sql security invoker set search_path=public,pg_temp as $$
 with todo as (select s.request_id,s.source from search_sources s join crm_requests r on r.id=s.request_id
 join app_companies co on co.id=r.company_id and (co.operations->'active_sources') ? s.source
 where r.archived_at is null and r.status in ('search','think') and (state='pending' or state='running' and claimed_at<now()-interval '3 minutes')
 order by s.claimed_at nulls first,s.request_id,s.source limit 6 for update of s skip locked),
 claimed as (update search_sources s set state='running',claimed_at=now(),attempt=attempt+1 from todo
 where (s.request_id,s.source)=(todo.request_id,todo.source) returning s.*)
 select jsonb_build_object('request_id',c.request_id,'source',c.source,'attempt',c.attempt,'company',r.company_id,'model',r.model,'filters',coalesce((select filters from bot_request_specs where request_id=r.id),'{}'::jsonb))
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
   new.sent_at+make_interval(days=>(select client_days from workflow_policy where company_id=new.company_id)) end where id=new.request_id;
 end if;
 return new;
end $$;
create or replace trigger workflow_offer_due after update of sent_at on public.request_offers for each row execute function public.workflow_contact_due();

create or replace view public.workflow_due with (security_invoker=true) as
 with waiting as (
 select th.id thread_id,r.id request_id,r.company_id,th.supplier_id,r.assigned_to,th.code,
  first_send.delivered_at, pol.supplier_hours,pol.escalation_hours
 from bot_threads th join crm_requests r on r.id=th.request_id join bot_supplier_profiles sp on sp.user_id=th.supplier_id and sp.active
 join app_users su on su.tg_id=th.supplier_id and su.active and su.role='supplier'
 join workflow_policy pol on pol.company_id=r.company_id
 cross join lateral (select min(b.delivered_at) delivered_at from bot_outbox b where b.thread_id=th.id and b.chat_id=th.supplier_id and b.reminder is null and b.state='sent') first_send
 where first_send.delivered_at is not null and r.archived_at is null and r.status in ('search','think')
 and not exists(select 1 from bot_messages m where m.thread_id=th.id and m.actor_id=th.supplier_id)
 ), due as (
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
 and not exists(select 1 from crm_activity c where c.request_id=r.id and c.kind='contact' and c.data->>'result'='connected' and c.created_at>f.sent_at and (c.data->'submitted_data'->>'next_contact_at' is null or r.next_contact_at<=c.created_at))
 union all
 select 'contact:'||r.id||':'||r.assigned_to||':'||extract(epoch from r.next_contact_at),'contact',r.assigned_to,r.assigned_to,null::uuid,r.id,r.company_id,
  'Пора связаться с клиентом по заявке '||r.model||'.'
 from crm_requests r where r.archived_at is null and r.status in ('search','think') and r.assigned_to is not null and r.next_contact_at<=now()
 and not (r.status='think' and exists(select 1 from request_offers f where f.request_id=r.id and f.sent_at is not null))
 and not exists(select 1 from crm_activity c where c.request_id=r.id and c.kind='contact' and c.created_at>=r.next_contact_at)
 union all
 select 'listing:'||c.id||':'||r.assigned_to,'listing',r.assigned_to,r.assigned_to,null::uuid,r.id,r.company_id,
  'Пора перезвонить продавцу: '||l.title||'. Откройте обзвон заявки '||r.model||'.'
 from listing_calls c join request_listings l on (l.request_id,l.url)=(c.request_id,c.url)
 join crm_requests r on r.id=c.request_id join app_users u on u.tg_id=r.assigned_to and u.active
 where r.archived_at is null and r.status in ('search','think') and c.next_call<=now() and c.result='retry'
 and c.id=(select last.id from listing_calls last where last.request_id=c.request_id and last.url=c.url order by last.created_at desc,last.id limit 1)
 ) select d.* from due d join app_companies c on c.id=d.company_id where not ((c.operations->'muted_events') ? d.kind);
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
