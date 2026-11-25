-- Optional deployment step. Preconfigure Vault secrets podbor_project_url and podbor_worker_secret.
do $$
begin
 if not exists(select 1 from vault.decrypted_secrets where name='podbor_project_url' and decrypted_secret like 'https://%.supabase.co') or
    not exists(select 1 from vault.decrypted_secrets where name='podbor_worker_secret' and length(decrypted_secret)>=32) then
  raise exception 'Set the project URL and worker secret in Vault before scheduling';
 end if;
 perform cron.schedule('podbor-workflow-drain','* * * * *',$job$
  select public.podbor_run_bot('drain')
 $job$);
end $$;
