-- =============================================================================
-- Sunday Picks — Phase 1 database setup
--
-- Run this whole file once in the Supabase SQL Editor (Dashboard > SQL Editor >
-- New query > paste > Run). It is safe to read top to bottom; each section is
-- explained in plain English.
--
-- Security model in one paragraph:
--   Row-level security (RLS) is turned ON for every table and NO policies are
--   added. That means the browser (which uses the public "anon" key) cannot
--   read or write any table directly. The only thing the browser can do is call
--   the functions at the bottom of this file. Those functions check the
--   player's login token (or PIN) and the game's kickoff time before doing
--   anything. They run as "security definer", meaning they run with the
--   database owner's permissions, so they can touch the tables on the player's
--   behalf — but only in the exact ways written here.
-- =============================================================================

-- pgcrypto gives us bcrypt hashing (crypt / gen_salt), random bytes, and sha256.
-- Supabase installs extensions into the "extensions" schema.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- TABLES
-- -----------------------------------------------------------------------------

-- One row per league. "code" is what friends type in to join.
create table public.leagues (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null check (char_length(name) between 1 and 40),
  created_at  timestamptz not null default now()
);

-- One row per player in a league. The PIN is stored only as a bcrypt hash.
-- failed_attempts / locked_until stop people from guessing a PIN.
create table public.players (
  id               uuid primary key default gen_random_uuid(),
  league_id        uuid not null references public.leagues(id) on delete cascade,
  display_name     text not null check (char_length(display_name) between 1 and 20),
  pin_hash         text not null,
  is_admin         boolean not null default false,
  failed_attempts  int not null default 0,
  locked_until     timestamptz,
  created_at       timestamptz not null default now()
);
-- No two players in the same league can share a name (case-insensitive).
create unique index players_league_name_idx
  on public.players (league_id, lower(display_name));

-- "Remember me on this phone." After a correct PIN, the phone gets a random
-- token. We store only a sha256 hash of it, so a database leak can't be used
-- to log in. Logging out deletes the row.
create table public.sessions (
  token_hash  text primary key,
  player_id   uuid not null references public.players(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '180 days'
);
create index sessions_player_idx on public.sessions (player_id);

-- One row per real game, shared by every league. Filled in by the sync-games
-- Edge Function from ESPN. id is ESPN's event id. kickoff_at is stored in UTC.
--   status: scheduled | in_progress | final | postponed | canceled
--   winner: home | away | tie  (null until the game is final)
--   manual_result: true once the admin corrects a result; the sync then stops
--                  overwriting the score for that game (used in Phase 3).
create table public.games (
  id             text primary key,
  season         int  not null,
  season_type    int  not null,          -- 1 preseason, 2 regular, 3 postseason
  week           int  not null,
  kickoff_at     timestamptz not null,
  home_team      text not null,
  home_abbr      text not null,
  away_team      text not null,
  away_abbr      text not null,
  home_score     int,
  away_score     int,
  status         text not null default 'scheduled'
                 check (status in ('scheduled','in_progress','final','postponed','canceled')),
  winner         text check (winner in ('home','away','tie')),
  manual_result  boolean not null default false,
  updated_at     timestamptz not null default now()
);
create index games_week_idx on public.games (season, season_type, week);

-- One row per player per game. "pick" is which side they chose.
create table public.picks (
  player_id   uuid not null references public.players(id) on delete cascade,
  game_id     text not null references public.games(id) on delete cascade,
  pick        text not null check (pick in ('home','away')),
  updated_at  timestamptz not null default now(),
  primary key (player_id, game_id)
);
create index picks_game_idx on public.picks (game_id);

-- Lock every table down. No policies = no direct access from the browser.
alter table public.leagues  enable row level security;
alter table public.players  enable row level security;
alter table public.sessions enable row level security;
alter table public.games    enable row level security;
alter table public.picks    enable row level security;

-- Belt and braces: remove default table grants from the browser roles too.
revoke all on public.leagues, public.players, public.sessions, public.games, public.picks
  from anon, authenticated;

-- -----------------------------------------------------------------------------
-- INTERNAL HELPERS (not callable from the browser)
-- -----------------------------------------------------------------------------

-- Validate a 4-digit PIN.
create or replace function public._check_pin_format(p_pin text)
returns void language plpgsql immutable as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
end $$;

-- Clean up a display name: trim spaces, collapse doubles, enforce length.
create or replace function public._clean_name(p_name text)
returns text language plpgsql immutable as $$
declare v text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if char_length(v) < 1 or char_length(v) > 20 then
    raise exception 'Name must be 1 to 20 characters';
  end if;
  return v;
end $$;

-- Create a session for a player and return the raw token (shown to the phone once).
create or replace function public._new_session(p_player_id uuid)
returns text language plpgsql security definer
set search_path = public, extensions as $$
declare v_token text := encode(gen_random_bytes(32), 'hex');
begin
  insert into sessions (token_hash, player_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), p_player_id);
  return v_token;
end $$;

-- Turn a token into a player id, or raise an error if it is missing/expired.
create or replace function public._player_from_token(p_token text)
returns uuid language plpgsql stable security definer
set search_path = public, extensions as $$
declare v_player uuid;
begin
  select s.player_id into v_player
  from sessions s
  where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
    and s.expires_at > now();
  if v_player is null then
    raise exception 'Not logged in';
  end if;
  return v_player;
end $$;

-- Public-facing JSON for "who am I".
create or replace function public._me_json(p_player_id uuid)
returns json language sql stable security definer
set search_path = public as $$
  select json_build_object(
    'player_id',    p.id,
    'display_name', p.display_name,
    'is_admin',     p.is_admin,
    'league_id',    l.id,
    'league_name',  l.name,
    'league_code',  l.code
  )
  from players p join leagues l on l.id = p.league_id
  where p.id = p_player_id;
$$;

-- -----------------------------------------------------------------------------
-- BROWSER-CALLABLE FUNCTIONS
-- -----------------------------------------------------------------------------

-- Create a new league. The creator becomes its admin and is logged in.
create or replace function public.create_league(p_league_name text, p_display_name text, p_pin text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_name   text := btrim(coalesce(p_league_name, ''));
  v_player text := public._clean_name(p_display_name);
  v_code   text;
  v_league uuid;
  v_pid    uuid;
  -- No 0/O/1/I/L so codes are easy to read aloud.
  v_chars  text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  perform public._check_pin_format(p_pin);
  if char_length(v_name) < 1 or char_length(v_name) > 40 then
    raise exception 'League name must be 1 to 40 characters';
  end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;
    exit when not exists (select 1 from leagues where code = v_code);
  end loop;

  insert into leagues (code, name) values (v_code, v_name) returning id into v_league;
  insert into players (league_id, display_name, pin_hash, is_admin)
  values (v_league, v_player, crypt(p_pin, gen_salt('bf')), true)
  returning id into v_pid;

  return json_build_object('token', public._new_session(v_pid), 'me', public._me_json(v_pid));
end $$;

-- Join an existing league with its code. Name must not already be taken.
create or replace function public.join_league(p_code text, p_display_name text, p_pin text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_name   text := public._clean_name(p_display_name);
  v_league uuid;
  v_pid    uuid;
begin
  perform public._check_pin_format(p_pin);
  select id into v_league from leagues where code = upper(btrim(coalesce(p_code, '')));
  if v_league is null then
    raise exception 'League code not found';
  end if;
  if exists (select 1 from players where league_id = v_league and lower(display_name) = lower(v_name)) then
    raise exception 'That name is already taken in this league. If it is you, use Log In.';
  end if;

  insert into players (league_id, display_name, pin_hash)
  values (v_league, v_name, crypt(p_pin, gen_salt('bf')))
  returning id into v_pid;

  return json_build_object('token', public._new_session(v_pid), 'me', public._me_json(v_pid));
end $$;

-- Log in with league code + name + PIN.
-- 5 wrong PINs in a row locks that player for 15 minutes.
-- (Errors would roll back the attempt counter, so wrong PINs return a JSON
--  error instead of raising.)
create or replace function public.login(p_code text, p_display_name text, p_pin text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_player players%rowtype;
begin
  select p.* into v_player
  from players p join leagues l on l.id = p.league_id
  where l.code = upper(btrim(coalesce(p_code, '')))
    and lower(p.display_name) = lower(public._clean_name(p_display_name));

  if v_player.id is null then
    return json_build_object('error', 'League code or name not found');
  end if;

  if v_player.locked_until is not null and v_player.locked_until > now() then
    return json_build_object('error',
      'Too many wrong PINs. Try again after ' ||
      to_char(v_player.locked_until at time zone 'America/New_York', 'FMHH12:MI AM') || ' ET.');
  end if;

  if p_pin is null or v_player.pin_hash <> crypt(p_pin, v_player.pin_hash) then
    update players
       set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
           locked_until    = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
     where id = v_player.id;
    return json_build_object('error', 'Wrong PIN');
  end if;

  update players set failed_attempts = 0, locked_until = null where id = v_player.id;
  return json_build_object('token', public._new_session(v_player.id), 'me', public._me_json(v_player.id));
end $$;

-- Log out: delete this phone's session.
create or replace function public.logout(p_token text)
returns void language sql security definer
set search_path = public, extensions as $$
  delete from sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- Who am I? Used when the app opens to check the saved token still works.
create or replace function public.get_me(p_token text)
returns json language sql stable security definer
set search_path = public as $$
  select public._me_json(public._player_from_token(p_token));
$$;

-- Which week should the Picks screen show by default?
-- The week of the next game that isn't final; if the season is over, the last week.
create or replace function public.get_current_week()
returns json language sql stable security definer
set search_path = public as $$
  select json_build_object('season', season, 'season_type', season_type, 'week', week)
  from (
    (select season, season_type, week, 0 as pri, kickoff_at
       from games where status in ('scheduled','in_progress')
       order by kickoff_at asc limit 1)
    union all
    (select season, season_type, week, 1 as pri, kickoff_at
       from games order by kickoff_at desc limit 1)
  ) x
  order by pri
  limit 1;
$$;

-- Games for a week, with this player's pick for each and whether it's locked.
create or replace function public.get_week_games(p_token text, p_season int, p_season_type int, p_week int)
returns json language sql stable security definer
set search_path = public as $$
  with me as (select public._player_from_token(p_token) as pid)
  select coalesce(json_agg(json_build_object(
           'id',          g.id,
           'kickoff_at',  g.kickoff_at,
           'home_team',   g.home_team,
           'home_abbr',   g.home_abbr,
           'away_team',   g.away_team,
           'away_abbr',   g.away_abbr,
           'home_score',  g.home_score,
           'away_score',  g.away_score,
           'status',      g.status,
           'winner',      g.winner,
           'locked',      (g.kickoff_at <= now() or g.status <> 'scheduled'),
           'my_pick',     pk.pick
         ) order by g.kickoff_at, g.id), '[]'::json)
  from games g
  cross join me
  left join picks pk on pk.game_id = g.id and pk.player_id = me.pid
  where g.season = p_season and g.season_type = p_season_type and g.week = p_week;
$$;

-- Make or change a pick. This is where pick locking is enforced: the database
-- refuses the pick if the game has kicked off, even if the browser is tampered with.
create or replace function public.submit_pick(p_token text, p_game_id text, p_pick text)
returns json language plpgsql security definer
set search_path = public as $$
declare
  v_pid  uuid := public._player_from_token(p_token);
  v_game games%rowtype;
begin
  if p_pick not in ('home','away') then
    raise exception 'Pick must be home or away';
  end if;

  -- "for share" stops the sync from changing this game mid-check.
  select * into v_game from games where id = p_game_id for share;
  if v_game.id is null then
    raise exception 'Game not found';
  end if;
  if v_game.kickoff_at <= now() or v_game.status <> 'scheduled' then
    raise exception 'This game is locked. Picks close at kickoff.';
  end if;

  insert into picks (player_id, game_id, pick, updated_at)
  values (v_pid, p_game_id, p_pick, now())
  on conflict (player_id, game_id)
  do update set pick = excluded.pick, updated_at = now();

  return json_build_object('game_id', p_game_id, 'pick', p_pick);
end $$;

-- Leaderboard for a player's league: points this week and season total.
-- 1 point per correct pick. Tie games score 0 for everyone. Missed picks score 0.
create or replace function public.get_leaderboard(p_token text, p_season int, p_season_type int, p_week int)
returns json language sql stable security definer
set search_path = public as $$
  with me as (
    select p.league_id from players p where p.id = public._player_from_token(p_token)
  ),
  scored as (
    select pl.id as player_id,
           g.week, g.season_type,
           (pk.pick = g.winner) as correct
    from players pl
    join me on me.league_id = pl.league_id
    join picks pk on pk.player_id = pl.id
    join games g  on g.id = pk.game_id
    where g.season = p_season and g.status = 'final'
  ),
  totals as (
    select pl.id, pl.display_name,
           coalesce(sum(case when s.correct and s.season_type = p_season_type and s.week = p_week
                             then 1 else 0 end), 0) as week_points,
           coalesce(sum(case when s.correct then 1 else 0 end), 0) as season_points
    from players pl
    join me on me.league_id = pl.league_id
    left join scored s on s.player_id = pl.id
    group by pl.id, pl.display_name
  )
  select coalesce(json_agg(json_build_object(
           'player_id',     id,
           'display_name',  display_name,
           'week_points',   week_points,
           'season_points', season_points
         ) order by season_points desc, week_points desc, lower(display_name)), '[]'::json)
  from totals;
$$;

-- -----------------------------------------------------------------------------
-- SYNC FUNCTION (called only by the sync-games Edge Function, with the
-- service-role key — never by the browser)
--
-- Takes a JSON array of games and inserts/updates them. If the admin has
-- manually set a result (manual_result = true), the score, status and winner
-- are left alone, but kickoff time and team names still update.
-- -----------------------------------------------------------------------------
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
    home_score  = case when games.manual_result then games.home_score else excluded.home_score end,
    away_score  = case when games.manual_result then games.away_score else excluded.away_score end,
    status      = case when games.manual_result then games.status     else excluded.status     end,
    winner      = case when games.manual_result then games.winner     else excluded.winner     end,
    updated_at  = now();
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- PERMISSIONS
-- By default Postgres lets anyone run any function. Take that away, then grant
-- the browser ("anon") only the functions it needs.
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_league(text, text, text),
  public.join_league(text, text, text),
  public.login(text, text, text),
  public.logout(text),
  public.get_me(text),
  public.get_current_week(),
  public.get_week_games(text, int, int, int),
  public.submit_pick(text, text, text),
  public.get_leaderboard(text, int, int, int)
to anon, authenticated;

grant execute on function public.upsert_games(jsonb) to service_role;
