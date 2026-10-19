// Every call to the database goes through this file.
// The browser only ever calls database *functions* (rpc), never tables.
import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const configured = Boolean(url && key);
const supabase = configured
  ? createClient(url, key, { auth: { persistSession: false } })
  : null;

// Call a database function and return its result, or throw a readable error.
export async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(error.message || "Something went wrong");
  if (data && data.error) throw new Error(data.error);
  return data;
}

// The login token is saved on this phone so the player stays logged in.
const TOKEN_KEY = "sunday-picks-token";

export function loadToken() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function saveToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    // Private browsing can block storage; the app still works until the tab closes.
  }
}
