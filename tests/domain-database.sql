begin;
insert into public.app_companies(slug,name) values ('__domain_a','Domain A'),('__domain_b','Domain B');
insert into public.app_users(tg_id,name,role,active,company_id) values
(-90201,'Domain manager','manager',true,(select id from public.app_companies where slug='__domain_a')),
(-90202,'Domain owner','owner',true,(select id from public.app_companies where slug='__domain_a')),
(-90203,'Other owner','owner',true,(select id from public.app_companies where slug='__domain_b')),
(-90204,'Second manager','manager',true,(select id from public.app_companies where slug='__domain_a'));
set local role service_role;
do $$
declare r jsonb; opt jsonb; approved jsonb; offer1 jsonb; offer2 jsonb; rid uuid; oid uuid; settings jsonb; input jsonb; data jsonb; sent_version integer;
begin
 r:=public.crm_save_request(-90201,null,0,'{"client_name":"Backend client","phone":"79990000301","model":"Backend car","budget":1800000,"consent_at":"2026-11-16T10:00:00Z"}');rid:=(r->>'id')::uuid;
 input:='{"purchase":1000000,"logistics":50000,"commission":50000,"duty":0,"recycling":0,"documents":0,"base_rate":1}';
 data:=jsonb_build_object('request_id',rid,'title','Car variant','scenario','rf','currency','RUB','input',input,'client_price',1099999,'market_median',1500000,'description','Автомобиль, +7 999 000 00 00','term','Под заказ');
 begin perform public.crm_backend(-90201,'option.save',data);raise exception 'floor bypass';exception when raise_exception then if sqlerrm<>'backend_price_below_cost' then raise;end if;end;
 data:=data||'{"client_price":1120000}';opt:=public.crm_backend(-90201,'option.save',data);oid:=(opt->'option'->>'id')::uuid;
 if (opt->'option'->>'total_cost')::numeric<>1100000 then raise exception 'wrong RF cost';end if;
 if (opt->'evaluation'->>'can_send')::boolean then raise exception 'unapproved option can send';end if;
 begin perform public.crm_backend(-90201,'offer.create',jsonb_build_object('request_id',rid,'option_ids',jsonb_build_array(oid)));raise exception 'approval bypass';exception when raise_exception then if sqlerrm<>'backend_approval_required' then raise;end if;end;
 begin perform public.crm_backend(-90201,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',1,'decision','approved'));raise exception 'manager approves price';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 perform public.crm_backend(-90201,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',1,'decision','requested'));
 approved:=public.crm_backend(-90202,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',2,'decision','approved'));
 if not (approved->'evaluation'->>'can_send')::boolean then raise exception 'approval ignored';end if;
 offer1:=public.crm_backend(-90201,'offer.create',jsonb_build_object('request_id',rid,'option_ids',jsonb_build_array(oid)));
 if offer1->'offer'->'model'->'cars'->0->>'description' like '%999%' then raise exception 'contacts leaked';end if;
 data:=data||jsonb_build_object('id',oid,'version',3,'client_price',1130000);
 opt:=public.crm_backend(-90201,'option.save',data);
 if opt->'option'->>'approval'<>'none' then raise exception 'approval survived changed calculation';end if;
 begin perform public.crm_backend(-90201,'offer.sent',jsonb_build_object('id',offer1->'offer'->>'id'));raise exception 'stale offer sent';exception when raise_exception then if sqlerrm<>'backend_offer_stale' then raise;end if;end;
 if (select model->'cars'->0->>'price' from public.request_offers where id=(offer1->'offer'->>'id')::uuid)<>'1120000' then raise exception 'snapshot changed';end if;
 approved:=public.crm_backend(-90202,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',4,'decision','approved'));
 offer2:=public.crm_backend(-90201,'offer.create',jsonb_build_object('request_id',rid,'option_ids',jsonb_build_array(oid)));
 perform public.crm_backend(-90201,'offer.sent',jsonb_build_object('id',offer2->'offer'->>'id'));
 select version into sent_version from public.crm_requests where id=rid;
 perform public.crm_backend(-90201,'offer.sent',jsonb_build_object('id',offer2->'offer'->>'id'));
 if (select version from public.crm_requests where id=rid)<>sent_version then raise exception 'sent not idempotent';end if;
 if (select status from public.crm_requests where id=rid)<>'think' then raise exception 'status not changed on sent';end if;
 settings:=public.crm_backend(-90202,'settings.get')->'settings';
 begin perform public.crm_backend(-90201,'settings.save',settings);raise exception 'manager edits settings';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 settings:=settings||jsonb_build_object('pricing',settings->'pricing'||'{"margin_pct":99}');
 perform public.crm_backend(-90202,'settings.save',settings);
 begin perform public.crm_backend(-90202,'settings.save',settings);raise exception 'settings stale version accepted';exception when raise_exception then if sqlerrm<>'crm_conflict' then raise;end if;end;
 begin perform public.crm_backend(-90201,'offer.create',jsonb_build_object('request_id',rid,'option_ids',jsonb_build_array(oid)));raise exception 'changed rules did not invalidate approval';exception when raise_exception then if sqlerrm<>'backend_approval_required' then raise;end if;end;
 begin perform public.crm_backend(-90203,'request.get',jsonb_build_object('request_id',rid));raise exception 'company leak';exception when raise_exception then if sqlerrm<>'crm_not_found' then raise;end if;end;
 begin perform public.crm_backend(-90204,'request.get',jsonb_build_object('request_id',rid));raise exception 'unassigned manager leak';exception when raise_exception then if sqlerrm<>'crm_not_found' then raise;end if;end;
 data:=jsonb_build_object('request_id',rid,'title','Import variant','scenario','import','currency','USD','input','{"purchase":10000,"base_rate":100,"logistics":50000,"commission":30000,"duty":200000,"recycling":100000,"documents":20000}'::jsonb,'client_price',1600000,'market_median',1700000);
 opt:=public.crm_backend(-90201,'option.save',data);
 if (opt->'option'->>'total_cost')::numeric<>1420000 then raise exception 'import cost wrong';end if;
 if (opt->'option'->'calculation'->>'effective_rate')::numeric<>102 then raise exception 'exchange snapshot wrong';end if;

 settings:=public.crm_backend(-90202,'settings.get')->'settings';
 settings:=settings||jsonb_build_object('pricing',settings->'pricing'||'{"median_enabled":false,"margin_enabled":false}');
 perform public.crm_backend(-90202,'settings.save',settings);
 oid:=(opt->'option'->>'id')::uuid;
 approved:=public.crm_backend(-90202,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',1,'decision','rejected'));
 if (approved->'evaluation'->>'can_send')::boolean then raise exception 'rejected normal price was sendable';end if;
 approved:=public.crm_backend(-90201,'option.review',jsonb_build_object('request_id',rid,'id',oid,'version',2,'decision','requested'));
 if (approved->'evaluation'->>'can_send')::boolean then raise exception 'pending normal price was sendable';end if;
 begin perform public.crm_backend(-90201,'asset.save','{"name":"test.pdf","content_type":"application/pdf","data_url":"data:application/pdf;base64,JVBERi0xLjQK"}');raise exception 'manager uploaded dealer asset';exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise;end if;end;
 opt:=public.crm_backend(-90202,'asset.save','{"name":"test.pdf","content_type":"application/pdf","data_url":"data:application/pdf;base64,JVBERi0xLjQK"}');
 begin perform public.crm_backend(-90203,'asset.get',jsonb_build_object('id',opt->'asset'->>'id'));raise exception 'asset company leak';exception when raise_exception then if sqlerrm<>'crm_not_found' then raise;end if;end;
end $$;
select 'PASS server cost calculation, price floor, owner-only approval, immutable offers, stale offer checks, sent idempotency, shared settings CAS and access scopes' as verification;

rollback;
