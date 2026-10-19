# Sunday Picks

A pick'em league for a group of friends. Each week, everyone picks the winner of every pro football game. Picks lock at each game's kickoff, get scored automatically from real results, and a leaderboard shows weekly and season standings.

## What it does

- **Join with a code.** Friends join a league with the league code, a display name, and a 4-digit PIN. No email or password.
- **Stays logged in.** After a correct PIN, the phone stays logged in until the player taps **Log out**.
- **Lockout.** 5 wrong PINs in a row locks that player out for 15 minutes.
- **Picks.** Tap a team to pick it. Each game locks at its own kickoff. Use the ‹ › arrows to move between weeks and pick ahead.
- **Everyone's picks.** These are revealed on each game once it kicks off, and never before.
- **Scoring.** Scores update on their own every 15 minutes. 1 point per correct pick. Tie games and missed picks score 0.
- **Leaderboard.** Has a **Season** view and a weekly view.
  - Season ties are broken by the most correct picks in the most recent week that has a finished game.
  - Players still tied share a rank.
- **Admin screen.** Only the league creator sees it, and it needs their PIN again. From it they can:
  - remove a player
  - reset a player's PIN (this also unlocks them and logs them out)
  - enter or correct a final score

  Corrections apply only to that league, and the automatic sync never overwrites them.
- **Times.** All kickoff times are stored in UTC and shown in US Eastern time.

### The pieces

| Piece | What it is | Where it lives |
|---|---|---|
| Website | React app built with Vite | Netlify |
| Database | Postgres tables and functions | Supabase |
| Game sync | `sync-games` function that pulls schedules and scores from ESPN | Supabase Edge Functions |
| Timer | Runs the sync every 15 minutes (`pg_cron`) | Supabase |

### Security in plain English

- **No direct table access.** The browser can't read or write any table. Row-level security is on for every table, with no access rules granted.
- **A fixed list of actions.** The browser can only call specific database functions, defined in `supabase/migrations/`. Each one checks the player's login token, or the admin's PIN, first.
- **Locking is enforced in the database.** It refuses any pick once a game has kicked off, so editing the website can't get around it.
- **Nothing is stored in plain text.** PINs are stored as bcrypt hashes. Login tokens are stored as SHA-256 hashes.
- **Admin mode times out.** It lasts 30 minutes and is kept only in the phone's memory. Reloading the app asks for the PIN again.
- **Only public keys in the website.** The only key in the website is Supabase's public "anon"/"publishable" key, which is designed to be public. The secret service-role key is only used inside the Edge Function, where Supabase provides it automatically.

### Database tables

| Table | One row per… | Key columns |
|---|---|---|
| `leagues` | league | `code` (what friends type to join), `name` |
| `players` | player in a league | `display_name`, `pin_hash`, `is_admin`, wrong-PIN counter and lock time |
| `sessions` | logged-in phone | hashed token, player, expiry (180 days) |
| `admin_sessions` | unlocked Admin screen | hashed token, player, expiry (30 minutes) |
| `games` | real game, shared by all leagues | ESPN id, season, week, `kickoff_at` (UTC), teams, scores, `status`, `winner` |
| `picks` | player and game | `pick` (`home` or `away`) |
| `game_overrides` | admin correction | league, game, corrected scores and winner |

### Game data source

The app uses ESPN's public scoreboard feed: `site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard`. It's free and needs no key. It was checked on Oct 19, 2026 and returned the 2026 regular season, Week 6.

- **It's unofficial.** ESPN doesn't document it or promise to keep it running, and it could change or disappear without notice.
- **There's no published rate limit.** The app makes about 2 calls every 15 minutes, which is light use.
- **If it breaks,** the admin can type final scores into the Admin screen, and scoring works the same way.
- **What the sync skips:** preseason, the Pro Bowl, and playoff games whose teams aren't set yet.

---

## Setup from scratch

You do these steps once. Allow about 30 minutes.

### 1. Create the Supabase project and tables

1. Go to <https://supabase.com>, sign in, and click **New project**. Pick any name and region, and save the database password somewhere safe.
2. When it's ready, open **SQL Editor** in the left sidebar and click **New query**.
3. Copy the whole contents of `supabase/migrations/0001_init.sql`, paste it in, and click **Run**. You should see "Success".
4. Click **New query** again and do the same with `supabase/migrations/0002_full_app.sql`.
5. Check it worked: open **Table Editor**. You should see 7 tables: `admin_sessions`, `game_overrides`, `games`, `leagues`, `picks`, `players`, and `sessions`.

### 2. Create the game-sync function

1. In Supabase, go to **Edge Functions**, then **Deploy a new function**, then **Via Editor**.
2. Name it exactly `sync-games`.
3. Replace the sample code with the full contents of `supabase/functions/sync-games/index.ts`, then click **Deploy**.
4. Open the function's **Details** or **Settings** and turn **off** "Verify JWT" (it may be labeled "Enforce JWT verification"). The function uses its own secret instead, set in the next step.
5. Go to **Edge Functions**, then **Secrets**, and add a secret:
   - Name: `SYNC_SECRET`
   - Value: a long random string you make up, for example 30+ random letters and numbers. Keep it private.

   You don't need to add `SUPABASE_URL` or `SUPABASE_SERVICE_ROLE_KEY`. Supabase provides those automatically.

### 3. Load the season's schedule (one time)

On a Mac, open Terminal and run the command below. Replace `YOUR-PROJECT-REF` with your project's ID (it's in your Supabase URL, `https://YOUR-PROJECT-REF.supabase.co`) and `YOUR_SYNC_SECRET` with the secret from step 2.

```bash
curl -X POST "https://YOUR-PROJECT-REF.supabase.co/functions/v1/sync-games" \
  -H "x-sync-secret: YOUR_SYNC_SECRET" \
  -H "content-type: application/json" \
  -d '{"season": 2026, "all_weeks": true}'
```

You should see something like `{"saved":272,...}`. That's all 18 regular-season weeks. If you see `"Not allowed"`, the secret doesn't match.

### 4. Turn on the automatic sync (every 15 minutes)

1. In **SQL Editor**, open a new query and paste in `supabase/migrations/0003_schedule_sync.sql`.
2. In the editor only, replace `YOUR-PROJECT-REF` and `YOUR_SYNC_SECRET` with your real values. **Don't save those values back into the file in GitHub.**
3. Click **Run**.
4. After 15 minutes, check it's working by running:

   ```sql
   select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;
   ```

   You should see `succeeded`.

Each run refreshes the current week's scores and loads next week's schedule. Playoff weeks are added automatically once the matchups are set.

### 5. Find your two public values

In Supabase, go to **Project Settings**, then **API Keys** (or **API**). Copy:

- **Project URL**, which looks like `https://abcd1234.supabase.co`
- **anon / publishable key**. This is the public one.

**Never use the `service_role` or secret key anywhere in the website.**

---

## Connect GitHub to Netlify

1. Sign in at <https://app.netlify.com>.
2. Click **Add new project** (or **Add new site**), then **Import an existing project**, then **GitHub**. Authorize Netlify if asked.
3. Pick the `NFL-pick-em-league` repository. If it's private and doesn't appear, click **Configure Netlify on GitHub** and give Netlify access to it.
4. **Branch to deploy:** `main`.
5. Netlify reads these build settings from `netlify.toml`. Confirm they show:
   - **Build command:** `npm run build`
   - **Publish directory:** `dist`
6. Under **Environment variables**, click **Add variable** and add both of these. You can also add them later under **Site configuration**, then **Environment variables**.

   | Key | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | your Supabase Project URL |
   | `VITE_SUPABASE_ANON_KEY` | your Supabase anon / publishable key |

7. Click **Deploy**. If you add or change environment variables later, go to **Deploys**, then **Trigger deploy**, then **Clear cache and deploy site**. The values are baked in when the site builds.
8. Optional: rename the site under **Site configuration**, then **Change site name**, so the link is something like `sunday-picks-bryan.netlify.app`.

Every push to `main` redeploys the site automatically.

### Where each secret or setting goes

| Name | Set it in | Secret? |
|---|---|---|
| `VITE_SUPABASE_URL` | Netlify environment variables, and `.env` locally | No (public) |
| `VITE_SUPABASE_ANON_KEY` | Netlify environment variables, and `.env` locally | No (public by design) |
| `SYNC_SECRET` | Supabase Edge Functions secrets, plus Vault via `0003_schedule_sync.sql` | **Yes** |
| Service-role / secret key | Nowhere. Supabase injects it into the Edge Function | **Yes** |

---

## First game day

1. Open the Netlify link on your phone, tap **New League**, and create the league. You're the admin.
2. Text the league code (shown at the top of the app) and the link to your friends. They tap **Join**.
3. Suggest everyone add the app to their home screen. On iPhone, tap Share, then **Add to Home Screen**. On Android, tap the menu, then **Add to Home screen**.

## Run it on your computer

You need Node.js 20 or newer from <https://nodejs.org>. Then run:

```bash
git clone https://github.com/Bryanperez0/NFL-pick-em-league.git
cd NFL-pick-em-league
npm install
cp .env.example .env      # then open .env and paste your two Supabase values
npm run dev
```

Open the address it prints, usually <http://localhost:5173>. Running locally uses your real Supabase database, so anything you do there shows up for everyone. `.env` is listed in `.gitignore`, so it is never committed.

## Project layout

```
index.html                         page shell
public/icon.svg                    app icon
src/App.jsx                        login check, top bar, bottom tabs, current week
src/api.js                         talks to Supabase; saves the login token on the phone
src/time.js                        Eastern-time formatting
src/weeks.js, src/WeekPicker.jsx   week labels and the ‹ Week › control
src/screens/JoinLogin.jsx          Log In / Join / New League
src/screens/Picks.jsx              a week's games, picks, results, everyone's picks
src/screens/Leaderboard.jsx        season and weekly standings
src/screens/Admin.jsx              players and game-result tools
src/styles.css                     all styling (mobile-first, light and dark)
supabase/migrations/0001_init.sql  core tables, security, login and picks
supabase/migrations/0002_full_app.sql   leaderboard, pick reveal, admin tools
supabase/migrations/0003_schedule_sync.sql  the 15-minute timer
supabase/functions/sync-games/     ESPN sync Edge Function
netlify.toml                       Netlify build settings
```

---

## Maintaining it

**Scores look stale.** Run the `cron.job_run_details` query from setup step 4 to see whether the timer is running and what errors it hit. You can also run the `curl` command from setup step 3 with `-d '{}'` to sync right away.

**ESPN stops working.** The sync will show errors and scores will stop updating. Picks and locking still work, because they use the kickoff times already saved. The admin can type final scores in **Admin → Game results** until it's fixed. A replacement data source would only need changes inside `supabase/functions/sync-games/index.ts`.

**A score is wrong.** Go to **Admin → Game results**, pick the week, type the right score, and tap **Save final**. Tap **Undo** to go back to the automatic result.

**A player forgot their PIN.** Go to **Admin → Players → Reset PIN**. If the admin forgets their own PIN, run this in the Supabase SQL Editor, replacing the name, code, and new PIN:

```sql
update players set pin_hash = extensions.crypt('5678', extensions.gen_salt('bf')),
                   failed_attempts = 0, locked_until = null
where lower(display_name) = lower('Bryan')
  and league_id = (select id from leagues where code = 'ABC123');
```

**Next season.** The timer keeps running, and ESPN's "current week" moves to the new season on its own. Before Week 1, load the full schedule with the `curl` command from setup step 3, changing `2026` to the new year. The week picker shows the newest season. Season totals only count that season, so standings start fresh. Use the same league code.

**The off-season.** I believe free Supabase projects pause after about a week with no activity. If yours is paused, open the Supabase dashboard and click **Restore** before the season starts.

**Changing the database.** Don't edit a migration file you've already run. Add a new numbered file, for example `0004_something.sql`, and run it in the SQL Editor. Since `0002`, new database functions are private by default. To let the website call a new one, add a `grant execute ... to anon, authenticated;` line for it, as at the end of `0002_full_app.sql`.

**App name or colors.** Change the name in `index.html` and the `Sunday Picks` text in `src/App.jsx` and `src/screens/JoinLogin.jsx`. Colors are at the top of `src/styles.css`.
