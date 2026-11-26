-- Apply after intake.sql and session.sql. Telegram drafts are private to the sender.
create table if not exists public.bot_readings (
 job_id bigint primary key references public.bot_jobs(id),
 revision uuid not null unique default gen_random_uuid(),
 root_job bigint not null references public.bot_jobs(id),
 actor_id bigint not null references public.app_users(tg_id),
 company_id uuid not null references public.app_companies(id),
 thread_id uuid references public.bot_threads(id),
 state text not null check(state in ('waiting','ready','editing','confirmed','cancelled','superseded')),
 source text not null, additions text not null default '', fields jsonb not null default '{}',
 summary text not null default '', question text not null default '', jpeg text,
 lease uuid, retry_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists bot_read_queue on public.bot_readings(company_id,retry_at) where state='waiting';
create index if not exists bot_read_actor on public.bot_readings(actor_id,thread_id,job_id desc) where state in ('waiting','ready','editing');
alter table public.bot_readings enable row level security;
revoke all on public.bot_readings from public,anon,authenticated;
grant select,insert,update on public.bot_readings to service_role;

-- Album images that follow a caption stay private with the same draft.
create table if not exists public.bot_read_photos (
 job_id bigint primary key references public.bot_jobs(id),
 root_job bigint not null references public.bot_jobs(id), jpeg text not null
);
alter table public.bot_read_photos enable row level security;
revoke all on public.bot_read_photos from public,anon,authenticated;
grant select,insert,delete on public.bot_read_photos to service_role;

create or replace function public.bot_read_allowed(d public.bot_readings)
returns boolean language sql stable security invoker set search_path=public,pg_temp as $$
 select exists(select 1 from app_users a where a.tg_id=d.actor_id and a.active and (
  (d.thread_id is null and a.company_id=d.company_id and a.role in ('manager','admin','owner')) or
  (a.role='supplier' and exists(select 1 from bot_threads t join crm_requests r on r.id=t.request_id where
    t.id=d.thread_id and t.supplier_id=a.tg_id and t.company_id=d.company_id and r.archived_at is null))))
$$;

create or replace function public.bot_read_question(d public.bot_readings)
returns text language sql stable security invoker set search_path=public,pg_temp as $$
 select left(bm.sanitized_text,1000) from bot_jobs j join bot_outbox b on b.thread_id=d.thread_id and b.chat_id=d.actor_id
 join bot_messages bm on bm.id=b.message_id and bm.thread_id=d.thread_id where j.id=d.root_job and b.state='sent' and bm.actor_id<>d.actor_id
 and b.created_at<=j.created_at and (j.payload#>>'{message,reply_to_message,message_id}' is null or b.telegram_message_id::text=j.payload#>>'{message,reply_to_message,message_id}')
 order by b.created_at desc limit 1
$$;
revoke all on function public.bot_read_question(public.bot_readings) from public,anon,authenticated;
grant execute on function public.bot_read_question(public.bot_readings) to service_role;

create or replace function public.bot_read_start(p_actor bigint,p_job bigint,p_thread uuid,p_new boolean,p_inline boolean,p_seed jsonb,p_jpeg text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare m jsonb; a app_users; d bot_readings; prior bot_readings; legacy bot_intakes; co uuid;
 raw text; additions text:=''; base jsonb:='{}'; src text; acknowledged text; root_id bigint:=p_job; has_reader boolean;
begin
 perform pg_advisory_xact_lock(p_actor);
 select * into strict a from app_users where tg_id=p_actor and active;
 select payload->'message' into strict m from bot_jobs where id=p_job and actor_id=p_actor;
 if m#>>'{chat,type}' is distinct from 'private' or m#>>'{chat,id}' is distinct from p_actor::text or m#>>'{from,id}' is distinct from p_actor::text then raise exception 'invalid_message'; end if;
 if m?'voice' and (coalesce((m#>>'{voice,duration}')::int,0) not between 1 and 120 or coalesce((m#>>'{voice,file_size}')::bigint,0) not between 0 and 8388608 or coalesce(m#>>'{voice,file_id}','')='') then raise exception 'invalid_voice'; end if;
 if p_thread is null then
  if a.role not in('manager','owner','admin') then raise exception 'crm_forbidden'; end if; co:=a.company_id;
 else
  perform bot_thread_access(p_actor,p_thread);
  select company_id into strict co from bot_threads where id=p_thread and supplier_id=p_actor and a.role='supplier';
 end if;
 if exists(select 1 from bot_readings where job_id=p_job) then return jsonb_build_object('handled',true); end if;
 select exists(select 1 from bot_session_companies where company_id=co) into has_reader;
 select * into prior from bot_readings where actor_id=p_actor and company_id=co and thread_id is not distinct from p_thread
 and state in ('ready','editing','waiting') and (p_thread is null or state='editing' or (state='ready' and question<>'') or (state='waiting' and root_job<>job_id))
 order by job_id desc limit 1 for update;
 if p_thread is null then select * into legacy from bot_intakes where company_id=co and user_id=p_actor for update; end if;
 if p_new and prior.state='editing' and (m?'forward_origin' or m?'forward_from' or m?'forward_date') and coalesce(m->>'text','') !~* '^/new([[:space:]]|@|$)' then p_new:=false; end if;
 if not p_new and p_thread is null and prior.job_id is null and legacy.user_id is null then return '{"handled":false}'; end if;
 raw:=left(regexp_replace(coalesce(m->>'text',m->>'caption',''),'^/new(@[a-zA-Z0-9_]+)?([[:space:]]+|$)','','i'),4096);
 if length(trim(raw))=0 and not m?'voice' then return '{"handled":false}'; end if;
 if not has_reader and not p_inline then return jsonb_build_object('handled',false,'offline',true); end if;
 if prior.job_id is not null then
  if not p_new and prior.state='waiting' and exists(select 1 from bot_jobs where id=prior.job_id and (payload->'message')?'voice') then
   insert into bot_outbox(chat_id,actor_id,scope_company_id,thread_id,dedupe_key,body) values(p_actor,p_actor,co,p_thread,'reading:busy:'||p_job,jsonb_build_object('text','Предыдущее голосовое ещё разбирается. Когда появится черновик, нажмите «Уточнить» и пришлите дополнение.'));
   return '{"handled":true}';
  end if;
  if not p_new then
   root_id:=prior.root_job; base:=prior.fields; src:=prior.source;
   additions:=concat_ws(E'\n',nullif(prior.additions,''),nullif(raw,''));
   if length(additions)>8000 then raise exception 'reading_too_long'; end if;
  end if;
  update bot_readings set state='superseded',lease=null,jpeg=null where job_id=prior.job_id;
 elsif not p_new and legacy.user_id is not null then
  base:=legacy.fields; src:=legacy.source_text; additions:=raw;
 end if;
 if legacy.user_id is not null then delete from bot_intakes where user_id=p_actor; end if;
 if p_jpeg is not null and (p_thread is null or length(p_jpeg)>350000 or not m?'photo') then raise exception 'invalid_photo'; end if;
 insert into bot_readings(job_id,root_job,actor_id,company_id,thread_id,state,source,additions,fields,summary,jpeg,lease,retry_at)
 values(p_job,root_id,p_actor,co,p_thread,'waiting',coalesce(nullif(src,''),raw),additions,base||coalesce(p_seed,'{}'),case when p_new then '' else coalesce(prior.summary,'') end,case when p_new then p_jpeg else coalesce(p_jpeg,prior.jpeg) end,
 case when p_inline then gen_random_uuid() end,case when p_inline then now()+interval '2 minutes' else now() end) returning * into d;
 if not p_inline then
  acknowledged:=case when p_thread is null then 'Разбираю пожелания клиента. Пришлю параметры на проверку.' else 'Разбираю ответ. Перед отправкой менеджеру покажу, что понял.' end;
  insert into bot_outbox(chat_id,actor_id,scope_company_id,thread_id,dedupe_key,body) values(p_actor,p_actor,co,p_thread,'reading:wait:'||p_job,jsonb_build_object('text',acknowledged));
 end if;
 return jsonb_build_object('handled',true,'lease',d.lease,'source',d.source,'additions',d.additions,'previous',d.fields,'summary',d.summary,'question',bot_read_question(d));
end $$;

create or replace function public.bot_read_claim(p_company uuid)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare d bot_readings; m jsonb;
begin
 select * into d from bot_readings q where company_id=p_company and state='waiting' and retry_at<=now() and bot_read_allowed(q)
 and exists(select 1 from bot_session_companies where company_id=p_company) order by retry_at,job_id limit 1 for update skip locked;
 if not found then return null; end if;
 update bot_readings set lease=gen_random_uuid(),retry_at=now()+interval '10 minutes' where job_id=d.job_id returning * into d;
 select payload->'message' into m from bot_jobs where id=d.job_id;
 return jsonb_build_object('task',case when d.thread_id is null then 'lead' else 'supplier' end,'job_id',d.job_id::text,'lease',d.lease,
 'kind',case when m?'voice' then 'voice' else 'text' end,'source',d.source,'corrections',d.additions,'previous',d.fields,'previous_summary',d.summary,'question',bot_read_question(d));
end $$;

create or replace function public.bot_read_audio_ref(p_job bigint,p_lease uuid)
returns text language sql stable security invoker set search_path=public,pg_temp as $$
 select j.payload#>>'{message,voice,file_id}' from bot_readings d join bot_jobs j on j.id=d.job_id and j.actor_id=d.actor_id
 where d.job_id=p_job and d.lease=p_lease and d.retry_at>now() and d.state='waiting' and bot_read_allowed(d)
$$;

-- Only explicitly supported facts can reach the CRM. Unknown values stay absent.
create or replace function public.bot_read_fields(lead boolean,f jsonb)
returns jsonb language plpgsql immutable security invoker set search_path=public,pg_temp as $$
declare k text; v jsonb; s text; output jsonb:='{}'; allowed text[];
begin
 if jsonb_typeof(f) is distinct from 'object' or length(f::text)>9000 then raise exception 'invalid_fields'; end if;
 allowed:=case when lead then array['client_name','phone','budget','brand','model','generation','years','mileage','color','trim','city','filters','spec']
 else array['kind','purchase','currency','quote_mode','logistics','duty','recycling','documents','commission','model','years','mileage','term','color','trim','body','gearbox','fuel','drive','generation'] end;
 for k,v in select key,value from jsonb_each(f) loop
  if not k=any(allowed) then raise exception 'invalid_field'; end if;
  if v='null'::jsonb then continue; end if;
  s:=trim(v#>>'{}');
  if k='years' and jsonb_typeof(v)='number' and s ~ '^(19|20)[0-9]{2}$' then v:=to_jsonb(s); end if;
  if k='filters' then v:=workflow_filters(v);
  elsif k in ('budget','purchase','mileage','logistics','duty','recycling','documents','commission') then
   if jsonb_typeof(v)<>'number' or v::numeric<0 or v::numeric>100000000000 or (k in ('purchase','budget') and v::numeric<=0) or (k='mileage' and (v::numeric>20000000 or trunc(v::numeric)<>v::numeric)) then raise exception 'invalid_number'; end if;
  else
   if jsonb_typeof(v)<>'string' or length(s)>(case when k='spec' then 1500 when k='brand' then 80 else 160 end) or s~'[[:cntrl:]]' then raise exception 'invalid_string'; end if;
   if s='' then continue; end if;
   if k='phone' then s:=regexp_replace(s,'[ ()+-]','','g'); if s~'^8[0-9]{10}$' then s:='7'||substr(s,2); end if; if s!~'^[0-9]{10,15}$' then raise exception 'invalid_phone'; end if; end if;
   if k not in ('client_name','phone','spec','city') and (s~*'(https?://|www\.|t\.me/|@|[+]?[0-9][0-9 ()-]{8,}[0-9])' or (lead and length(f->>'client_name')>=3 and strpos(lower(s),lower(f->>'client_name'))>0)) then raise exception 'contact_in_result'; end if;
   if (k='currency' and s not in ('RUB','JPY','CNY','USD','EUR')) or (k='quote_mode' and s not in ('turnkey','itemized')) or (k='kind' and s not in ('quote','clarification','unavailable','unintelligible')) then raise exception 'invalid_enum'; end if;
   v:=to_jsonb(s);
  end if;
  output:=output||jsonb_build_object(k,v);
 end loop;
 if not lead then
  if not output?'kind' then raise exception 'missing_kind'; end if;
  if output->>'kind'='quote' and not output?&array['purchase','currency'] then raise exception 'invalid_quote'; end if;
  if output->>'kind'<>'quote' and (output-'kind')<>'{}' then raise exception 'invalid_clarification'; end if;
 end if;
 return output;
end $$;

create or replace function public.bot_read_lines(f jsonb)
returns text language plpgsql immutable security invoker set search_path=public,pg_temp as $$
declare x record; value text; lines text[]:='{}';
begin
 for x in select * from (values
 ('client_name','Клиент'),('phone','Телефон'),('brand','Марка'),('model','Модель'),('generation','Поколение'),('years','Год'),
 ('budget','Бюджет, ₽'),('mileage','Пробег, км'),('color','Цвет'),('trim','Комплектация'),('city','Город'),('spec','Пожелания'),
 ('body','Кузов'),('gearbox','Коробка'),('drive','Привод'),('fuel','Топливо'),('price_from','Цена от, ₽'),('price_to','Цена до, ₽'),
 ('year_from','Год от'),('year_to','Год до'),('mileage_from','Пробег от, км'),('mileage_to','Пробег до, км'),
 ('quote_mode','Расчёт'),('purchase','Цена поставщика'),('logistics','Доставка, ₽'),('duty','Пошлина, ₽'),('recycling','Утильсбор, ₽'),
 ('documents','Оформление, ₽'),('commission','Комиссия, ₽'),('term','Срок')) labels(k,title) loop
  value:=coalesce(f->>x.k,f->'filters'->>x.k);
  if value is null then continue; end if;
  if x.k='quote_mode' then value:=case value when 'turnkey' then 'Под ключ' else 'Цена и расходы отдельно' end; end if;
  if (x.k='price_to' and value=f->>'budget') or (x.k='mileage_to' and value=f->>'mileage') then continue; end if;
  if x.k in ('budget','purchase','price_from','price_to','mileage','mileage_from','mileage_to','logistics','duty','recycling','documents','commission') then
   value:=replace(to_char(trunc(value::numeric),'FM999,999,999,999,990'),',',' ')||case when strpos(value,'.')>0 then ','||split_part(value,'.',2) else '' end;
  end if;
  if x.k='purchase' then value:=value||' '||(f->>'currency'); end if;
  lines:=array_append(lines,x.title||': '||value);
 end loop;
 return array_to_string(lines,E'\n');
end $$;

create or replace function public.bot_read_finish(p_job bigint,p_lease uuid,p_summary text,p_fields jsonb,p_question text default '')
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare d bot_readings; facts jsonb; msg text; buttons jsonb; prompt text; missing text; lead boolean;
begin
 select * into strict d from bot_readings where job_id=p_job and lease=p_lease for update;
 if d.state in ('ready','editing','confirmed','cancelled') then return d.revision; end if;
 if d.state<>'waiting' or d.retry_at<=now() or not bot_read_allowed(d) then raise exception 'expired_lease'; end if;
 lead:=d.thread_id is null;
 facts:=bot_read_fields(lead,p_fields);
 if p_summary is null or length(p_summary)>3000 or length(coalesce(p_question,''))>350 then raise exception 'invalid_summary'; end if;
 if not lead and (nullif(trim(p_summary),'') is null or p_summary~*'(https?://|www\.|t\.me/|@|\+[0-9][0-9 ()-]{8,}[0-9])') then raise exception 'invalid_supplier_text'; end if;
 if lead then
  select string_agg(label,', ' order by pos) into missing from (values (1,'client_name','имя'),(2,'phone','телефон'),(3,'brand','марку'),(4,'model','модель'),(5,'budget','бюджет')) as needed(pos,k,label) where not facts?k;
 end if;
 prompt:=coalesce(nullif(trim(p_question),''),case when missing is not null then 'Уточните одним сообщением: '||missing||'.' when facts->>'kind'='unintelligible' then 'Повторите сообщение текстом или голосом.' end,'');
 msg:=case when lead then 'Правильно понял заявку?' else 'Правильно понял ваш ответ?' end;
 if not lead then msg:=msg||E'\n\n'||p_summary; end if;
 if bot_read_lines(facts)<>'' then msg:=msg||E'\n\n'||bot_read_lines(facts); end if;
 if prompt<>'' then msg:=msg||E'\n\n'||prompt; end if;
 buttons:=jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Уточнить','callback_data','rdedit:'||d.revision),jsonb_build_object('text','Нет, отменить','callback_data','rdno:'||d.revision)));
 buttons:=jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Да, всё верно','style','primary','callback_data','rdyes:'||d.revision)))||buttons;
 update bot_readings set state='ready',fields=facts,summary=trim(p_summary),question=prompt,
 source=case when source='' then trim(p_summary) else source end where job_id=p_job;
 insert into bot_outbox(chat_id,actor_id,thread_id,scope_company_id,dedupe_key,body) values(d.actor_id,d.actor_id,d.thread_id,d.company_id,'reading:preview:'||p_job,
 jsonb_build_object('text',left(msg,4000),'reply_markup',jsonb_build_object('inline_keyboard',buttons)));
 return d.revision;
end $$;

create or replace function public.bot_read_decide(p_actor bigint,p_job bigint,p_revision uuid,p_action text)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare d bot_readings; note text; receipt jsonb; m jsonb; photo record; kb jsonb:='{}';
begin
 perform pg_advisory_xact_lock(p_actor);
 if not exists(select 1 from bot_jobs where id=p_job and actor_id=p_actor) then raise exception 'crm_forbidden'; end if;
 if exists(select 1 from bot_outbox where dedupe_key='reading:click:'||p_job or dedupe_key='intake:'||p_job) then return; end if;
 select * into d from bot_readings where actor_id=p_actor and revision=p_revision for update;
 if not found or not bot_read_allowed(d) then raise exception 'crm_forbidden'; end if;
 if d.state not in ('ready','editing') then
  note:=case d.state when 'confirmed' then 'Уже подтверждено.' when 'cancelled' then 'Черновик уже отменён.' else 'Это прежний разбор. Откройте последнее сообщение бота.' end;
 elsif p_action='no' then
  update bot_readings set state='cancelled',jpeg=null where job_id=d.job_id;
  delete from bot_read_photos where root_job=d.root_job;
  note:='Черновик отменён.';
  kb:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','В меню','callback_data','nav:home')))));
 elsif p_action='edit' or (p_action='yes' and d.question<>'') then
  if d.thread_id is not null then
   update bot_readings set state='ready' where actor_id=p_actor and thread_id=d.thread_id and state='editing' and job_id<>d.job_id;
   insert into bot_context(user_id,company_id,thread_id,request_id,dialogue) select p_actor,d.company_id,t.id,t.request_id,'[]'::jsonb from bot_threads t where t.id=d.thread_id
   on conflict(user_id) do update set company_id=excluded.company_id,thread_id=excluded.thread_id,request_id=excluded.request_id,offer_id=null,dialogue='[]';
  end if;
  update bot_readings set state='editing' where job_id=d.job_id;
  note:=coalesce(nullif(d.question,''),'Напишите все уточнения одним сообщением. Затем я покажу обновлённый разбор.');
 elsif p_action='yes' and d.state='ready' and d.question='' then
  if d.thread_id is null then
   perform bot_intake(p_actor,p_job,'save',jsonb_build_object('previous',null,'fresh',true,'fields',d.fields,'ready',true,'source',d.source,
    'preview','Параметры подтверждены.'||E'\n'||bot_read_lines(d.fields)||E'\n\nПроверьте получателей и согласие клиента перед созданием заявки.'));
   update bot_readings set state='confirmed' where job_id=d.job_id;
   return;
  end if;
  select payload->'message' into strict m from bot_jobs where id=d.root_job;
  receipt:=workflow_receive(p_actor,d.thread_id,d.root_job,coalesce(m->>'media_group_id',case when d.jpeg is not null then 'image:'||d.root_job end),d.summary,
    d.fields||jsonb_build_object('input_kind',case when m?'voice' then 'voice' else 'text' end),d.jpeg);
  update bot_readings set state='confirmed',jpeg=null where job_id=d.job_id;
  for photo in select * from bot_read_photos where root_job=d.root_job order by job_id loop
   perform workflow_receive(p_actor,d.thread_id,photo.job_id,m->>'media_group_id','',null,photo.jpeg);
  end loop;
  delete from bot_read_photos where root_job=d.root_job;
  note:='Ответ отправлен менеджеру в этой заявке.';
  kb:=jsonb_build_object('reply_markup',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Добавить фото','callback_data','addpic:'||(receipt->>'id'))))));
 else note:='Пришлите уточнение и проверьте обновлённый разбор.';
 end if;
 insert into bot_outbox(chat_id,actor_id,scope_company_id,thread_id,dedupe_key,body) values(p_actor,p_actor,d.company_id,d.thread_id,'reading:click:'||p_job,jsonb_build_object('text',note)||kb);
end $$;

revoke all on function public.bot_read_allowed(public.bot_readings),public.bot_read_start(bigint,bigint,uuid,boolean,boolean,jsonb,text),public.bot_read_claim(uuid),public.bot_read_audio_ref(bigint,uuid),public.bot_read_fields(boolean,jsonb),public.bot_read_lines(jsonb),public.bot_read_finish(bigint,uuid,text,jsonb,text),public.bot_read_decide(bigint,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.bot_read_allowed(public.bot_readings),public.bot_read_start(bigint,bigint,uuid,boolean,boolean,jsonb,text),public.bot_read_claim(uuid),public.bot_read_audio_ref(bigint,uuid),public.bot_read_fields(boolean,jsonb),public.bot_read_lines(jsonb),public.bot_read_finish(bigint,uuid,text,jsonb,text),public.bot_read_decide(bigint,bigint,uuid,text) to service_role;

create or replace function public.bot_read_retry(p_job bigint,p_lease uuid)
returns boolean language plpgsql security invoker set search_path=public,pg_temp as $$
declare d bot_readings;
begin
 select * into d from bot_readings where job_id=p_job and lease=p_lease and state='waiting' for update;
 if not found then return true; end if;
 if exists(select 1 from bot_session_companies where company_id=d.company_id) then
  update bot_readings set lease=null,retry_at=now() where job_id=p_job;
  insert into bot_outbox(chat_id,actor_id,scope_company_id,thread_id,dedupe_key,body)
  values(d.actor_id,d.actor_id,d.company_id,d.thread_id,'reading:retry:'||p_job,jsonb_build_object('text','Сообщение принято. Пришлю разбор на проверку.')) on conflict do nothing;
  return true;
 end if;
 update bot_readings set state='editing',lease=null where job_id=p_job;
 return false;
end $$;
revoke all on function public.bot_read_retry(bigint,uuid) from public,anon,authenticated;
grant execute on function public.bot_read_retry(bigint,uuid) to service_role;

create or replace function public.bot_read_album(p_actor bigint,p_album text)
returns uuid language sql stable security invoker set search_path=public,pg_temp as $$
 select d.thread_id from bot_readings d join bot_jobs j on j.id=d.root_job where d.actor_id=p_actor
 and j.payload#>>'{message,media_group_id}'=p_album and d.thread_id is not null and bot_read_allowed(d)
 order by d.job_id desc limit 1
$$;

create or replace function public.bot_read_hold_photo(p_actor bigint,p_thread uuid,p_job bigint,p_album text,p_jpeg text)
returns boolean language plpgsql security invoker set search_path=public,pg_temp as $$
declare d bot_readings;
begin
 perform pg_advisory_xact_lock(p_actor);
 if not exists(select 1 from bot_jobs where id=p_job and actor_id=p_actor and payload#>>'{message,media_group_id}'=p_album and payload->'message'?'photo') or p_jpeg is null or length(p_jpeg)>350000 then raise exception 'invalid_photo'; end if;
 select q.* into d from bot_readings q join bot_jobs j on j.id=q.root_job where q.thread_id=p_thread and q.actor_id=p_actor
 and j.payload#>>'{message,media_group_id}'=p_album order by q.job_id desc limit 1 for update of q;
 if not found or d.state='confirmed' then return false; end if;
 if not bot_read_allowed(d) then raise exception 'crm_forbidden'; end if;
 if d.state not in ('superseded','cancelled') then
  insert into bot_read_photos values(p_job,d.root_job,p_jpeg) on conflict(job_id) do nothing;
 end if;
 return true;
end $$;

create or replace function public.bot_read_new_lead(p_actor bigint,p_job bigint)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 perform pg_advisory_xact_lock(p_actor);
 if not exists(select 1 from app_users a join bot_jobs j on j.actor_id=a.tg_id where j.id=p_job and a.tg_id=p_actor and a.active and a.role in ('owner','admin','manager')) then raise exception 'crm_forbidden'; end if;
 update bot_readings set state='superseded',lease=null where actor_id=p_actor and thread_id is null and state in ('waiting','ready','editing');
end $$;
revoke all on function public.bot_read_album(bigint,text),public.bot_read_hold_photo(bigint,uuid,bigint,text,text),public.bot_read_new_lead(bigint,bigint) from public,anon,authenticated;
grant execute on function public.bot_read_album(bigint,text),public.bot_read_hold_photo(bigint,uuid,bigint,text,text),public.bot_read_new_lead(bigint,bigint) to service_role;
