-- =============================================================================
-- Sunday Picks — run the ESPN sync automatically every 15 minutes
--
-- Run this AFTER 0001 and 0002, and after the sync-games Edge Function is
-- deployed with its SYNC_SECRET (see README).
--
-- BEFORE RUNNING: replace the two placeholders below in the SQL Editor ONLY.
--   YOUR-PROJECT-REF   -> your project's ref (from your Supabase URL)
--   YOUR_SYNC_SECRET   -> the same value you set as SYNC_SECRET
-- Do NOT save your real secret back into this file or commit it to GitHub.
-- The values are stored encrypted in Supabase Vault, not in the job itself.
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co', 'sunday_picks_project_url');
select vault.create_secret('YOUR_SYNC_SECRET', 'sunday_picks_sync_secret');

-- Every 15 minutes, call the sync-games Edge Function. With an empty body it
-- refreshes ESPN's current week and loads next week's schedule.
select cron.schedule(
  'sunday-picks-sync',
  '*/15 * * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets
                where name = 'sunday_picks_project_url') || '/functions/v1/sync-games',
    headers := jsonb_build_object(
                 'content-type', 'application/json',
                 'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets
                                   where name = 'sunday_picks_sync_secret')),
    body    := '{}'::jsonb
  );
  $$
);

-- Useful later:
--   See recent runs:      select * from cron.job_run_details order by start_time desc limit 10;
--   Pause the sync:       select cron.unschedule('sunday-picks-sync');
--   Fix a wrong secret:   select vault.update_secret(
--                           (select id from vault.secrets where name = 'sunday_picks_sync_secret'),
--                           'NEW_VALUE');
