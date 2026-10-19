# Sunday Picks

A pick'em league for a group of friends. Each week, everyone picks the winner of every pro football game. Picks lock at each game's kickoff, get scored automatically from real results, and a leaderboard shows who's winning.

**Status:** Phase 1 (join, log in, pick the current week, see scores). Phase 2 adds automatic syncing, a week picker, and full leaderboards. Phase 3 adds the Admin screen.

## How it works

- **Joining:** friends join with the league code, a display name, and a 4-digit PIN. No email or password.
- **Staying logged in:** after a correct PIN, the phone stays logged in until the player taps **Log out**.
- **PIN guessing:** 5 wrong PINs in a row lock that player out for 15 minutes.
- **Admin:** whoever creates the league is its admin.
- **Scoring:** 1 point per correct pick. Tie games and missed picks score 0.
- **Times:** kickoff times are stored in UTC and shown in US Eastern time.

### The pieces

| Piece | What it is | Where it lives |
|---|---|---|
| Website | React app built with Vite | Netlify |
| Database | Postgres tables and functions | Supabase |
| Game sync | `sync-games` function that pulls schedules and scores from ESPN | Supabase Edge Functions |

### Security in plain English

- The browser can't read or write any table directly. Row-level security is on, and no access rules are granted.
- The browser can only call a short list of database functions, defined in `supabase/migrations/0001_init.sql`. Each one checks the player's login token first.
- `submit_pick` refuses any pick once a game has kicked off. That check runs in the database, so editing the website can't get around it.
- PINs are stored as bcrypt hashes. Login tokens are stored as SHA-256 hashes.
- The only key in the website is Supabase's public "anon"/"publishable" key, which is designed to be public. The secret service-role key is only used inside the Edge Function, where Supabase provides it automatically.

### Database tables

| Table | One row per… | Key columns |
|---|---|---|
| `leagues` | league | `code` (what friends type to join), `name` |
| `players` | player in a league | `display_name`, `pin_hash`, `is_admin`, wrong-PIN counter and lock time |
| `sessions` | logged-in phone | hashed token, which player it belongs to, expiry (180 days) |
| `games` | real game, shared by all leagues | ESPN id, season, week, `kickoff_at` (UTC), teams, scores, `status`, `winner`, `manual_result` |
| `picks` | player and game | `pick` (`home` or `away`) |

### Game data source

The app uses ESPN's public scoreboard feed: `site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard`. It's free and needs no key. It was checked on Oct 19, 2026 and returned the 2026 regular season, Week 6.

- **It's unofficial.** ESPN doesn't document it or promise to keep it running, and it could change or disappear without notice.
- **There's no published rate limit.** We only call it a few times an hour, which is light use.
- **If it breaks,** the Admin screen (Phase 3) will let the admin enter final scores by hand. Scores the admin enters are never overwritten by the sync.

---

## Setup from scratch

You do these steps once. Allow about 20 minutes.

### 1. Create the Supabase project

1. Go to <https://supabase.com>, sign in, and click **New project**. Pick any name and region, and save the database password somewhere safe.
2. When the project is ready, open **SQL Editor** in the left sidebar and click **New query**.
3. Open `supabase/migrations/0001_init.sql` from this repo, copy the whole file, paste it into the editor, and click **Run**. You should see "Success. No rows returned."
4. Check it worked: open **Table Editor**. You should see `games`, `leagues`, `picks`, `players`, and `sessions`, each marked as having RLS enabled.

### 2. Create the game-sync function

1. In Supabase, go to **Edge Functions**, then **Deploy a new function**, then **Via Editor**.
2. Name it exactly `sync-games`.
3. Replace the sample code with the full contents of `supabase/functions/sync-games/index.ts`, then click **Deploy**.
4. Open the function's **Details** or **Settings** and turn **off** "Verify JWT" (it may be labeled "Enforce JWT verification"). The function uses its own secret instead, set in the next step.
5. Go to **Edge Functions**, then **Secrets**, and add a secret:
   - Name: `SYNC_SECRET`
   - Value: a long random string you make up, for example 30+ random letters and numbers. Keep it private.

   You don't need to add `SUPABASE_URL` or `SUPABASE_SERVICE_ROLE_KEY`. Supabase provides those automatically.

### 3. Load this week's games

On a Mac, open Terminal and run the command below. Replace `YOUR-PROJECT-REF` with your project's ID (it's in your Supabase URL) and `YOUR_SYNC_SECRET` with the secret from step 2.

```bash
curl -X POST "https://YOUR-PROJECT-REF.supabase.co/functions/v1/sync-games" \
  -H "x-sync-secret: YOUR_SYNC_SECRET" \
  -H "content-type: application/json" \
  -d '{}'
```

You should see something like `{"saved":14,...}`.

- To load a specific week, send `-d '{"season":2026,"season_type":2,"week":7}'`.
- `season_type` is 2 for the regular season and 3 for the playoffs.

**Phase 1 doesn't update scores automatically yet.** Re-run this command after games finish to pull final scores. Phase 2 sets up a schedule so this happens on its own.

### 4. Find your two public values

In Supabase, go to **Project Settings**, then **API Keys** (or **API**). Copy:

- **Project URL**, which looks like `https://abcd1234.supabase.co`
- **anon / publishable key**. This is the public one.

**Do not use the `service_role` or secret key anywhere in the website.**

---

## Connect GitHub to Netlify

1. Sign in at <https://app.netlify.com>.
2. Click **Add new project** (or **Add new site**), then **Import an existing project**, then **GitHub**. Authorize Netlify if asked.
3. Pick the `nfl-pick-em-league` repository. Because it's private, you may need to click **Configure Netlify on GitHub** and give Netlify access to it.
4. Pick the branch to deploy, normally `main`.
5. Netlify reads `netlify.toml`, but confirm these build settings:
   - **Build command:** `npm run build`
   - **Publish directory:** `dist`
6. Under **Environment variables**, click **Add variable** and add both of these. You can also add them later under **Site configuration**, then **Environment variables**.

   | Key | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | your Supabase Project URL |
   | `VITE_SUPABASE_ANON_KEY` | your Supabase anon / publishable key |

7. Click **Deploy**. If you add or change environment variables later, go to **Deploys**, then **Trigger deploy**, then **Clear cache and deploy site**. The values are baked in when the site builds.

Every push to `main` redeploys the site automatically.

### Where each secret or setting goes

| Name | Set it in | Secret? |
|---|---|---|
| `VITE_SUPABASE_URL` | Netlify environment variables, and `.env` locally | No (public) |
| `VITE_SUPABASE_ANON_KEY` | Netlify environment variables, and `.env` locally | No (public by design) |
| `SYNC_SECRET` | Supabase, under Edge Functions, then Secrets | **Yes** |
| Service-role / secret key | Nowhere. Supabase injects it into the Edge Function | **Yes** |

---

## Run it on your computer

You need Node.js 20 or newer from <https://nodejs.org>. Then run:

```bash
git clone https://github.com/bryanperez0/nfl-pick-em-league.git
cd nfl-pick-em-league
npm install
cp .env.example .env      # then open .env and paste your two Supabase values
npm run dev
```

Open the address it prints, usually <http://localhost:5173>. To view it on a phone, use your browser's device toolbar or run `npm run dev -- --host` and open the printed network address on a phone on the same Wi-Fi.

`.env` is listed in `.gitignore`, so it is never committed.

## Project layout

```
index.html                       page shell
src/App.jsx                      login check, top bar, bottom tabs
src/api.js                       talks to Supabase; saves the login token on the phone
src/time.js                      Eastern-time formatting
src/screens/JoinLogin.jsx        Log In / Join / New League
src/screens/Picks.jsx            this week's games and picks
src/screens/Leaderboard.jsx      standings
src/styles.css                   all styling (mobile-first)
supabase/migrations/0001_init.sql   tables, security, and all database functions
supabase/functions/sync-games/      ESPN sync Edge Function
netlify.toml                     Netlify build settings
```

## Changing things yourself

- **App name or colors:** change the name in `index.html` and the `Sunday Picks` text in `src/App.jsx` and `src/screens/JoinLogin.jsx`. Colors are at the top of `src/styles.css`.
- **Database changes:** don't edit `0001_init.sql` after you've run it. Add a new file, for example `0002_something.sql`, and run that in the SQL Editor.
- **A player forgot their PIN:** for now, run this in the SQL Editor, replacing the name, league code, and new PIN. Phase 3 adds a button for this.

  ```sql
  update players set pin_hash = extensions.crypt('5678', extensions.gen_salt('bf')),
                     failed_attempts = 0, locked_until = null
  where lower(display_name) = lower('Sam')
    and league_id = (select id from leagues where code = 'ABC123');
  ```
