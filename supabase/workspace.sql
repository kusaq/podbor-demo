-- Personal working state of the interactive prototype. Not dealer multi-tenancy.
create table if not exists public.user_workspaces (
  user_id bigint primary key references public.app_users(tg_id) on delete cascade on update cascade,
  state jsonb not null default '{}'::jsonb,
  revision integer not null default 1 check (revision > 0),
  updated_at timestamptz not null default now(),
  constraint workspace_object check (jsonb_typeof(state) = 'object'),
  constraint workspace_size check (octet_length(state::text) <= 6000000)
);
alter table public.user_workspaces enable row level security;
revoke all on public.user_workspaces from public, anon, authenticated;
grant select, insert, update on public.user_workspaces to service_role;
-- Existing tables also need explicit server privileges when auto-exposure is disabled.
grant select, insert, update, delete on public.app_users to service_role;
grant select on public.mocks to service_role;
