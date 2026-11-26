-- Disposable database. Check both release paths using isolated Telegram identities.
begin;
insert into app_companies(slug,name) values('__reading','Reading fixture');
insert into bot_session_companies select id from app_companies where slug='__reading';
insert into app_users(tg_id,name,role,company_id)
select who,n,role,c.id from (values (84531,'Manager','manager'),(84532,'Supplier','supplier'),(84533,'Other','manager')) f(who,n,role)
cross join app_companies c where c.slug='__reading';
set local role service_role;
do $$
declare co uuid; rid uuid; th uuid; item jsonb; rev uuid; old uuid; fields jsonb; actor bigint; x integer; raw text; result uuid;
begin
 select id into co from app_companies where slug='__reading';
 insert into crm_requests(company_id,created_by,assigned_to,client_name,phone,model,budget,consent_at)
 values(co,84531,84531,'Fixture','70000000000','Toyota Camry',3000000,now()) returning id into rid;
 insert into bot_threads(company_id,request_id,supplier_id) values(co,rid,84532) returning id into th;
 for x in 87101..87114 loop
  actor:=case when x<=87106 then 84531 else 84532 end;
  raw:=case x when 87101 then 'Хочу XC90 до трёх миллионов' when 87103 then 'до трёх с половиной, серую, с полным приводом'
   when 87107 then 'Есть за два миллиона четыреста пятьдесят, доставка отдельно, пятьдесят тысяч рублей'
   when 87109 then 'Исправьте только доставку, сорок тысяч' else 'fixture' end;
  insert into bot_jobs(id,actor_id,payload) values(x,actor,jsonb_build_object('message',jsonb_build_object('text',raw,'from',jsonb_build_object('id',actor),'chat',jsonb_build_object('type','private','id',actor),'message_id',x)));
 end loop;
 perform bot_read_start(84531,87101,null,true,false,'{}',null);
 assert bot_read_claim(gen_random_uuid()) is null;
 item:=bot_read_claim(co);assert item->>'task'='lead' and item->>'source' like '%XC90%';
 fields:='{"brand":"Volvo","model":"XC90","budget":3000000,"filters":{"year_from":2021}}';
 old:=bot_read_finish(87101,(item->>'lease')::uuid,'',fields);
 perform bot_read_decide(84531,87102,old,'edit');
 perform bot_read_start(84531,87103,null,false,false,'{}',null);
 item:=bot_read_claim(co);assert item->'previous'=fields and item->>'corrections' like '%полным приводом%';
 fields:=fields||'{"phone":"80000000001","client_name":"Иван","budget":3500000,"filters":{"year_from":2021,"drive":"Полный","color":"Серый"},"spec":"Без дизеля"}';
 rev:=bot_read_finish(87103,(item->>'lease')::uuid,'',fields);
 assert (select body->>'text' from bot_outbox where dedupe_key='reading:preview:87103') like '%Привод: Полный%';
 perform bot_read_decide(84531,87104,old,'yes');assert not exists(select 1 from bot_intakes where user_id=84531);
 begin perform bot_read_decide(84533,87104,rev,'yes');raise exception 'foreign draft';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 perform bot_read_decide(84531,87105,rev,'yes');
 assert (select bot_intakes.fields->>'phone' from bot_intakes where user_id=84531)='70000000001';
 assert (select count(*) from crm_requests where company_id=co)=1;
 perform bot_intake(84531,87106,'confirm',jsonb_build_object('previous',(select revision from bot_intakes where user_id=84531),'desk','https://example.test/'));
 assert exists(select 1 from crm_requests where company_id=co and client_name='Иван' and budget=3500000 and spec like '%Без дизеля%');
 perform bot_read_start(84532,87107,th,false,false,'{}',null);
 item:=bot_read_claim(co);assert item->>'task'='supplier';
 fields:='{"kind":"quote","purchase":2450000,"currency":"RUB","logistics":50000}';
 old:=bot_read_finish(87107,(item->>'lease')::uuid,'Цена 2450000 рублей, доставка отдельно.',fields);
 perform bot_read_decide(84532,87108,old,'edit');
 perform bot_read_start(84532,87109,th,false,false,'{}',null);
 item:=bot_read_claim(co);assert item->'previous'=fields and item->>'corrections' like '%сорок тысяч%';
 rev:=bot_read_finish(87109,(item->>'lease')::uuid,'Цена 2450000 рублей, доставка 40000 рублей.',fields||'{"logistics":40000}');
 perform bot_read_decide(84532,87110,old,'yes');
 assert not exists(select 1 from bot_messages where thread_id=th and actor_id=84532);
 perform bot_read_decide(84532,87111,rev,'yes');perform bot_read_decide(84532,87111,rev,'yes');
 assert (select count(*) from bot_messages where thread_id=th and actor_id=84532)=1;
 assert (select parsed->>'logistics' from bot_messages where thread_id=th and actor_id=84532)='40000';
 perform bot_read_start(84532,87112,th,false,false,'{}',null);
 item:=bot_read_claim(co);rev:=bot_read_finish(87112,(item->>'lease')::uuid,'Да, входит.','{"kind":"clarification"}');
 perform bot_read_decide(84532,87113,rev,'no');perform bot_read_decide(84532,87114,rev,'yes');
 assert (select count(*) from bot_messages where thread_id=th and actor_id=84532)=1;
 assert not has_function_privilege('authenticated','public.bot_read_claim(uuid)','execute');
 assert not has_table_privilege('anon','public.bot_readings','select');
end $$;
rollback;
