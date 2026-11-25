-- After workflow.sql. Only new CRM events enqueue messages.
alter table public.bot_outbox add column if not exists activity_id bigint references public.crm_activity(id);
create index if not exists bot_outbox_activity on public.bot_outbox(activity_id) where activity_id is not null;

create or replace function public.bot_event_recipients(p_activity bigint)
returns table(recipient bigint) language sql stable security invoker set search_path=public,pg_temp as $$
 select u.tg_id from crm_activity e
 join crm_requests r on r.id=e.request_id and r.company_id=e.company_id and r.archived_at is null
 join app_users u on u.company_id=e.company_id and u.active and u.role in ('manager','owner','admin')
 left join request_options o on o.id::text=e.data->>'option_id' and o.request_id=r.id and not o.archived
 where e.id=p_activity
 and not exists(select 1 from crm_activity later where later.request_id=r.id and later.id>e.id and (
  (e.kind like 'price.%' and later.kind like 'price.%' and later.data->>'option_id'=e.data->>'option_id') or
  (e.kind in ('created','updated') and later.kind='updated' and later.data->>'from_assigned_to' is distinct from later.data->>'assigned_to')))
 and u.tg_id is distinct from e.actor_id and (
  (e.kind in ('created','updated') and e.data->>'assigned_to' is distinct from e.data->>'from_assigned_to'
    and u.tg_id=r.assigned_to and u.tg_id::text=e.data->>'assigned_to')
  or (e.kind='price.requested' and u.role in ('owner','admin') and o.approval='pending')
  or (e.kind in ('price.approved','price.rejected') and u.tg_id=r.assigned_to and o.approval=split_part(e.kind,'.',2))
  or (e.kind='car.chosen' and u.role in ('owner','admin') and r.status='won')
 )
$$;
create or replace function public.bot_event_can_deliver(p_activity bigint,p_recipient bigint)
returns boolean language sql stable security invoker set search_path=public,pg_temp as $$
 select exists(select 1 from bot_event_recipients(p_activity) n where n.recipient=p_recipient)
$$;
create or replace function public.bot_queue_crm_event()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
declare heading text; r crm_requests; section text;
begin
 select * into strict r from crm_requests where id=new.request_id;
 heading:=case new.kind when 'price.requested' then 'Нужно согласовать цену'
  when 'price.approved' then 'Цена согласована' when 'price.rejected' then 'Цена отклонена'
  when 'car.chosen' then 'Клиент выбрал автомобиль' else 'Вам назначена заявка' end;
 section:=case when new.kind like 'price.%' then 'price' when new.kind='car.chosen' then 'order' else 'client' end;
 insert into bot_outbox(chat_id,actor_id,scope_company_id,request_id,activity_id,dedupe_key,body)
 select n.recipient,n.recipient,r.company_id,r.id,new.id,'activity:'||new.id||':'||n.recipient,
  jsonb_strip_nulls(jsonb_build_object('text',heading||E'\n'||r.model,'section',section,'option',new.data->>'option_id'))
 from bot_event_recipients(new.id) n on conflict(dedupe_key) do nothing;
 return new;
end $$;
create or replace trigger bot_crm_event after insert on public.crm_activity for each row
 when (new.kind in ('created','updated','price.requested','price.approved','price.rejected','car.chosen'))
 execute function public.bot_queue_crm_event();
revoke all on function public.bot_event_recipients(bigint),public.bot_queue_crm_event(),public.bot_event_can_deliver(bigint,bigint) from public,anon,authenticated;
grant execute on function public.bot_event_recipients(bigint),public.bot_queue_crm_event(),public.bot_event_can_deliver(bigint,bigint) to service_role;
