-- Run as the deploying database administrator. Edge receives only the digests.
create extension if not exists pg_cron;
create extension if not exists http with schema extensions;
create table if not exists public.bot_key_digests (
 kind text primary key check(kind in ('worker','webhook')),
 sha256 text not null check(length(sha256)=64)
);
alter table public.bot_key_digests enable row level security;
revoke all on public.bot_key_digests from public,anon,authenticated,service_role;
grant select on public.bot_key_digests to service_role;
do $$
declare k text; secret_name text;
begin
 foreach k in array array['worker','webhook'] loop
  secret_name:='podbor_'||k||'_secret';
  if not exists(select 1 from vault.secrets where name=secret_name) then
   perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),secret_name);
  end if;
  insert into public.bot_key_digests(kind,sha256)
   select k,encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex') from vault.decrypted_secrets where name=secret_name
   on conflict(kind) do update set sha256=excluded.sha256;
 end loop;
end $$;

-- Send directly over TLS. The long-lived credentials never enter a shared request queue.
create or replace function public.podbor_run_bot(task text) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
 base text;
 headers extensions.http_header[];
 response extensions.http_response;
 payload jsonb;
begin
 if task not in ('drain','configure-webhook') or task is null then raise exception 'Invalid bot task'; end if;
 select decrypted_secret into strict base from vault.decrypted_secrets where name='podbor_project_url';
 if base !~ '^https://[a-z0-9]+[.]supabase[.]co$' then raise exception 'Invalid project URL'; end if;
 select array[extensions.http_header('x-worker-secret',decrypted_secret)] into strict headers
 from vault.decrypted_secrets where name='podbor_worker_secret';
 if task='configure-webhook' then
  select array_append(headers,extensions.http_header('x-podbor-install-secret',decrypted_secret)) into strict headers
  from vault.decrypted_secrets where name='podbor_webhook_secret';
 end if;
 perform set_config('http.curlopt_connecttimeout_ms','15000',true);
 perform set_config('http.curlopt_timeout_ms','55000',true);
 response:=extensions.http(row('POST',base||'/functions/v1/telegram-bot/'||task,headers,'application/json','{}')::extensions.http_request);
 begin payload:=response.content::jsonb; exception when invalid_text_representation then payload:='{}'; end;
 if response.status<>200 then
  raise exception 'Bot task % returned HTTP % (%)',task,response.status,
   case when payload->>'error' in ('another_webhook','telegram_401','telegram_404','telegram_unavailable') then payload->>'error' else 'see edge logs' end;
 end if;
 if task='drain' then
  if payload->'ok' is distinct from 'true'::jsonb then raise exception 'Worker did not acknowledge'; end if;
  return jsonb_build_object('ok',true);
 end if;
 if payload->'configured' is distinct from 'true'::jsonb then raise exception 'Webhook not confirmed'; end if;
 return jsonb_build_object('configured',true,'bot',payload->'bot','bot_id',payload->'bot_id','pending',payload->'pending',
  'menu_ready',payload->'menu_ready','text_model_configured',payload->'text_model_configured');
end $$;
revoke all on function public.podbor_run_bot(text) from public, anon, authenticated, service_role;
