begin;
insert into public.app_companies(slug,name) values ('__crm_verify_a','CRM verification A'),('__crm_verify_b','CRM verification B');
insert into public.app_users(tg_id,name,role,active,company_id) values
(-90101,'Test manager 1','manager',true,(select id from public.app_companies where slug='__crm_verify_a')),
(-90102,'Test manager 2','manager',true,(select id from public.app_companies where slug='__crm_verify_a')),
(-90103,'Test owner','owner',true,(select id from public.app_companies where slug='__crm_verify_a')),
(-90104,'Other owner','owner',true,(select id from public.app_companies where slug='__crm_verify_b'));
set local role service_role;
do $$
declare r jsonb; changed jsonb; found boolean; rid uuid;
begin
 r:=public.crm_save_request(-90101,null,0,'{"client_name":"Test client","phone":"79990000101","model":"Test car","budget":4000000,"consent_at":"2026-11-13T10:00:00Z"}'); rid:=(r->>'id')::uuid;
 if r->>'assigned_to'<>'-90101' then raise exception 'wrong initial assignee'; end if;
 if (public.crm_list_requests(-90102)->>'total')::integer<>0 then raise exception 'manager sees someone else'; end if;
 if (public.crm_list_requests(-90103)->>'total')::integer<>1 then raise exception 'owner cannot see company requests'; end if;
 if (public.crm_list_requests(-90104)->>'total')::integer<>0 then raise exception 'cross company leak'; end if;
 begin perform public.crm_request_detail(-90104,rid); raise exception 'unexpected cross company access'; exception when raise_exception then if sqlerrm<>'crm_not_found' then raise; end if; end;
 begin perform public.crm_save_request(-90101,rid,1,'{"assigned_to":-90102}'); raise exception 'manager can reassign'; exception when raise_exception then if sqlerrm<>'crm_forbidden' then raise; end if; end;
 begin perform public.crm_save_request(-90101,rid,1,'{"status":"lost","reasons":[]}'); raise exception 'no reason check'; exception when raise_exception then if sqlerrm<>'crm_reason_required' then raise; end if; end;
 begin perform public.crm_save_request(-90101,rid,1,'{"status":"lost","reasons":["Другое"],"note":""}'); raise exception 'no comment check'; exception when raise_exception then if sqlerrm<>'crm_comment_required' then raise; end if; end;
 changed:=public.crm_save_request(-90103,rid,1,'{"assigned_to":-90102,"status":"think"}');
 begin perform public.crm_save_request(-90103,rid,1,'{"status":"won"}'); raise exception 'stale update accepted'; exception when raise_exception then if sqlerrm<>'crm_conflict' then raise; end if; end;
 begin perform public.crm_request_detail(-90101,rid); raise exception 'old assignee has access'; exception when raise_exception then if sqlerrm<>'crm_not_found' then raise; end if; end;
 perform public.crm_add_comment(-90102,rid,'Test note');
 r:=public.crm_request_detail(-90102,rid);
 if jsonb_array_length(r->'activity')<>3 then raise exception 'missing audit entries'; end if;
 changed:=public.crm_save_request(-90103,rid,2,'{"archived":true}');
 if (public.crm_list_requests(-90103)->>'total')::integer<>0 then raise exception 'archive did not hide request'; end if;
 if (public.crm_list_requests(-90103,'','','',true)->>'total')::integer<>1 then raise exception 'archive missing request'; end if;
end $$;
insert into public.user_workspaces(user_id,source_company_id,state) values (-90101,(select company_id from public.app_users where tg_id=-90101),'{"version":1,"requests":[{"key":"local-import-test","custom":true,"title":"Legacy car","budget":3000000}],"clients":{"local-import-test":{"name":"Legacy client","phone":"79990000201","consentAt":"2026-11-13T10:00:00Z","status":"search","reasons":[]}}}');
update public.app_users set active=false where tg_id=-90101;
do $$
begin
 if public.crm_import_company(-90103)<>1 then raise exception 'legacy import failed'; end if;
 if public.crm_import_company(-90103)<>0 then raise exception 'legacy import was not idempotent'; end if;
 if not exists(select 1 from public.user_workspaces where user_id=-90101 and legacy_backup is not null) then raise exception 'legacy backup missing'; end if;
end $$;
update public.app_users set company_id=(select id from public.app_companies where slug='__crm_verify_b') where tg_id=-90101;
do $$
begin
 if public.crm_import_workspace(-90101)<>0 then raise exception 'old company data copied to a new company'; end if;
end $$;
select 'PASS company isolation, manager scope, reassignment, status validation, version conflicts, audit comments, archive, legacy backup and idempotent import' as verification;
rollback;
