import { useEffect, useState } from "react";
import { configured, rpc, loadToken, saveToken } from "./api.js";
import JoinLogin from "./screens/JoinLogin.jsx";
import Picks from "./screens/Picks.jsx";
import Leaderboard from "./screens/Leaderboard.jsx";

export default function App() {
  const [token, setToken] = useState(loadToken);
  const [me, setMe] = useState(null);
  const [checking, setChecking] = useState(Boolean(token));
  const [tab, setTab] = useState("picks");

  // On open, make sure the saved token still works.
  useEffect(() => {
    if (!token || me || !configured) return;
    rpc("get_me", { p_token: token })
      .then(setMe)
      .catch(() => signOut(false))
      .finally(() => setChecking(false));
  }, [token]);

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
        {tab === "picks" && <Picks token={token} onAuthError={() => signOut(false)} />}
        {tab === "board" && <Leaderboard token={token} me={me} />}
      </main>

      <nav className="tabs">
        <button className={tab === "picks" ? "active" : ""} onClick={() => setTab("picks")}>
          This Week's Picks
        </button>
        <button className={tab === "board" ? "active" : ""} onClick={() => setTab("board")}>
          Leaderboard
        </button>
      </nav>
    </>
  );
}
