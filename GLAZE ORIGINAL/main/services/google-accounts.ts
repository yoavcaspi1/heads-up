/**
 * Multi-account registry for Google sign-ins. Each account owns its own
 * OAuthService storage key (providerId); the registry (email → providerId)
 * lives in a small JSON file in userData. Tokens themselves stay in
 * OAuthService's safeStorage — never in this file.
 */
import * as fs from "fs";
import * as path from "path";

import { app, logger } from "@glaze/core/backend";

import { createGoogleOAuth, getLegacyGoogleOAuth, isGoogleConfigured, LEGACY_PROVIDER_ID } from "./google-oauth.js";

export interface GoogleAccount {
  /** Stable id = the account email. */
  id: string;
  email: string;
  name: string | null;
  /** Storage key for this account's OAuthService. */
  providerId: string;
}

interface UserInfo {
  email?: string;
  name?: string;
}

let cache: GoogleAccount[] | null = null;
let migrated = false;

/** Account ids whose refresh token Google has rejected (invalid_grant) — need re-auth. */
const needsReconnect = new Set<string>();

/**
 * Set when Google rejects the Client ID/Secret itself (invalid_client,
 * unauthorized_client) — every account fails the same way since they all
 * share the one OAuth client from Settings. Re-running sign-in (reconnect)
 * can't fix this; only re-entering correct credentials can.
 */
let credentialsInvalid = false;

function matchesProviderError(error: unknown, codes: string[]): boolean {
  if (typeof error !== "object" || error === null) {
    return false;
  }
  const e = error as { providerError?: unknown; code?: unknown; message?: unknown };
  return codes.some(
    (code) =>
      e.providerError === code ||
      e.code === code ||
      (typeof e.message === "string" && e.message.includes(code)),
  );
}

/** Detect Google's invalid_grant response (dead/revoked/expired refresh token). */
function isInvalidGrant(error: unknown): boolean {
  return matchesProviderError(error, ["invalid_grant"]);
}

/** Detect Google rejecting the OAuth client itself (bad/deleted Client ID or secret). */
function isInvalidClient(error: unknown): boolean {
  return matchesProviderError(error, ["invalid_client", "unauthorized_client"]);
}

export function accountNeedsReconnect(id: string): boolean {
  return needsReconnect.has(id);
}

export function anyAccountNeedsReconnect(): boolean {
  return load().some((a) => needsReconnect.has(a.id));
}

export function credentialsAreInvalid(): boolean {
  return credentialsInvalid;
}

/** Clear the invalid-client flag — call whenever the user (re)saves or removes credentials. */
export function resetCredentialsInvalid(): void {
  credentialsInvalid = false;
}

function registryPath(): string {
  return path.join(app.getPath("userData"), "accounts.json");
}

function load(): GoogleAccount[] {
  if (cache) {
    return cache;
  }
  try {
    const raw = fs.readFileSync(registryPath(), "utf-8");
    const parsed = JSON.parse(raw) as GoogleAccount[];
    cache = Array.isArray(parsed) ? parsed : [];
  } catch {
    cache = [];
  }
  return cache;
}

function persist(accounts: GoogleAccount[]): void {
  cache = accounts;
  try {
    fs.writeFileSync(registryPath(), JSON.stringify(accounts, null, 2), "utf-8");
  } catch (error) {
    logger.error("accounts", "Failed to persist account registry", error);
    throw new Error("Could not save the account list to disk.");
  }
}

async function fetchUserInfo(accessToken: string): Promise<UserInfo> {
  const res = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    return {};
  }
  return (await res.json()) as UserInfo;
}

/**
 * One-time migration: if a legacy single-account token exists but the registry
 * is empty, adopt it as the first account.
 */
export async function migrateLegacyAccount(): Promise<void> {
  if (migrated) {
    return;
  }
  migrated = true;

  if (!(await isGoogleConfigured()) || load().length > 0) {
    return;
  }

  const legacyOAuth = await getLegacyGoogleOAuth();
  const tokens = await legacyOAuth.getTokens();
  if (!tokens) {
    return;
  }

  try {
    const accessToken = await legacyOAuth.getAccessToken();
    const info = accessToken ? await fetchUserInfo(accessToken) : {};
    const email = info.email ?? "Google account";
    persist([
      { id: email, email, name: info.name ?? null, providerId: LEGACY_PROVIDER_ID },
    ]);
    logger.info("accounts", "Migrated legacy Google account", { email });
  } catch (error) {
    logger.error("accounts", "Legacy migration failed", error);
  }
}

export function listAccounts(): GoogleAccount[] {
  return load();
}

export function hasAccounts(): boolean {
  return load().length > 0;
}

/** Launch the browser OAuth flow and register the resulting account. */
export async function addAccount(): Promise<GoogleAccount> {
  if (!(await isGoogleConfigured())) {
    throw new Error("Google OAuth is not configured. Add your client ID and secret in Settings.");
  }

  const providerId = `google-${Date.now()}`;
  const oauth = await createGoogleOAuth(providerId);
  await oauth.authorize();

  const accessToken = await oauth.getAccessToken();
  const info = accessToken ? await fetchUserInfo(accessToken) : {};
  const email = info.email ?? providerId;

  const accounts = load();
  const existing = accounts.find((a) => a.id === email);
  if (existing) {
    // Already connected — move the fresh tokens onto the existing entry so a
    // re-add doubles as a reconnect, then drop the duplicate provider tokens.
    needsReconnect.delete(existing.id);
    await oauth.removeTokens();
    logger.info("accounts", "Account already connected", { email });
    return existing;
  }

  const account: GoogleAccount = { id: email, email, name: info.name ?? null, providerId };
  needsReconnect.delete(email);
  persist([...accounts, account]);
  logger.info("accounts", "Added Google account", { email });
  return account;
}

/** Re-run the OAuth flow for an existing account to replace its dead tokens. */
export async function reconnectAccount(id: string): Promise<GoogleAccount> {
  if (!(await isGoogleConfigured())) {
    throw new Error("Google OAuth is not configured. Add your client ID and secret in Settings.");
  }
  const accounts = load();
  const account = accounts.find((a) => a.id === id);
  if (!account) {
    throw new Error("That account is no longer connected.");
  }

  // Re-authorize under the SAME providerId so fresh tokens overwrite the dead ones.
  const oauth = await createGoogleOAuth(account.providerId);
  await oauth.authorize();

  // Guard against the user picking a different Google account during consent.
  const accessToken = await oauth.getAccessToken();
  const info = accessToken ? await fetchUserInfo(accessToken) : {};
  if (info.email && info.email !== account.id) {
    await oauth.removeTokens();
    throw new Error(
      `Signed in as ${info.email}, but this account is ${account.email}. Choose the same account to reconnect.`,
    );
  }

  needsReconnect.delete(id);
  logger.info("accounts", "Reconnected Google account", { email: account.email });
  return account;
}

export async function removeAccount(id: string): Promise<void> {
  const accounts = load();
  const account = accounts.find((a) => a.id === id);
  if (!account) {
    return;
  }
  await removeTokensFor(account);
  needsReconnect.delete(id);
  persist(accounts.filter((a) => a.id !== id));
  logger.info("accounts", "Removed Google account", { email: account.email });
}

export async function removeAllAccounts(): Promise<void> {
  const accounts = load();
  for (const account of accounts) {
    await removeTokensFor(account);
  }
  needsReconnect.clear();
  persist([]);
}

/**
 * Best-effort token removal. Credentials may already be gone (e.g. the user is
 * clearing them), so tolerate an unconfigured client rather than orphaning the
 * registry entry.
 */
async function removeTokensFor(account: GoogleAccount): Promise<void> {
  if (!(await isGoogleConfigured())) {
    return;
  }
  try {
    await (await createGoogleOAuth(account.providerId)).removeTokens();
  } catch (error) {
    logger.error("accounts", "Failed to remove tokens", { email: account.email, error });
  }
}

/**
 * Return a valid access token for an account, or null if it can't refresh.
 * A dead/revoked refresh token (invalid_grant) flags the account as needing
 * reconnect so the UI can surface it instead of silently showing no data.
 */
export async function getAccessTokenFor(account: GoogleAccount): Promise<string | null> {
  if (!(await isGoogleConfigured())) {
    return null;
  }
  try {
    const token = await (await createGoogleOAuth(account.providerId)).getAccessToken();
    needsReconnect.delete(account.id);
    credentialsInvalid = false;
    return token;
  } catch (error) {
    if (isInvalidClient(error)) {
      credentialsInvalid = true;
      logger.warn(
        "accounts",
        "OAuth client rejected (invalid_client) — Client ID/Secret in Settings don't match a real Google OAuth app",
        { email: account.email },
      );
      return null;
    }
    if (isInvalidGrant(error)) {
      needsReconnect.add(account.id);
      logger.warn("accounts", "Refresh token rejected (invalid_grant) — account needs reconnect", {
        email: account.email,
      });
      return null;
    }
    // Transient errors (network, 5xx) — don't mark the account dead.
    logger.error("accounts", "Failed to get access token", { email: account.email, error });
    return null;
  }
}
