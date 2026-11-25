begin;
insert into app_companies(slug,name) values('__wf','Dealer'),('__wf_ext','Other dealer');
insert into app_users(tg_id,name,role,company_id)
select id,n,role,(select id from app_companies where slug=g) from (values
 (81101,'Manager','manager','__wf'),(81102,'Owner','owner','__wf'),(81103,'Outside','owner','__wf_ext'),
 (81104,'First','supplier','__wf'),(81105,'Second','supplier','__wf_ext'),(81106,'Third','supplier','__wf'),
 (81107,'Other manager','manager','__wf')) v(id,n,role,g);
set local role service_role;
do $$
declare lead jsonb:='{"model":"Fixturebrand Camry","client_name":"Private Client","phone":"79991234567","budget":3000000,"generation":"XV70","years":"2022","consent_at":"2026-10-10T10:00:00Z"}';
 search jsonb:='{"brand":"","color":"белый","trim":"Prestige"}';
 tariff jsonb:='{"id":"81104","revision":0,"currency":"JPY","enabled":true,"brands":["Fixturebrand"],"fees":{"logistics":50000,"commission":10000,"duty":200000,"recycling":100000,"documents":5000}}';
 draft jsonb:='{"title":"Camry 2022","scenario":"import","currency":"JPY","input":{"purchase":1000000,"base_rate":0.5,"logistics":50000,"commission":10000,"duty":200000,"recycling":100000,"documents":5000},"client_price":1050000,"market_median":1050000,"term":"45 дней"}';
 a jsonb; msg uuid; oid uuid; img uuid; img2 uuid; rid uuid; th uuid; other uuid; offer jsonb; token uuid:=gen_random_uuid(); source jsonb; external text; photo uuid; result jsonb;
begin
 perform crm_workflow(81102,'terms.save',tariff);
 perform crm_workflow(81103,'terms.save',tariff||'{"id":"81105"}');
 perform crm_workflow(81102,'terms.save',tariff||'{"id":"81106","brands":["Kia"]}');
 select value->>'id' into external from jsonb_array_elements(crm_workflow(81102,'network','{}')->'suppliers') where not (value->>'owned')::boolean and (value->'brands') ? 'fixturebrand';
 if external is null or external='81105' then raise exception 'External directory leaked identity';end if;
 perform crm_workflow(81102,'terms.save',tariff||jsonb_build_object('id',external,'fees',(tariff->'fees')||'{"logistics":100000}'));
 begin perform crm_workflow(81101,'network','{}');raise exception 'manager edited network';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 a:=workflow_create(81101,token,lead,search);rid:=(a->'request'->>'id')::uuid;
 if a->>'queued'<>'2' or (workflow_create(81101,token,lead,search)->'request'->>'id')::uuid<>rid then raise exception 'request create/dedup';end if;
 if workflow_dispatch(81101,rid,'fixturebrand','','')<>0 then raise exception 'duplicated supplier';end if;
 if (select count(*) from search_sources where request_id=rid)<>2 then raise exception 'parallel searches missing';end if;
 if exists(select 1 from bot_outbox b join bot_threads t on t.id=b.thread_id where t.request_id=rid and (b.body::text like '%Private Client%' or b.body::text like '%9991234567%' or b.body::text like '%3000000%'))then raise exception 'private data forwarded';end if;
 select id into th from bot_threads where request_id=rid and supplier_id=81104;
 select id into other from bot_threads where request_id=rid and supplier_id=81105;
 update bot_outbox set state='sent' where thread_id in(th,other);
 update bot_outbox set delivered_at=now()-interval '7 hours' where thread_id in(th,other);
 perform workflow_queue_due();perform workflow_queue_due();
 if (select count(*) from bot_outbox where thread_id=th and reminder is not null)<>2 then raise exception 'reminder dedup'; end if;
 insert into bot_jobs(id,actor_id,payload) values(801,81104,'{}'),(802,81104,'{}'),(803,81105,'{}');
 a:=workflow_receive(81104,th,801,'album1','','{}','/9j/AAAA');msg:=(a->>'id')::uuid;
 a:=workflow_receive(81104,th,802,'album1','Camry 2022','{"model":"Camry","years":"2022","purchase":1000000,"currency":"JPY"}','/9j/AAAA');
 perform workflow_receive(81104,th,802,'album1','Camry 2022','{}','/9j/AAAA');
 if (a->>'id')::uuid<>msg or (select count(*) from supplier_photos where message_id=msg)<>2 then raise exception 'album duplicates'; end if;
 if exists(select 1 from workflow_due where thread_id=th) then raise exception 'stale reminders after reply';end if;
 if (select count(*) from workflow_due where thread_id=other)<>2 then raise exception 'second supplier still pending';end if;
 select id into img from supplier_photos where job_id=801;
 a:=crm_workflow(81101,'inbox',jsonb_build_object('request_id',rid));
 if jsonb_array_length(a->'threads')<>2 or a::text not like '%Camry 2022%' then raise exception 'missing inbox'; end if;
 begin perform crm_workflow(81103,'photo',jsonb_build_object('request_id',rid,'id',img));raise exception 'cross-company photo';exception when raise_exception then if sqlerrm<>'crm_not_found' then raise;end if;end;
 begin perform crm_workflow(81107,'inbox',jsonb_build_object('request_id',rid));raise exception 'wrong manager';exception when raise_exception then if sqlerrm<>'crm_not_found' then raise;end if;end;
 a:=jsonb_build_object('request_id',rid,'thread_id',th,'text','Какой срок поставки?','token',gen_random_uuid());
 perform crm_workflow(81101,'reply',a);perform crm_workflow(81101,'reply',a);
 if (select count(*) from bot_messages where thread_id=th and sanitized_text='Какой срок поставки?')<>1 then raise exception 'reply retry'; end if;
 a:=jsonb_build_object('request_id',rid,'message_id',msg,'terms_revision',1,'photos',jsonb_build_array(img),'option',draft);
 result:=crm_workflow(81101,'option.fromReply',a);oid:=(result->>'id')::uuid;
 if (select total_cost from request_options where id=oid)<>875000 then raise exception 'wrong supplier calculation'; end if;
 begin perform crm_workflow(81101,'option.fromReply',a);raise exception 'duplicate option';exception when raise_exception then if sqlerrm<>'crm_conflict' then raise;end if;end;
 offer:=crm_backend(81101,'offer.create',jsonb_build_object('request_id',rid,'option_ids',jsonb_build_array(oid)))->'offer';
 if offer->'model'->'cars'->0->'photo_ids'<>jsonb_build_array(img) or offer->'model' is null then raise exception 'offer photos';end if;
 perform crm_workflow(81102,'terms.save',tariff||jsonb_build_object('revision',1,'fees',(tariff->'fees')||'{"logistics":90000}'));
 if (select total_cost from request_options where id=oid)<>875000 then raise exception 'tariff rewrote snapshot';end if;
 perform crm_backend(81101,'offer.sent',jsonb_build_object('id',offer->>'id'));
 a:=workflow_receive(81105,other,803,null,'Второй вариант','{}',null);
 result:=crm_workflow(81101,'option.fromReply',jsonb_build_object('request_id',rid,'message_id',a->>'id','terms_revision',1,'photos','[]'::jsonb,
  'option',draft||jsonb_build_object('input',(draft->'input')||'{"logistics":100000}')));
 if (select total_cost from request_options where id=(result->>'id')::uuid)<>925000 then raise exception 'second supplier tariff'; end if;
 select id into img2 from supplier_photos where job_id=802;
 perform crm_workflow(81101,'option.fromReply',jsonb_build_object('request_id',rid,'message_id',msg,'terms_revision',1,'photos',jsonb_build_array(img2),
   'option',draft||jsonb_build_object('id',oid,'version',1)));
 if (select model->'cars'->0->'photo_ids' from request_offers where id=(offer->>'id')::uuid)<>jsonb_build_array(img) then raise exception 'old PDF photos changed'; end if;
 perform crm_workflow(81101,'listing.save',jsonb_build_object('request_id',rid,'url','https://example.org/camry','title','Camry','purchase',1000000));
 if crm_workflow(81101,'inbox',jsonb_build_object('request_id',rid))->'listings'->0->>'title'<>'Camry' then raise exception 'listing lost'; end if;
 if not exists(select 1 from crm_requests where id=rid and status='think' and next_contact_at>=now()+interval '1 day') then raise exception 'feedback date missing';end if;
 update crm_requests set next_contact_at=now()-interval '1 hour' where id=rid;
 perform workflow_queue_due();perform workflow_queue_due();
 if (select count(*) from bot_outbox where request_id=rid and reminder='feedback')<>1 then raise exception 'feedback reminder dedup';end if;
 perform crm_log_contact(81101,rid,(select version from crm_requests where id=rid),gen_random_uuid(),'connected','Заказ оформлен','{"status":"won"}');
 if exists(select 1 from workflow_due where request_id=rid) then raise exception 'closed request still due';end if;
end $$;
select 'PASS request retry, brand matching, parallel sources, privacy, photos and album dedup, terms, partial offer, reminder dedup and client outcome' as result;
rollback;
