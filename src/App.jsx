import { useEffect, useState } from "react";
import { configured, rpc, loadToken, saveToken } from "./api.js";
import JoinLogin from "./screens/JoinLogin.jsx";
import Picks from "./screens/Picks.jsx";
import Leaderboard from "./screens/Leaderboard.jsx";
import Admin from "./screens/Admin.jsx";

export default function App() {
  const [token, setToken] = useState(loadToken);
  const [me, setMe] = useState(null);
  const [checking, setChecking] = useState(Boolean(token));
  const [tab, setTab] = useState("picks");
  const [weeks, setWeeks] = useState(null);
  const [week, setWeek] = useState(null);

  // On open, make sure the saved token still works.
  useEffect(() => {
    if (!token || me || !configured) return;
    rpc("get_me", { p_token: token })
      .then(setMe)
      .catch(() => signOut(false))
      .finally(() => setChecking(false));
  }, [token]);

  // Once logged in, load the list of weeks and start on the current one.
  useEffect(() => {
    if (!me) return;
    Promise.all([rpc("get_weeks"), rpc("get_current_week")])
      .then(([all, current]) => {
        setWeeks(all);
        setWeek(current || all[all.length - 1] || null);
      })
      .catch(() => setWeeks([]));
  }, [me]);

  function signIn(result) {
    saveToken(result.token);
    setToken(result.token);
    setMe(result.me);
    setTab("picks");
  }

  async function signOut(callServer = true) {
    if (callServer && token) {
      try {
        await rpc("logout", { p_token: token });
      } catch {
        // Log out locally even if the server call fails.
      }
    }
    saveToken(null);
    setToken(null);
    setMe(null);
    setWeeks(null);
    setWeek(null);
    setChecking(false);
  }

  if (!configured) {
    return (
      <main className="page">
        <h1 className="brand">Sunday Picks</h1>
        <p className="error">
          The app isn't connected to its database yet. Set VITE_SUPABASE_URL and
          VITE_SUPABASE_ANON_KEY (see the README).
        </p>
      </main>
    );
  }

  if (checking) return <main className="page muted">Loading…</main>;
  if (!me) return <JoinLogin onSignedIn={signIn} />;

  const tabs = [
    ["picks", "Picks"],
    ["board", "Leaderboard"],
    ...(me.is_admin ? [["admin", "Admin"]] : []),
  ];
  const shared = { token, me, weeks: weeks || [], week, setWeek, onAuthError: () => signOut(false) };

  return (
    <>
      <header className="topbar">
        <div>
          <div className="brand small">Sunday Picks</div>
          <div className="muted tiny">
            {me.league_name} · code <strong>{me.league_code}</strong>
          </div>
        </div>
        <div className="me">
          <span>{me.display_name}</span>
          <button className="link" onClick={() => signOut()}>Log out</button>
        </div>
      </header>

      <main className="page">
        {!weeks ? (
          <p className="muted">Loading…</p>
        ) : !week && tab !== "admin" ? (
          <p className="muted">No games loaded yet. The schedule sync hasn't run.</p>
        ) : (
          <>
            {tab === "picks" && <Picks {...shared} />}
            {tab === "board" && <Leaderboard {...shared} />}
            {tab === "admin" && <Admin {...shared} />}
          </>
        )}
      </main>

      <nav className="tabs">
        {tabs.map(([key, label]) => (
          <button key={key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>
            {label}
          </button>
        ))}
      </nav>
    </>
  );
}
