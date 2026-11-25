-- Inbox for the temporary, company-scoped Codex reader. Apply after workflow.sql.
create table if not exists public.bot_session_companies (
 company_id uuid primary key references public.app_companies(id)
);
alter table public.bot_session_companies enable row level security;
revoke all on public.bot_session_companies from public,anon,authenticated;
grant select on public.bot_session_companies to service_role;

create table if not exists public.bot_session_inputs (
 job_id bigint primary key references public.bot_jobs(id),
 thread_id uuid not null references public.bot_threads(id),
 kind text not null check (kind in ('text','voice')),
 lease uuid, retry_at timestamptz not null default now(), attempts int not null default 0,
 finished_at timestamptz, message_id uuid references public.bot_messages(id)
);
create index if not exists bot_session_ready on public.bot_session_inputs(retry_at,job_id) where finished_at is null;
create index if not exists bot_session_thread on public.bot_session_inputs(thread_id);
alter table public.bot_session_inputs enable row level security;
revoke all on public.bot_session_inputs from public,anon,authenticated;
grant select,insert,update on public.bot_session_inputs to service_role;

create or replace function public.bot_session_only_thread(p_actor bigint)
returns uuid language sql stable set search_path=public,pg_temp as $$
 select case when count(*)=1 then (array_agg(id))[1] end from (
  select t.id from bot_threads t join app_users u on u.tg_id=t.supplier_id and u.active and u.role='supplier'
  join crm_requests r on r.id=t.request_id and r.archived_at is null where t.supplier_id=p_actor limit 2
 ) eligible
$$;
revoke all on function public.bot_session_only_thread(bigint) from public,anon,authenticated;
grant execute on function public.bot_session_only_thread(bigint) to service_role;
create or replace function public.bot_session_enqueue(p_actor bigint,p_thread uuid,p_job bigint)
returns boolean language plpgsql set search_path=public,pg_temp as $$
declare m jsonb; k text;
begin
 perform bot_thread_access(p_actor,p_thread);
 select j.payload->'message' into strict m from bot_jobs j join bot_threads t on t.id=p_thread and t.supplier_id=j.actor_id
 join app_users u on u.tg_id=t.supplier_id and u.role='supplier' and u.active where j.id=p_job and j.actor_id=p_actor;
 if m#>>'{chat,type}' is distinct from 'private' or m#>>'{from,id}' is distinct from p_actor::text
    or m#>>'{chat,id}' is distinct from p_actor::text then raise exception 'invalid_message'; end if;
 if m?'voice' then
  if coalesce(m#>>'{voice,file_id}','')='' or coalesce((m#>>'{voice,duration}')::int,0) not between 1 and 120
    or coalesce((m#>>'{voice,file_size}')::bigint,0) not between 0 and 8388608 then raise exception 'invalid_voice'; end if;
  k:='voice';
 elsif length(btrim(coalesce(m->>'text',m->>'caption',''))) between 1 and 4096 then k:='text';
 else raise exception 'invalid_message'; end if;
 if not exists(select 1 from bot_threads t join bot_session_companies c on c.company_id=t.company_id where t.id=p_thread) then return false; end if;
 insert into bot_session_inputs(job_id,thread_id,kind) values(p_job,p_thread,k) on conflict(job_id) do nothing;
 if not exists(select 1 from bot_session_inputs where job_id=p_job and thread_id=p_thread) then raise exception 'thread_changed'; end if;
 return true;
end $$;

create or replace function public.bot_session_claim(p_company uuid)
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare s bot_session_inputs; j bot_jobs; t bot_threads; question text; ticket uuid:=gen_random_uuid(); sent_reply text;
begin
 select q.* into s from bot_session_inputs q join bot_threads th on th.id=q.thread_id
 join crm_requests r on r.id=th.request_id and r.archived_at is null join app_users u on u.tg_id=th.supplier_id and u.active and u.role='supplier'
 where th.company_id=p_company and exists(select 1 from bot_session_companies where company_id=p_company) and q.finished_at is null and q.retry_at<=now()
 order by q.retry_at,q.job_id limit 1 for update of q skip locked;
 if not found then return null; end if;
 select * into strict j from bot_jobs where id=s.job_id;
 select * into strict t from bot_threads where id=s.thread_id and supplier_id=j.actor_id;
 sent_reply:=j.payload#>>'{message,reply_to_message,message_id}';
 select bm.sanitized_text into question from bot_outbox b join bot_messages bm on bm.id=b.message_id and bm.thread_id=t.id
 where b.thread_id=t.id and b.chat_id=j.actor_id and b.state='sent' and bm.actor_id<>j.actor_id and coalesce(b.delivered_at,b.created_at)<=j.created_at
 and (sent_reply is null or b.telegram_message_id::text=sent_reply)
 order by coalesce(b.delivered_at,b.created_at) desc,b.id limit 1;
 update bot_session_inputs set lease=ticket,retry_at=now()+interval '10 minutes',attempts=attempts+1 where job_id=s.job_id;
 return jsonb_build_object('job_id',s.job_id::text,'lease',ticket,'kind',s.kind,'question',left(question,1000),
 'text',case when s.kind='text' then left(coalesce(j.payload#>>'{message,text}',j.payload#>>'{message,caption}'),4096) end);
end $$;

create or replace function public.bot_session_audio_ref(p_job bigint,p_lease uuid)
returns text language sql stable set search_path=public,pg_temp as $$
 select j.payload#>>'{message,voice,file_id}' from bot_session_inputs s join bot_jobs j on j.id=s.job_id
 join bot_threads t on t.id=s.thread_id and t.supplier_id=j.actor_id join crm_requests r on r.id=t.request_id and r.archived_at is null
 join app_users u on u.tg_id=j.actor_id and u.active and u.role='supplier'
 where s.job_id=p_job and s.lease=p_lease and s.kind='voice' and s.finished_at is null and s.retry_at>now()
$$;

create or replace function public.bot_session_finish(p_job bigint,p_lease uuid,p_text text,p_facts jsonb)
returns uuid language plpgsql set search_path=public,pg_temp as $$
declare s bot_session_inputs; j bot_jobs; saved jsonb; k text; v jsonb; album_id text; action text:=p_facts->>'kind';
begin
 select * into strict s from bot_session_inputs where job_id=p_job and lease=p_lease for update;
 if s.finished_at is not null then return s.message_id; end if;
 if s.retry_at<=now() then raise exception 'expired_lease'; end if;
 select * into strict j from bot_jobs where id=p_job;
 perform bot_thread_access(j.actor_id,s.thread_id);
 if not exists(select 1 from bot_threads t join app_users u on u.tg_id=t.supplier_id and u.active and u.role='supplier'
    where t.id=s.thread_id and t.supplier_id=j.actor_id) then raise exception 'access_changed'; end if;
 if p_text is null or length(btrim(p_text)) not between 1 and 3500 or jsonb_typeof(p_facts) is distinct from 'object'
    or action is null or action not in ('clarification','quote','unavailable','unintelligible') then raise exception 'invalid_result'; end if;
 if p_text ~* '(https?://|www\.|t\.me/|@[[:alnum:]_]+|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]+|\+[0-9][0-9 ()-]{8,}[0-9])' then raise exception 'contact_in_result'; end if;
 for k,v in select key,value from jsonb_each(p_facts) loop
  if k='kind' then continue;
  elsif action<>'quote' then raise exception 'invalid_fact';
  elsif k in ('purchase','mileage','logistics','duty','recycling','documents','commission') then
   if jsonb_typeof(v)<>'number' or v::text::numeric not between 0 and 100000000000 then raise exception 'invalid_number'; end if;
  elsif k='currency' then
   if coalesce(p_facts->>k,'') not in ('RUB','JPY','CNY','USD','EUR') then raise exception 'invalid_currency'; end if;
  elsif k='quote_mode' then
   if coalesce(p_facts->>k,'') not in ('turnkey','itemized') then raise exception 'invalid_mode'; end if;
  elsif k in ('model','years','term','color','trim','body','gearbox','fuel','drive','generation') then
   if jsonb_typeof(v)<>'string' or length(p_facts->>k) not between 1 and 120 or (p_facts->>k) ~ '[[:cntrl:]@/:+]' then raise exception 'invalid_field'; end if;
  else raise exception 'invalid_fact'; end if;
 end loop;
 if action='quote' and (not (p_facts ?& array['purchase','currency']) or (p_facts->>'purchase')::numeric<=0) then raise exception 'invalid_quote'; end if;
 album_id:=coalesce(j.payload#>>'{message,media_group_id}',case when j.payload->'message'?'photo' then 'image:'||p_job end);
 saved:=workflow_receive(j.actor_id,s.thread_id,p_job,album_id,btrim(p_text),p_facts||jsonb_build_object('input_kind',s.kind),null);
 update bot_messages set created_at=least(created_at,j.created_at) where id=(saved->>'id')::uuid and job_id=p_job;
 update bot_session_inputs set message_id=(saved->>'id')::uuid,finished_at=now() where job_id=p_job;
 if action='unintelligible' then
  insert into bot_outbox(chat_id,actor_id,thread_id,dedupe_key,body) values(j.actor_id,j.actor_id,s.thread_id,'retry-input:'||p_job,
   jsonb_build_object('text','Не удалось разобрать сообщение. Ответьте на исходный вопрос ещё раз текстом или запишите голосовое в более тихом месте.')) on conflict(dedupe_key) do nothing;
 end if;
 return (saved->>'id')::uuid;
end $$;
revoke all on function public.bot_session_enqueue(bigint,uuid,bigint),public.bot_session_claim(uuid),public.bot_session_audio_ref(bigint,uuid),public.bot_session_finish(bigint,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bot_session_enqueue(bigint,uuid,bigint),public.bot_session_claim(uuid),public.bot_session_audio_ref(bigint,uuid),public.bot_session_finish(bigint,uuid,text,jsonb) to service_role;
