/**
 * Google OAuth configuration + a factory that creates one OAuthService per
 * connected account (each account stores its tokens under its own providerId).
 *
 * The OAuth client ID + secret are NOT hardcoded here — they are supplied by
 * each user in Settings and stored encrypted (see ./google-credentials.ts), so
 * the app never ships a developer-owned credential. Users create their own
 * client under "APIs & Services → Credentials" (Web application type) with
 * https://www.glaze.app/api/oauth/callback as an authorized redirect URI, and
 * enable the Google Calendar API on their project.
 */
import { OAuthService } from "@glaze/core/oauth";

import { getGoogleCredentials, hasGoogleCredentials } from "./google-credentials.js";

/** Providers key legacy single-account tokens were stored under. */
export const LEGACY_PROVIDER_ID = "google";

/** True once the user has saved their own OAuth client credentials. */
export async function isGoogleConfigured(): Promise<boolean> {
  return hasGoogleCredentials();
}

/** Create an OAuthService bound to a specific account's storage key. */
export async function createGoogleOAuth(providerId: string): Promise<OAuthService> {
  const creds = await getGoogleCredentials();
  if (!creds) {
    throw new Error("Google OAuth is not configured. Add your client ID and secret in Settings.");
  }

  return new OAuthService({
    providerId,
    clientId: creds.clientId,
    clientSecret: creds.clientSecret,
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    scopes: [
      "https://www.googleapis.com/auth/calendar.readonly",
      "openid",
      "email",
      "profile",
    ],
    // access_type=offline + prompt=consent guarantees a refresh token;
    // select_account lets the user choose a different account each time.
    extraAuthorizationParameters: {
      access_type: "offline",
      prompt: "select_account consent",
    },
  });
}

/** OAuthService for the legacy single-account token (used only for migration). */
export async function getLegacyGoogleOAuth(): Promise<OAuthService> {
  return createGoogleOAuth(LEGACY_PROVIDER_ID);
}
