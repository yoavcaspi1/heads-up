/**
 * In Your Face IPC handlers — Google auth, calendar events, settings, and
 * full-screen alert controls. Handlers stay thin; logic lives in services/.
 */
import { ipcMain, shell, logger } from "@glaze/core/backend";

import { getGoogleCredentials, setGoogleCredentials, clearGoogleCredentials } from "../services/google-credentials.js";
import {
  listAccounts,
  addAccount,
  removeAccount,
  removeAllAccounts,
  reconnectAccount,
  accountNeedsReconnect,
  anyAccountNeedsReconnect,
  credentialsAreInvalid,
  resetCredentialsInvalid,
} from "../services/google-accounts.js";
import { listAllCalendars } from "../services/google-calendar.js";
import { getSettings, updateSettings, type AppSettings } from "../services/settings-store.js";
import {
  getCachedEvents,
  isConnected,
  refresh,
  snooze,
  onSettingsChanged,
} from "../services/scheduler.js";
import {
  showAlert,
  dismissAlert,
  getCurrentAlert,
  type AlertPayload,
} from "../windows/alert-window.js";
import { applyTraySetting } from "../windows/tray.js";

function asMinutes(value: unknown): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0 || n > 120) {
    throw new Error("Snooze minutes must be a number between 1 and 120.");
  }
  return n;
}

export function registerInYourFaceHandlers(): void {
  // ── Auth / accounts ─────────────────────────────────────────────────
  ipcMain.handle("auth:status", async () => {
    const creds = await getGoogleCredentials();
    // Only the client ID is returned for display — the secret never leaves the backend.
    return {
      configured: creds !== null,
      connected: await isConnected(),
      clientId: creds?.clientId ?? null,
      needsReconnect: anyAccountNeedsReconnect(),
      credentialsInvalid: credentialsAreInvalid(),
    };
  });

  // Save the user's own OAuth client credentials (stored encrypted, per-user).
  ipcMain.handle("auth:setCredentials", async (_event, payload: unknown) => {
    const { clientId, clientSecret } = (payload ?? {}) as { clientId?: unknown; clientSecret?: unknown };
    if (typeof clientId !== "string" || typeof clientSecret !== "string") {
      throw new Error("Invalid credentials payload.");
    }
    await setGoogleCredentials(clientId, clientSecret);
    resetCredentialsInvalid();
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
    return { configured: true };
  });

  // Remove the stored credentials (and any accounts that depended on them).
  ipcMain.handle("auth:clearCredentials", async () => {
    await removeAllAccounts();
    await clearGoogleCredentials();
    resetCredentialsInvalid();
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
    return { configured: false };
  });

  ipcMain.handle("auth:accounts", async () => {
    return listAccounts().map((a) => ({
      id: a.id,
      email: a.email,
      name: a.name,
      needsReconnect: accountNeedsReconnect(a.id),
    }));
  });

  // Add a Google account (also used for the first connection).
  ipcMain.handle("auth:addAccount", async () => {
    const account = await addAccount();
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
    return { id: account.id, email: account.email, name: account.name, needsReconnect: false };
  });

  // Re-run OAuth for an existing account whose refresh token died (invalid_grant).
  ipcMain.handle("auth:reconnectAccount", async (_event, id: unknown) => {
    if (typeof id !== "string" || !id) {
      throw new Error("Invalid account id.");
    }
    const account = await reconnectAccount(id);
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
    return { id: account.id, email: account.email, name: account.name, needsReconnect: false };
  });

  ipcMain.handle("auth:removeAccount", async (_event, id: unknown) => {
    if (typeof id !== "string" || !id) {
      throw new Error("Invalid account id.");
    }
    await removeAccount(id);
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
  });

  ipcMain.handle("auth:disconnect", async () => {
    await removeAllAccounts();
    await refresh();
    ipcMain.broadcast("accounts:changed", {});
    return { connected: false };
  });

  // ── Calendar ────────────────────────────────────────────────────────
  ipcMain.handle("calendar:getEvents", async () => {
    return getCachedEvents();
  });

  ipcMain.handle("calendar:refresh", async () => {
    await refresh();
    return getCachedEvents();
  });

  ipcMain.handle("calendar:listAll", async () => {
    const calendars = await listAllCalendars();
    const disabled = new Set(getSettings().disabledCalendars);
    return calendars.map((c) => ({ ...c, enabled: !disabled.has(c.key) }));
  });

  // Look up the event in the shared cache (not renderer-supplied) so we only
  // ever open a link Google itself gave us, and open it in the default browser
  // — Google Calendar events aren't synced into macOS Calendar.app, so its
  // own web view is the "default calendar app" experience that actually works.
  ipcMain.handle("calendar:openEvent", async (_event, payload: unknown) => {
    const { id, start } = (payload ?? {}) as { id?: unknown; start?: unknown };
    if (typeof id !== "string" || !id || typeof start !== "string" || !start) {
      throw new Error("Invalid event reference.");
    }
    const match = getCachedEvents().find((e) => e.id === id && e.start === start);
    if (match?.htmlLink) {
      await shell.openExternal(match.htmlLink);
    }
  });

  ipcMain.handle("calendar:setEnabled", async (_event, payload: unknown) => {
    const { key, enabled } = (payload ?? {}) as { key?: unknown; enabled?: unknown };
    if (typeof key !== "string" || !key || typeof enabled !== "boolean") {
      throw new Error("Invalid calendar toggle payload.");
    }
    const disabled = new Set(getSettings().disabledCalendars);
    if (enabled) {
      disabled.delete(key);
    } else {
      disabled.add(key);
    }
    const next = updateSettings({ disabledCalendars: [...disabled] });
    onSettingsChanged();
    ipcMain.broadcast("settings:changed", { value: next });
    await refresh();
    return next;
  });

  // ── Settings ────────────────────────────────────────────────────────
  ipcMain.handle("settings:get", async () => {
    return getSettings();
  });

  ipcMain.handle("settings:set", async (_event, patch: unknown) => {
    if (typeof patch !== "object" || patch === null) {
      throw new Error("Invalid settings payload.");
    }
    const next: AppSettings = updateSettings(patch as Partial<AppSettings>);
    onSettingsChanged();
    applyTraySetting();
    ipcMain.broadcast("settings:changed", { value: next });
    return next;
  });

  // ── Alert controls ──────────────────────────────────────────────────
  ipcMain.handle("alert:getCurrent", async () => {
    return getCurrentAlert();
  });

  ipcMain.handle("alert:dismiss", async () => {
    dismissAlert();
  });

  ipcMain.handle("alert:snooze", async (_event, minutes: unknown) => {
    const mins = asMinutes(minutes);
    const current = getCurrentAlert();
    dismissAlert();
    if (current) {
      snooze(current, mins);
    }
  });

  ipcMain.handle("alert:join", async () => {
    const current = getCurrentAlert();
    if (current?.meetingUrl) {
      await shell.openExternal(current.meetingUrl);
    }
    dismissAlert();
  });

  ipcMain.handle("alert:test", async () => {
    const now = Date.now();
    const settings = getSettings();
    const test: AlertPayload = {
      id: `test-${now}`,
      title: "Test alert — this is how meetings will appear",
      start: new Date(now + settings.alertLeadTimes[0] * 60_000).toISOString(),
      end: new Date(now + 30 * 60_000).toISOString(),
      allDay: false,
      location: null,
      meetingUrl: null,
      meetingProvider: null,
      accountEmail: null,
      calendarName: null,
      htmlLink: null,
      isTest: true,
    };
    logger.info("alert", "Showing test alert");
    await showAlert(test);
  });
}
