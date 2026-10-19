-- =============================================================================
-- Sunday Picks — Phases 2 and 3 database changes
--
-- Run this AFTER 0001_init.sql, in the Supabase SQL Editor (paste whole file,
-- click Run). It adds:
--   * week-by-week browsing and the full leaderboard with tiebreaker
--   * other players' picks, revealed only after each game kicks off
--   * the admin tools (remove player, reset PIN, correct/enter results)
--
-- Result corrections are stored PER LEAGUE in game_overrides, so one league's
-- admin can never change scores for a different league. The ESPN sync never
-- touches game_overrides, so a correction always sticks.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- NEW TABLES
-- -----------------------------------------------------------------------------

-- An admin's correction (or hand-entered final score) for one game in one league.
create table public.game_overrides (
  league_id   uuid not null references public.leagues(id) on delete cascade,
  game_id     text not null references public.games(id) on delete cascade,
  home_score  int  not null check (home_score >= 0),
  away_score  int  not null check (away_score >= 0),
  winner      text not null check (winner in ('home','away','tie')),
  updated_at  timestamptz not null default now(),
  primary key (league_id, game_id)
);

-- Short-lived "admin mode" tokens. Opening the Admin screen requires the
-- admin's PIN; that gives the phone a token good for 30 minutes, kept only in
-- memory (closing or reloading the app ends admin mode).
create table public.admin_sessions (
  token_hash  text primary key,
  player_id   uuid not null references public.players(id) on delete cascade,
  expires_at  timestamptz not null default now() + interval '30 minutes'
);

alter table public.game_overrides enable row level security;
alter table public.admin_sessions enable row level security;
revoke all on public.game_overrides, public.admin_sessions from anon, authenticated;

-- Corrections now live in game_overrides, so this column is no longer used.
alter table public.games drop column if exists manual_result;

-- -----------------------------------------------------------------------------
-- INTERNAL HELPERS
-- -----------------------------------------------------------------------------

-- Check a player's PIN with the 5-strikes / 15-minute lockout.
-- Returns NULL if the PIN is right, otherwise an error message.
-- (It returns instead of raising so the wrong-PIN counter is saved.)
create or replace function public._check_pin(p_player_id uuid, p_pin text)
returns text language plpgsql security definer
set search_path = public, extensions as $$
declare v players%rowtype;
begin
  select * into v from players where id = p_player_id;
  if v.id is null then
    return 'Player not found';
  end if;
  if v.locked_until is not null and v.locked_until > now() then
    return 'Too many wrong PINs. Try again after ' ||
      to_char(v.locked_until at time zone 'America/New_York', 'FMHH12:MI AM') || ' ET.';
  end if;
  if p_pin is null or v.pin_hash <> crypt(p_pin, v.pin_hash) then
    update players
       set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
           locked_until    = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
     where id = v.id;
    return 'Wrong PIN';
  end if;
  update players set failed_attempts = 0, locked_until = null where id = v.id;
  return null;
end $$;

-- All regular-season and playoff games, with this league's corrections applied.
-- Every screen reads games through this, so corrections show up everywhere.
create or replace function public._league_games(p_league_id uuid)
returns table (
  id text, season int, season_type int, week int, kickoff_at timestamptz,
  home_team text, home_abbr text, away_team text, away_abbr text,
  home_score int, away_score int, status text, winner text, corrected boolean
) language sql stable security definer
set search_path = public as $$
  select g.id, g.season, g.season_type, g.week, g.kickoff_at,
         g.home_team, g.home_abbr, g.away_team, g.away_abbr,
         coalesce(o.home_score, g.home_score),
         coalesce(o.away_score, g.away_score),
         case when o.game_id is not null then 'final' else g.status end,
         case when o.game_id is not null then o.winner else g.winner end,
         o.game_id is not null
  from games g
  left join game_overrides o on o.game_id = g.id and o.league_id = p_league_id
  where g.season_type in (2, 3);   -- skip preseason
$$;

-- Turn an admin-mode token into the admin's player row, or raise.
create or replace function public._admin_from_token(p_admin_token text)
returns players language plpgsql stable security definer
set search_path = public, extensions as $$
declare v players%rowtype;
begin
  select p.* into v
  from admin_sessions a join players p on p.id = a.player_id
  where a.token_hash = encode(digest(coalesce(p_admin_token, ''), 'sha256'), 'hex')
    and a.expires_at > now()
    and p.is_admin;
  if v.id is null then
    raise exception 'Admin session expired. Enter your PIN again.';
  end if;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- UPDATED PLAYER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Log in (now shares the PIN check with admin unlock).
create or replace function public.login(p_code text, p_display_name text, p_pin text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_pid uuid;
  v_err text;
begin
  select p.id into v_pid
  from players p join leagues l on l.id = p.league_id
  where l.code = upper(btrim(coalesce(p_code, '')))
    and lower(p.display_name) = lower(public._clean_name(p_display_name));
  if v_pid is null then
    return json_build_object('error', 'League code or name not found');
  end if;

  v_err := public._check_pin(v_pid, p_pin);
  if v_err is not null then
    return json_build_object('error', v_err);
  end if;

  delete from sessions where player_id = v_pid and expires_at < now();  -- tidy up
  return json_build_object('token', public._new_session(v_pid), 'me', public._me_json(v_pid));
end $$;

-- Every week that has games this season, in order (for the week picker).
create or replace function public.get_weeks()
returns json language sql stable security definer
set search_path = public as $$
  select coalesce(json_agg(json_build_object('season', season, 'season_type', season_type, 'week', week)
                           order by season_type, week), '[]'::json)
  from (
    select distinct season, season_type, week
    from games
    where season_type in (2, 3)
      and season = (select max(season) from games where season_type in (2, 3))
  ) w;
$$;

-- Default week: the week of the next unfinished game; after the season, the last week.
create or replace function public.get_current_week()
returns json language sql stable security definer
set search_path = public as $$
  select json_build_object('season', season, 'season_type', season_type, 'week', week)
  from (
    (select season, season_type, week, 0 as pri
       from games where status in ('scheduled','in_progress') and season_type in (2, 3)
       order by kickoff_at asc limit 1)
    union all
    (select season, season_type, week, 1 as pri
       from games where season_type in (2, 3)
       order by kickoff_at desc limit 1)
  ) x
  order by pri
  limit 1;
$$;

-- A week's games with: my pick, whether it's locked, and — only once a game has
-- kicked off — what everyone else in my league picked.
create or replace function public.get_week_games(p_token text, p_season int, p_season_type int, p_week int)
returns json language sql stable security definer
set search_path = public as $$
  with me as (
    select p.id as pid, p.league_id from players p where p.id = public._player_from_token(p_token)
  ),
  lg as (
    select g.*, (g.kickoff_at <= now() or g.status <> 'scheduled') as is_locked
    from me, lateral public._league_games(me.league_id) g
    where g.season = p_season and g.season_type = p_season_type and g.week = p_week
  )
  select coalesce(json_agg(json_build_object(
           'id',          lg.id,
           'kickoff_at',  lg.kickoff_at,
           'home_team',   lg.home_team,
           'home_abbr',   lg.home_abbr,
           'away_team',   lg.away_team,
           'away_abbr',   lg.away_abbr,
           'home_score',  lg.home_score,
           'away_score',  lg.away_score,
           'status',      lg.status,
           'winner',      lg.winner,
           'corrected',   lg.corrected,
           'locked',      lg.is_locked,
           'my_pick',     (select pick from picks where player_id = me.pid and game_id = lg.id),
           'picks',       case when lg.is_locked then (
                            select coalesce(json_agg(json_build_object('name', pl.display_name, 'pick', pk.pick)
                                                     order by lower(pl.display_name)), '[]'::json)
                            from picks pk join players pl on pl.id = pk.player_id
                            where pk.game_id = lg.id and pl.league_id = me.league_id)
                          end
         ) order by lg.kickoff_at, lg.id), '[]'::json)
  from lg cross join me;
$$;

-- Make or change a pick. Refused once the game has kicked off, or once the
-- admin has entered a result for it.
create or replace function public.submit_pick(p_token text, p_game_id text, p_pick text)
returns json language plpgsql security definer
set search_path = public as $$
declare
  v_pid    uuid := public._player_from_token(p_token);
  v_league uuid := (select league_id from players where id = v_pid);
  v_game   games%rowtype;
begin
  if p_pick not in ('home','away') then
    raise exception 'Pick must be home or away';
  end if;

  select * into v_game from games where id = p_game_id for share;
  if v_game.id is null or v_game.season_type not in (2, 3) then
    raise exception 'Game not found';
  end if;
  if v_game.kickoff_at <= now() or v_game.status <> 'scheduled'
     or exists (select 1 from game_overrides where league_id = v_league and game_id = p_game_id) then
    raise exception 'This game is locked. Picks close at kickoff.';
  end if;

  insert into picks (player_id, game_id, pick, updated_at)
  values (v_pid, p_game_id, p_pick, now())
  on conflict (player_id, game_id)
  do update set pick = excluded.pick, updated_at = now();

  return json_build_object('game_id', p_game_id, 'pick', p_pick);
end $$;

-- Leaderboard as of a chosen week.
--   weekly: points in that week (ties share a rank)
--   season: points from Week 1 through that week. Ties are broken by points in
--           the most recent week (up to the chosen week) that has a finished
--           game. Still tied = shared rank.
-- 1 point per correct pick; tie games and missed picks score 0.
drop function if exists public.get_leaderboard(text, int, int, int);
create function public.get_leaderboard(p_token text, p_season int, p_season_type int, p_week int)
returns json language sql stable security definer
set search_path = public as $$
  with me as (
    select p.league_id from players p where p.id = public._player_from_token(p_token)
  ),
  lg as (
    -- season_type * 100 + week gives one number that sorts regular season before playoffs
    select g.id, g.winner, g.status, g.season_type * 100 + g.week as wk
    from me, lateral public._league_games(me.league_id) g
    where g.season = p_season
  ),
  sel as (select p_season_type * 100 + p_week as wk),
  tb as (
    select max(lg.wk) as wk from lg, sel where lg.status = 'final' and lg.wk <= sel.wk
  ),
  scored as (
    select pk.player_id, lg.wk
    from lg join picks pk on pk.game_id = lg.id
    where lg.status = 'final' and pk.pick = lg.winner
  ),
  totals as (
    select pl.id, pl.display_name,
           count(s.wk) filter (where s.wk = sel.wk) as week_points,
           count(s.wk) filter (where s.wk <= sel.wk) as season_points,
           count(s.wk) filter (where s.wk = tb.wk) as tiebreak_points
    from players pl
    join me on me.league_id = pl.league_id
    cross join sel cross join tb
    left join scored s on s.player_id = pl.id
    group by pl.id, pl.display_name
  )
  select json_build_object(
    'tiebreak_week', (select case when wk is null then null
                                  else json_build_object('season_type', wk / 100, 'week', wk % 100) end
                      from tb),
    'weekly', (select coalesce(json_agg(json_build_object(
                   'player_id', id, 'display_name', display_name,
                   'rank', r, 'points', week_points)
                 order by r, lower(display_name)), '[]'::json)
               from (select *, rank() over (order by week_points desc) r from totals) x),
    'season', (select coalesce(json_agg(json_build_object(
                   'player_id', id, 'display_name', display_name,
                   'rank', r, 'points', season_points, 'tiebreak', tiebreak_points)
                 order by r, lower(display_name)), '[]'::json)
               from (select *, rank() over (order by season_points desc, tiebreak_points desc) r
                     from totals) x)
  );
$$;

-- Sync: same as before, minus the old manual_result column.
create or replace function public.upsert_games(p_games jsonb)
returns int language plpgsql security definer
set search_path = public as $$
declare v_count int;
begin
  insert into games (id, season, season_type, week, kickoff_at,
                     home_team, home_abbr, away_team, away_abbr,
                     home_score, away_score, status, winner, updated_at)
  select g->>'id', (g->>'season')::int, (g->>'season_type')::int, (g->>'week')::int,
         (g->>'kickoff_at')::timestamptz,
         g->>'home_team', g->>'home_abbr', g->>'away_team', g->>'away_abbr',
         (g->>'home_score')::int, (g->>'away_score')::int,
         g->>'status', g->>'winner', now()
  from jsonb_array_elements(p_games) g
  on conflict (id) do update set
    season      = excluded.season,
    season_type = excluded.season_type,
    week        = excluded.week,
    kickoff_at  = excluded.kickoff_at,
    home_team   = excluded.home_team,
    home_abbr   = excluded.home_abbr,
    away_team   = excluded.away_team,
    away_abbr   = excluded.away_abbr,
    home_score  = excluded.home_score,
    away_score  = excluded.away_score,
    status      = excluded.status,
    winner      = excluded.winner,
    updated_at  = now();
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- ADMIN FUNCTIONS
-- -----------------------------------------------------------------------------

-- Enter admin mode: requires a logged-in admin AND their PIN (with lockout).
create or replace function public.admin_unlock(p_token text, p_pin text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_pid   uuid := public._player_from_token(p_token);
  v_err   text;
  v_token text := encode(gen_random_bytes(32), 'hex');
begin
  if not (select is_admin from players where id = v_pid) then
    return json_build_object('error', 'Only the league admin can open this screen');
  end if;
  v_err := public._check_pin(v_pid, p_pin);
  if v_err is not null then
    return json_build_object('error', v_err);
  end if;
  delete from admin_sessions where expires_at < now();
  insert into admin_sessions (token_hash, player_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_pid);
  return json_build_object('admin_token', v_token);
end $$;

-- Everyone in the admin's league.
create or replace function public.admin_list_players(p_admin_token text)
returns json language sql stable security definer
set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'player_id',    p.id,
           'display_name', p.display_name,
           'is_admin',     p.is_admin,
           'locked',       coalesce(p.locked_until > now(), false),
           'picks_made',   (select count(*) from picks where player_id = p.id)
         ) order by lower(p.display_name)), '[]'::json)
  from players p
  where p.league_id = (public._admin_from_token(p_admin_token)).league_id;
$$;

-- Remove a player (and all their picks) from the league.
create or replace function public.admin_remove_player(p_admin_token text, p_player_id uuid)
returns void language plpgsql security definer
set search_path = public as $$
declare v_admin players%rowtype := public._admin_from_token(p_admin_token);
begin
  if p_player_id = v_admin.id then
    raise exception 'You can''t remove yourself';
  end if;
  delete from players where id = p_player_id and league_id = v_admin.league_id;
  if not found then
    raise exception 'Player not found in your league';
  end if;
end $$;

-- Give a player a new PIN. Also unlocks them and logs them out everywhere.
create or replace function public.admin_reset_pin(p_admin_token text, p_player_id uuid, p_new_pin text)
returns void language plpgsql security definer
set search_path = public, extensions as $$
declare v_admin players%rowtype := public._admin_from_token(p_admin_token);
begin
  perform public._check_pin_format(p_new_pin);
  update players
     set pin_hash = crypt(p_new_pin, gen_salt('bf')), failed_attempts = 0, locked_until = null
   where id = p_player_id and league_id = v_admin.league_id;
  if not found then
    raise exception 'Player not found in your league';
  end if;
  -- Log them out on every phone (but don't log the admin out of their own phone).
  if p_player_id <> v_admin.id then
    delete from sessions where player_id = p_player_id;
  end if;
end $$;

-- Set or correct a game's final score for this league. Allowed only after kickoff.
create or replace function public.admin_set_result(p_admin_token text, p_game_id text,
                                                   p_home_score int, p_away_score int)
returns void language plpgsql security definer
set search_path = public as $$
declare
  v_admin players%rowtype := public._admin_from_token(p_admin_token);
  v_kick  timestamptz;
begin
  select kickoff_at into v_kick from games where id = p_game_id;
  if v_kick is null then
    raise exception 'Game not found';
  end if;
  if v_kick > now() then
    raise exception 'You can only enter a result after kickoff';
  end if;
  if p_home_score is null or p_away_score is null or p_home_score < 0 or p_away_score < 0 then
    raise exception 'Enter both scores (0 or more)';
  end if;
  insert into game_overrides (league_id, game_id, home_score, away_score, winner, updated_at)
  values (v_admin.league_id, p_game_id, p_home_score, p_away_score,
          case when p_home_score > p_away_score then 'home'
               when p_away_score > p_home_score then 'away' else 'tie' end,
          now())
  on conflict (league_id, game_id) do update set
    home_score = excluded.home_score, away_score = excluded.away_score,
    winner = excluded.winner, updated_at = now();
end $$;

-- Undo a correction: go back to the automatic (ESPN) result.
create or replace function public.admin_clear_result(p_admin_token text, p_game_id text)
returns void language plpgsql security definer
set search_path = public as $$
begin
  delete from game_overrides
  where league_id = (public._admin_from_token(p_admin_token)).league_id
    and game_id = p_game_id;
end $$;

-- -----------------------------------------------------------------------------
-- PERMISSIONS
-- -----------------------------------------------------------------------------

-- Supabase normally lets the browser run any new function. Turn that off for
-- functions created from now on, so nothing is exposed by accident.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_league(text, text, text),
  public.join_league(text, text, text),
  public.login(text, text, text),
  public.logout(text),
  public.get_me(text),
  public.get_weeks(),
  public.get_current_week(),
  public.get_week_games(text, int, int, int),
  public.submit_pick(text, text, text),
  public.get_leaderboard(text, int, int, int),
  public.admin_unlock(text, text),
  public.admin_list_players(text),
  public.admin_remove_player(text, uuid),
  public.admin_reset_pin(text, uuid, text),
  public.admin_set_result(text, text, int, int),
  public.admin_clear_result(text, text)
to anon, authenticated;

grant execute on function public.upsert_games(jsonb) to service_role;
