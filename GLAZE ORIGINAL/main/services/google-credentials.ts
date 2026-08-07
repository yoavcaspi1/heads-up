/**
 * Per-user storage for the Google OAuth client credentials.
 *
 * The app no longer ships a developer-owned client ID/secret. Each user pastes
 * their own credentials in Settings; they are encrypted at rest with the native
 * safeStorage backend (same mechanism OAuthService uses for tokens) and never
 * committed to source or shared between users.
 */
import * as fs from "fs";
import * as path from "path";

import { app, logger, safeStorage } from "@glaze/core/backend";

export interface GoogleCredentials {
  clientId: string;
  clientSecret: string;
}

let cache: GoogleCredentials | null = null;
let loaded = false;

function credentialsPath(): string {
  return path.join(app.getPath("userData"), "google-credentials.enc");
}

/** Read + decrypt the credentials file once, then serve from the in-memory cache. */
async function ensureLoaded(): Promise<void> {
  if (loaded) {
    return;
  }
  loaded = true;
  try {
    const encrypted = fs.readFileSync(credentialsPath());
    const json = await safeStorage.decryptString(encrypted);
    const parsed = JSON.parse(json) as Partial<GoogleCredentials>;
    if (
      typeof parsed.clientId === "string" &&
      parsed.clientId.trim() &&
      typeof parsed.clientSecret === "string" &&
      parsed.clientSecret.trim()
    ) {
      cache = { clientId: parsed.clientId, clientSecret: parsed.clientSecret };
    }
  } catch {
    // No file yet, or it couldn't be decrypted (e.g. keychain changed) — treat as unconfigured.
    cache = null;
  }
}

export async function getGoogleCredentials(): Promise<GoogleCredentials | null> {
  await ensureLoaded();
  return cache;
}

export async function hasGoogleCredentials(): Promise<boolean> {
  return (await getGoogleCredentials()) !== null;
}

/** Persist the user's own client ID + secret (encrypted). */
export async function setGoogleCredentials(clientId: string, clientSecret: string): Promise<void> {
  const trimmedId = clientId.trim();
  const trimmedSecret = clientSecret.trim();
  if (!trimmedId || !trimmedSecret) {
    throw new Error("Both the client ID and client secret are required.");
  }
  if (!(await safeStorage.isEncryptionAvailable())) {
    throw new Error("Secure storage is unavailable on this Mac, so credentials can't be saved safely.");
  }

  const encrypted = await safeStorage.encryptString(
    JSON.stringify({ clientId: trimmedId, clientSecret: trimmedSecret }),
  );
  try {
    fs.writeFileSync(credentialsPath(), encrypted);
  } catch (error) {
    logger.error("google-credentials", "Failed to persist credentials", error);
    throw new Error("Could not save the Google credentials to disk.");
  }

  cache = { clientId: trimmedId, clientSecret: trimmedSecret };
  loaded = true;
  logger.info("google-credentials", "Saved Google OAuth credentials", { clientId: trimmedId });
}

/** Forget the stored credentials (used when the user disconnects / re-configures). */
export async function clearGoogleCredentials(): Promise<void> {
  try {
    fs.rmSync(credentialsPath(), { force: true });
  } catch (error) {
    logger.error("google-credentials", "Failed to remove credentials file", error);
  }
  cache = null;
  loaded = true;
}
