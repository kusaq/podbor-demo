-- Apply after workflow.sql. One editable draft per authorized employee.
create table if not exists public.bot_intakes (
 user_id bigint primary key references public.app_users(tg_id) on update cascade on delete cascade,
 company_id uuid not null references public.app_companies(id), revision uuid not null unique,
 fields jsonb not null, source_text text not null, ready boolean not null, updated_at timestamptz not null default now()
);
alter table public.bot_intakes enable row level security;
revoke all on public.bot_intakes from public,anon,authenticated;
grant select,insert,update,delete on public.bot_intakes to service_role;

create or replace function public.bot_intake(p_actor bigint,p_job bigint,p_action text,p jsonb)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare a app_users; d bot_intakes; f jsonb; result jsonb; rid uuid; rev uuid:=gen_random_uuid(); body jsonb; msg text;
begin
 select * into strict a from app_users where tg_id=p_actor and active and role in ('manager','owner','admin') for share;
 perform pg_advisory_xact_lock(p_actor);
 if not exists(select 1 from bot_jobs where id=p_job and actor_id=p_actor) then raise exception 'crm_forbidden'; end if;
 if exists(select 1 from bot_outbox where dedupe_key='intake:'||p_job) then return; end if;
 select * into d from bot_intakes where user_id=p_actor and company_id=a.company_id for update;
 if coalesce(p->>'previous','')<>coalesce(d.revision::text,'') then
  msg:='Этот черновик уже изменён или закрыт. Используйте последнее сообщение бота.';
 elsif p_action='save' then
  insert into bot_intakes(user_id,company_id,revision,fields,source_text,ready)
  values(p_actor,a.company_id,rev,p->'fields',left(p->>'source',4096),(p->>'ready')::boolean)
  on conflict(user_id) do update set company_id=excluded.company_id,revision=excluded.revision,fields=excluded.fields,
   source_text=excluded.source_text,ready=excluded.ready,updated_at=now();
  msg:=p->>'preview';
  body:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(
    (case when (p->>'ready')::boolean then jsonb_build_array(jsonb_build_object('text','Создать заявку','callback_data','leadok:'||rev)) else '[]'::jsonb end)||
    jsonb_build_array(jsonb_build_object('text','Отменить','callback_data','leadno:'||rev)))));
 elsif p_action='confirm' and d.ready then
  f:=d.fields;
  result:=workflow_create(p_actor,d.revision,(f-'brand'-'trim'-'color')||jsonb_build_object('consent_at',now(),'source_text',d.source_text,
   'spec',concat_ws(E'\n','Цвет: '||nullif(f->>'color',''),'Комплектация: '||nullif(f->>'trim',''))),jsonb_build_object('brand',f->>'brand','color',f->>'color','trim',f->>'trim'));
  rid:=(result->'request'->>'id')::uuid;
  insert into bot_context(user_id,company_id,request_id,thread_id,offer_id,dialogue) values(p_actor,a.company_id,rid,null,null,'[]')
   on conflict(user_id) do update set company_id=excluded.company_id,request_id=excluded.request_id,thread_id=null,offer_id=null,dialogue='[]';
  msg:='Заявка создана · '||(f->>'model')||E'\nПоставщиков в рассылке: '||(result->>'queued');
  body:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object(
   'text','Открыть заявку','web_app',jsonb_build_object('url',(p->>'desk')||'?request='||rid||'&mini=1'))))));
  delete from bot_intakes where user_id=p_actor;
 elsif p_action='cancel' then
  delete from bot_intakes where user_id=p_actor and company_id=a.company_id;
  msg:='Черновик закрыт.';
 else msg:='Перешлите сообщение клиента, чтобы начать новую заявку.';
 end if;
 insert into bot_outbox(chat_id,actor_id,scope_company_id,request_id,dedupe_key,body)
 values(p_actor,p_actor,a.company_id,rid,'intake:'||p_job,coalesce(body,'{}')||jsonb_build_object('text',msg));
end $$;
revoke all on function public.bot_intake(bigint,bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.bot_intake(bigint,bigint,text,jsonb) to service_role;
