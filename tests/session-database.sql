-- Run against an isolated database with schema through session.sql.
begin;
insert into app_companies(slug,name) values('__session','Fixture');
insert into bot_session_companies select id from app_companies where slug='__session';
insert into app_users(tg_id,name,role,company_id)
select who,n,role,c.id from (values (84501,'Manager','manager'),(84502,'Supplier','supplier')) f(who,n,role)
cross join app_companies c where c.slug='__session';
set local role service_role;
do $$
declare co uuid; rid uuid; th uuid; sent uuid; ticket uuid; next_ticket uuid; claim jsonb; inbox jsonb; result uuid; msg jsonb; item jsonb;
begin
 select id into co from app_companies where slug='__session';
 insert into crm_requests(company_id,created_by,assigned_to,client_name,phone,model,budget,consent_at)
 values(co,84501,84501,'Fixture','79990000000','Toyota',2450000,now()) returning id into rid;
 insert into bot_threads(company_id,request_id,supplier_id) values(co,rid,84502) returning id into th;
 assert bot_session_only_thread(84502)=th;
 insert into bot_messages(thread_id,actor_id,sanitized_text) values(th,84501,'Доставка входит в 2 450 000 ₽?') returning id into sent;
 insert into bot_outbox(thread_id,message_id,chat_id,actor_id,state,telegram_message_id,body) values(th,sent,84502,84501,'sent',500,'{}');
 msg:='{"chat":{"id":84502,"type":"private"},"from":{"id":84502},"message_id":501,"reply_to_message":{"message_id":500},"voice":{"duration":8,"file_id":"fixture-voice"}}';
 insert into bot_jobs(id,actor_id,payload) values(87001,84502,jsonb_build_object('message',msg));
 assert bot_session_enqueue(84502,th,87001);
 assert bot_session_enqueue(84502,th,87001);
 assert bot_session_claim(gen_random_uuid()) is null;
 claim:=bot_session_claim(co);
 assert claim->>'kind'='voice' and claim->>'question'='Доставка входит в 2 450 000 ₽?';
 ticket:=(claim->>'lease')::uuid;
 assert bot_session_claim(co) is null;
 assert bot_session_audio_ref(87001,gen_random_uuid()) is null;
 assert bot_session_audio_ref(87001,ticket)='fixture-voice';
 update bot_session_inputs set retry_at=now()-interval '1 second' where job_id=87001;
 next_ticket:=(bot_session_claim(co)->>'lease')::uuid;
 assert next_ticket<>ticket and bot_session_audio_ref(87001,ticket) is null;
 begin
  perform bot_session_finish(87001,next_ticket,'Да, входит.','{"kind":"clarification","purchase":2450000}');
  raise exception 'clarification became quote';
 exception when raise_exception then if sqlerrm<>'invalid_fact' then raise; end if; end;
 result:=bot_session_finish(87001,next_ticket,'Да, доставка входит.','{"kind":"clarification"}');
 assert bot_session_finish(87001,next_ticket,'Да, доставка входит.','{"kind":"clarification"}')=result;
 assert bot_session_audio_ref(87001,next_ticket) is null;
 inbox:=crm_workflow(84501,'inbox',jsonb_build_object('request_id',rid));
 select m into item from jsonb_array_elements(inbox->'threads'->0->'messages') m where m->>'id'=result::text;
 assert item->>'text'='Да, доставка входит.' and item->>'incoming'='true' and item#>>'{parsed,input_kind}'='voice' and not(item->'parsed'?'purchase');
 assert (select count(*)=1 from bot_outbox where dedupe_key='received:'||result);
 insert into bot_jobs(id,actor_id,payload) values(87002,84502,jsonb_build_object('message',(msg-'voice')||'{"message_id":502,"text":"Есть белая машина за 1900000 рублей"}'));
 assert bot_session_enqueue(84502,th,87002);
 claim:=bot_session_claim(co);
 assert claim->>'text'='Есть белая машина за 1900000 рублей' and claim->>'kind'='text';
 result:=bot_session_finish(87002,(claim->>'lease')::uuid,'Белая машина за 1 900 000 рублей.','{"kind":"quote","purchase":1900000,"currency":"RUB","color":"Белый"}');
 assert (select parsed->>'purchase'='1900000' and thread_id=th and option_id is null from bot_messages where id=result);
 assert not has_function_privilege('anon','bot_session_claim(uuid)','execute');
 assert not has_function_privilege('authenticated','bot_session_audio_ref(bigint,uuid)','execute');
end $$;
rollback;
