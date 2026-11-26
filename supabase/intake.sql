-- Apply after workflow.sql. One editable draft per authorized employee.
create table if not exists public.bot_intakes (
 user_id bigint primary key references public.app_users(tg_id) on update cascade on delete cascade,
 company_id uuid not null references public.app_companies(id), revision uuid not null unique,
 fields jsonb not null, source_text text not null, ready boolean not null, updated_at timestamptz not null default now()
);
alter table public.bot_intakes enable row level security;
revoke all on public.bot_intakes from public,anon,authenticated;
grant select,insert,update,delete on public.bot_intakes to service_role;

alter table public.bot_intakes add column if not exists routing jsonb not null default '{}';
create or replace function public.bot_intake(p_actor bigint,p_job bigint,p_action text,p jsonb)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare a app_users; d bot_intakes; f jsonb; result jsonb; rid uuid; rev uuid:=gen_random_uuid(); body jsonb; msg text; route jsonb; choices jsonb; selected jsonb; keys jsonb; brand text; idx integer; pg integer; buttons jsonb; rec record;
begin
 select * into strict a from app_users where tg_id=p_actor and active and role in ('manager','owner','admin') for share;
 perform pg_advisory_xact_lock(p_actor);
 if not exists(select 1 from bot_jobs where id=p_job and actor_id=p_actor) then raise exception 'crm_forbidden'; end if;
 if exists(select 1 from bot_outbox where dedupe_key='intake:'||p_job) then return; end if;
 select * into d from bot_intakes where user_id=p_actor and company_id=a.company_id for update;
 if coalesce(p->>'previous','')<>coalesce(d.revision::text,'') then
  msg:='Этот черновик уже изменён или закрыт. Используйте последнее сообщение бота.';
 elsif p_action in ('save','toggle','page') then
  if p_action='save' then
   f:=p->'fields';brand:=workflow_route_brand(f->>'brand',f->>'model');
   select coalesce(jsonb_agg(jsonb_build_object('key',w.key,'name',w.name) order by w.name,w.key),'[]') into choices from workflow_model_routes(a.company_id,brand,f->>'model') w;
   select coalesce(jsonb_agg(value->>'key'),'[]') into keys from jsonb_array_elements(choices);
   selected:=case when not coalesce((p->>'fresh')::boolean,false) and d.routing->>'brand'=brand and lower(trim(d.fields->>'model'))=lower(trim(f->>'model')) then
    (select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements_text(keys) where d.routing->'selected' ? value) else keys end;
   route:=jsonb_build_object('brand',brand,'choices',choices,'selected',selected,'preview',p->>'preview','page',0);
  else
   route:=d.routing; choices:=route->'choices';selected:=route->'selected';idx:=(p->>'index')::integer;
   if idx<0 or choices is null then raise exception 'crm_conflict'; end if;
   if p_action='toggle' then
    brand:=choices->idx->>'key';if brand is null then raise exception 'crm_conflict';end if;
    selected:=case when selected ? brand then selected-brand else selected||jsonb_build_array(brand) end;
    route:=jsonb_set(route,'{selected}',selected);
   else
    if idx*6>=jsonb_array_length(choices) then raise exception 'crm_conflict';end if;
    route:=jsonb_set(route,'{page}',to_jsonb(idx));
   end if;
   p:=p||jsonb_build_object('fields',d.fields,'ready',d.ready,'source',d.source_text);
  end if;
  insert into bot_intakes(user_id,company_id,revision,fields,source_text,ready,routing)
  values(p_actor,a.company_id,rev,p->'fields',left(p->>'source',4096),(p->>'ready')::boolean,route)
  on conflict(user_id) do update set company_id=excluded.company_id,revision=excluded.revision,fields=excluded.fields,
   source_text=excluded.source_text,ready=excluded.ready,routing=excluded.routing,updated_at=now();
  msg:=route->>'preview';
  body:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(
    jsonb_build_array(jsonb_build_object('text','Отменить черновик','callback_data','leadno:'||rev)))));
  if (p->>'ready')::boolean then
   msg:=msg||E'\n\nПолучатели по марке: '||jsonb_array_length(selected)||' из '||jsonb_array_length(choices)||
    case when jsonb_array_length(choices)>0 then '. Снимите отметку с тех, кому писать не нужно.' else '. Подходящих поставщиков нет. Сообщите администратору. Заявку можно создать без рассылки.' end;
   buttons:='[]'::jsonb;pg:=(route->>'page')::integer;
   for rec in select value as item,(ord-1)::integer as i from jsonb_array_elements(choices) with ordinality as x(value,ord) where ord between pg*6+1 and pg*6+6 loop
    buttons:=buttons||jsonb_build_array(jsonb_build_array(jsonb_build_object('text',(case when selected ? (rec.item->>'key') then '✓ ' else '○ ' end)||left(rec.item->>'name',48),'callback_data','leadpick:'||rev||':'||rec.i)));
   end loop;
   if pg>0 then buttons:=buttons||jsonb_build_array(jsonb_build_array(jsonb_build_object('text','← Назад','callback_data','leadpage:'||rev||':'||(pg-1))));end if;
   if (pg+1)*6<jsonb_array_length(choices) then buttons:=buttons||jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Дальше →','callback_data','leadpage:'||rev||':'||(pg+1))));end if;
   buttons:=buttons||jsonb_build_array(jsonb_build_array(jsonb_build_object('text',
    case when jsonb_array_length(selected)>0 then 'Создать и отправить · '||jsonb_array_length(selected) else 'Создать без рассылки' end,
    'style','primary','callback_data','leadok:'||rev)))||(body#>'{reply_markup,inline_keyboard}');
   body:=jsonb_set(body,'{reply_markup,inline_keyboard}',buttons);
  end if;
 elsif p_action='confirm' and d.ready then
  f:=d.fields;
  result:=workflow_create(p_actor,d.revision,(f-'brand'-'trim'-'color')||jsonb_build_object('consent_at',now(),'source_text',d.source_text,
   'spec',concat_ws(E'\n','Цвет: '||nullif(f->>'color',''),'Комплектация: '||nullif(f->>'trim',''))),jsonb_build_object('brand',f->>'brand','color',f->>'color','trim',f->>'trim','filters',coalesce(f->'filters','{}'))||case when d.routing?'selected' then jsonb_build_object('recipients',d.routing->'selected') else '{}'::jsonb end);
  rid:=(result->'request'->>'id')::uuid;
  insert into bot_context(user_id,company_id,request_id,thread_id,offer_id,dialogue) values(p_actor,a.company_id,rid,null,null,'[]')
   on conflict(user_id) do update set company_id=excluded.company_id,request_id=excluded.request_id,thread_id=null,offer_id=null,dialogue='[]';
  msg:='Заявка создана · '||(f->>'model')||E'\nПоставщиков в рассылке: '||(result->>'queued');
  body:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object(
   'text','Открыть подбор','style','primary','web_app',jsonb_build_object('url',(p->>'desk')||'?request='||rid||'&mini=1'))))));
  delete from bot_intakes where user_id=p_actor;
 elsif p_action='cancel' then
  delete from bot_intakes where user_id=p_actor and company_id=a.company_id;
  msg:='Черновик закрыт.';
 else msg:='Перешлите сообщение клиента, чтобы начать новую заявку.';
 end if;
 if body is null then
  body:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','В меню','callback_data','nav:home')))));
 end if;
 insert into bot_outbox(chat_id,actor_id,scope_company_id,request_id,dedupe_key,body)
 values(p_actor,p_actor,a.company_id,rid,'intake:'||p_job,coalesce(body,'{}')||jsonb_build_object('text',msg));
end $$;
revoke all on function public.bot_intake(bigint,bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.bot_intake(bigint,bigint,text,jsonb) to service_role;
