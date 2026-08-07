/**
 * Simple JSON-file settings store in the app's userData directory.
 * Holds non-sensitive preferences only — OAuth tokens live in OAuthService.
 */
import * as fs from "fs";
import * as path from "path";

import { app, logger } from "@glaze/core/backend";

export interface AppSettings {
  /** Minutes before an event starts to fire each of the two full-screen alerts. */
  alertLeadTimes: [number, number];
  /** Minutes for each of the two quick-snooze buttons shown on the alert. */
  snoozeDurations: [number, number];
  /** Master switch for full-screen alerts. */
  alertsEnabled: boolean;
  /** Calendars excluded from sync and alerts, keyed `${accountId}::${calendarId}`. */
  disabledCalendars: string[];
  /** Whether the menu bar (tray) icon showing the next meeting is shown. */
  menuBarCalendarEnabled: boolean;
  /** Full-screen alert surface: opaque theme color, or a native blur of whatever is behind it. */
  alertBackground: "solid" | "blur";
  /** Strength of the frosted tint over the native blur, 0 (barely tinted) to 100 (near-opaque). Only used when alertBackground is "blur". */
  alertBlurIntensity: number;
}

const DEFAULTS: AppSettings = {
  alertLeadTimes: [30, 5],
  snoozeDurations: [1, 5],
  alertsEnabled: true,
  disabledCalendars: [],
  menuBarCalendarEnabled: true,
  alertBackground: "solid",
  alertBlurIntensity: 30,
};

const ALLOWED_LEAD_TIMES = [0, 1, 2, 5, 10, 15, 30, 60];
const ALLOWED_SNOOZE_MINUTES = [1, 2, 5, 10, 15, 30, 60];

function settingsPath(): string {
  return path.join(app.getPath("userData"), "settings.json");
}

let cache: AppSettings | null = null;

export function getSettings(): AppSettings {
  if (cache) {
    return cache;
  }

  try {
    const raw = fs.readFileSync(settingsPath(), "utf-8");
    const parsed = JSON.parse(raw) as Partial<AppSettings>;
    cache = sanitize(parsed);
  } catch {
    cache = { ...DEFAULTS };
  }

  return cache;
}

export function updateSettings(patch: Partial<AppSettings>): AppSettings {
  const next = sanitize({ ...getSettings(), ...patch });
  cache = next;

  try {
    fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2), "utf-8");
  } catch (error) {
    logger.error("settings", "Failed to persist settings", error);
    throw new Error("Could not save settings to disk.");
  }

  return next;
}

function sanitizePair(input: unknown, allowed: number[], fallback: [number, number]): [number, number] {
  const arr = Array.isArray(input) ? input : [];
  return [0, 1].map((i) => {
    const n = Number(arr[i]);
    return allowed.includes(n) ? n : fallback[i];
  }) as [number, number];
}

function sanitizeDisabledCalendars(input: unknown): string[] {
  if (!Array.isArray(input)) {
    return [];
  }
  return [...new Set(input.filter((v): v is string => typeof v === "string"))];
}

function sanitize(input: Partial<AppSettings>): AppSettings {
  return {
    alertLeadTimes: sanitizePair(input.alertLeadTimes, ALLOWED_LEAD_TIMES, DEFAULTS.alertLeadTimes),
    snoozeDurations: sanitizePair(input.snoozeDurations, ALLOWED_SNOOZE_MINUTES, DEFAULTS.snoozeDurations),
    alertsEnabled: typeof input.alertsEnabled === "boolean" ? input.alertsEnabled : DEFAULTS.alertsEnabled,
    disabledCalendars: sanitizeDisabledCalendars(input.disabledCalendars),
    menuBarCalendarEnabled:
      typeof input.menuBarCalendarEnabled === "boolean"
        ? input.menuBarCalendarEnabled
        : DEFAULTS.menuBarCalendarEnabled,
    alertBackground: input.alertBackground === "blur" ? "blur" : DEFAULTS.alertBackground,
    alertBlurIntensity: sanitizeIntensity(input.alertBlurIntensity),
  };
}

function sanitizeIntensity(input: unknown): number {
  const n = Number(input);
  if (!Number.isFinite(n)) {
    return DEFAULTS.alertBlurIntensity;
  }
  return Math.min(100, Math.max(0, Math.round(n)));
}
