// Cognito Managed Login using the authorization code flow with PKCE.
// Tokens live in sessionStorage only (cleared when the tab closes).

const DOMAIN = import.meta.env.VITE_COGNITO_DOMAIN as string;
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID as string;
const REDIRECT = `${window.location.origin}/`;
const KEY = "dt_id_token";

function b64url(bytes: ArrayBuffer | Uint8Array) {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return btoa(String.fromCharCode(...arr)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomString() {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

function configured() {
  if (!DOMAIN || !CLIENT_ID) {
    throw new Error("Cognito configuration is missing. Set VITE_COGNITO_DOMAIN and VITE_COGNITO_CLIENT_ID.");
  }
}

function claims(token: string): any {
  try {
    const segment = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = segment + "=".repeat((4 - (segment.length % 4)) % 4);
    return JSON.parse(atob(padded));
  } catch {
    return {};
  }
}

export function getToken(): string | null {
  const t = sessionStorage.getItem(KEY);
  if (!t) return null;
  const exp = claims(t).exp ?? 0;
  if (Date.now() / 1000 > exp - 30) {
    sessionStorage.removeItem(KEY);
    return null;
  }
  return t;
}

export function userEmail(): string {
  const t = getToken();
  return t ? claims(t).email ?? "" : "";
}

export async function login() {
  configured();
  const verifier = randomString();
  const state = randomString();
  sessionStorage.setItem("pkce_verifier", verifier);
  sessionStorage.setItem("pkce_state", state);
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const qs = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT,
    scope: "openid email",
    state,
    code_challenge_method: "S256",
    code_challenge: challenge,
  });
  window.location.assign(`${DOMAIN}/oauth2/authorize?${qs}`);
}

export function logout() {
  configured();
  sessionStorage.removeItem(KEY);
  const qs = new URLSearchParams({ client_id: CLIENT_ID, logout_uri: REDIRECT });
  window.location.assign(`${DOMAIN}/logout?${qs}`);
}

/** Finish a login redirect if present. Returns true when the user is signed in. */
export async function completeLogin(): Promise<boolean> {
  configured();
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  if (code) {
    const state = params.get("state");
    const verifier = sessionStorage.getItem("pkce_verifier");
    const expected = sessionStorage.getItem("pkce_state");
    sessionStorage.removeItem("pkce_verifier");
    sessionStorage.removeItem("pkce_state");
    window.history.replaceState({}, "", "/");
    if (!verifier || !state || state !== expected) return false;
    const res = await fetch(`${DOMAIN}/oauth2/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: CLIENT_ID,
        code,
        redirect_uri: REDIRECT,
        code_verifier: verifier,
      }),
    });
    if (!res.ok) return false;
    const body = await res.json();
    if (body.id_token) sessionStorage.setItem(KEY, body.id_token);
  }
  return getToken() !== null;
}
