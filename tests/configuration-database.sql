begin;
insert into app_companies(slug,name) values('__config_a','A'),('__config_b','B');
insert into app_users(tg_id,name,role,company_id)
select n,role,role,c.id from (values (98501,'owner','__config_a'),(98502,'manager','__config_a'),
 (98503,'supplier','__config_a'),(98504,'admin','__config_b')) users(n,role,slug)
join app_companies c on c.slug=users.slug;
set local role service_role;
do $$
declare s jsonb; ops jsonb; outsider jsonb; saved jsonb; r jsonb; old_reason jsonb; req uuid; o jsonb; offer jsonb;
 price jsonb; bad jsonb; event_id bigint; previous_attempt integer; jobs jsonb;
begin
 s:=crm_backend(98501,'settings.get')->'settings';
 ops:=s->'operations'||'{"offer_note":"Версия один","supplier_instruction":"Укажите стоимость доставки отдельно.","loss_reasons":["Срок поставки","Другое"],"muted_events":[]}'::jsonb;
 outsider:=crm_backend(98504,'settings.get')->'settings';
 begin perform crm_backend(98502,'settings.save',s);raise exception 'manager edited configuration';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 begin perform crm_backend(98503,'settings.get');raise exception 'supplier read configuration';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 foreach bad in array array['{"loss_reasons":["Тест","тест","Другое"]}'::jsonb,'{"loss_reasons":["Тест"]}','{"muted_events":["unknown"]}','{"active_sources":[{}]}','{"supplier_instruction":"Пишите @supplier"}','{"offer_note":false}'] loop
  begin perform crm_backend(98501,'settings.save',s||jsonb_build_object('operations',ops||bad));raise exception 'invalid configuration saved';exception when raise_exception then if sqlerrm<>'backend_bad_settings' then raise;end if;end;
 end loop;
 saved:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',ops))->'settings';
 begin perform crm_backend(98501,'settings.save',s);raise exception 'stale configuration saved';exception when raise_exception then if sqlerrm<>'crm_conflict' then raise;end if;end;
 s:=crm_backend(98501,'settings.save',saved-'operations')->'settings';
 assert s->'operations'=ops and (crm_backend(98504,'settings.get')->'settings')=outsider;
 assert crm_list_requests(98502)->'loss_reasons'=ops->'loss_reasons';
 r:=crm_save_request(98501,null,0,'{"assigned_to":98502,"client_name":"Клиент","phone":"79991110000","model":"Тест","budget":2000,"consent_at":"2026-11-25T10:00:00Z"}');
 req:=(r->>'id')::uuid;
 select id into strict event_id from crm_activity where request_id=req and kind='created';
 assert bot_event_can_deliver(event_id,98502);
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',ops||'{"muted_events":["assignment"]}'))->'settings';
 assert not bot_event_can_deliver(event_id,98502);
 r:=crm_save_request(98502,req,(r->>'version')::int,'{"status":"lost","reasons":["Срок поставки"]}');
 ops:=s->'operations'||'{"loss_reasons":["Нет нужной модели","Другое"]}'::jsonb;
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',ops))->'settings';
 old_reason:=crm_save_request(98502,req,(r->>'version')::int,'{"note":"Старый выбор сохранён"}');
 assert old_reason->'reasons'='["Срок поставки"]'::jsonb;
 r:=crm_save_request(98502,req,(old_reason->>'version')::int,'{"status":"search"}');
 begin perform crm_save_request(98502,req,(r->>'version')::int,'{"status":"lost","reasons":["Срок поставки"]}');raise exception 'retired reason accepted';exception when raise_exception then if sqlerrm<>'crm_reason_unknown' then raise;end if;end;

 price:=jsonb_build_object('request_id',req,'title','Тест','scenario','rf','currency','RUB','input','{"purchase":10000}'::jsonb,'client_price',10299.99,'market_median',10000);
 o:=crm_backend(98502,'option.save',price);
 assert (o->'evaluation'->>'needs_approval')::boolean;
 o:=crm_backend(98502,'option.save',price||'{"client_price":10300}');
 assert (o->'evaluation'->>'can_send')::boolean;
 offer:=crm_backend(98502,'offer.create',jsonb_build_object('request_id',req,'option_ids',jsonb_build_array(o->'option'->'id')))->'offer';
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',ops||'{"offer_note":"Версия два"}'))->'settings';
 assert crm_backend(98502,'offer.get',jsonb_build_object('id',offer->>'id'))->'offer'->'model'->>'offerNote'='Версия один';
 assert crm_backend(98502,'offer.create',jsonb_build_object('request_id',req,'option_ids',jsonb_build_array(o->'option'->'id')))->'offer'->'model'->>'offerNote'='Версия два';
 price:=price||'{"scenario":"import","currency":"JPY","client_price":20000}';
 begin perform crm_backend(98502,'option.save',price);raise exception 'missing import rate accepted';exception when raise_exception then if sqlerrm<>'backend_bad_data' then raise;end if;end;
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('exchange',s->'exchange'||'{"mode":"fixed","fixed":0.55}'))->'settings';
 o:=crm_backend(98502,'option.save',price);
 assert (o->'option'->>'total_cost')::numeric=5500;
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('exchange',s->'exchange'||'{"mode":"percent","fixed_rates":{"JPY":0.65}}'))->'settings';
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('exchange',(s->'exchange')-'fixed_rates'))->'settings';
 o:=crm_backend(98502,'option.save',price);
 assert (o->'option'->>'total_cost')::numeric=6500 and o->'option'->'calculation'->>'rate_source'='company';
 begin perform crm_backend(98502,'option.save',price||'{"currency":"CNY"}');raise exception 'JPY rate used for CNY';exception when raise_exception then if sqlerrm<>'backend_bad_data' then raise;end if;end;
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('exchange',s->'exchange'||'{"fixed_rates":{}}'))->'settings';
 begin perform crm_backend(98502,'option.save',price);raise exception 'removed JPY rate used';exception when raise_exception then if sqlerrm<>'backend_bad_data' then raise;end if;end;

 insert into bot_request_specs(request_id,company_id,brand,model_at_selection) values(req,(r->>'company_id')::uuid,'test','Тест');
 perform workflow_claim_sources();
 select attempt into strict previous_attempt from search_sources where request_id=req and source='market' and state='running';
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',s->'operations'||'{"active_sources":["stock"]}'))->'settings';
 assert not exists(select 1 from workflow_claim_sources() j where j->>'request_id'=req::text and j->>'source'='market');
 assert exists(select 1 from search_sources where request_id=req and source='market' and attempt>previous_attempt and state='pending');
 s:=crm_backend(98501,'settings.save',s||jsonb_build_object('operations',s->'operations'||'{"active_sources":["stock","market"]}'))->'settings';
 assert exists(select 1 from workflow_claim_sources() j where j->>'request_id'=req::text and j->>'source'='market');
end $$;
select 'PASS company rules, access, revisions, historical reasons and offers, exact margin cutoff, import rates, pending notifications and source leases' as result;
rollback;
