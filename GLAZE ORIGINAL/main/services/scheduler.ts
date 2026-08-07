/**
 * Alert scheduler. Polls Google Calendar and fires a full-screen alert a
 * configurable number of minutes before each timed event starts.
 */
import { ipcMain, logger } from "@glaze/core/backend";

import { getUpcomingEvents, type CalendarEvent } from "./google-calendar.js";
import { isGoogleConfigured } from "./google-oauth.js";
import {
  hasAccounts,
  migrateLegacyAccount,
  anyAccountNeedsReconnect,
  credentialsAreInvalid,
} from "./google-accounts.js";
import { getSettings } from "./settings-store.js";
import { showAlert } from "../windows/alert-window.js";

const POLL_INTERVAL_MS = 60_000;
// Only arm a real timer for events firing within this window; later events get
// armed on a subsequent poll. Keeps the number of live timers small.
const SCHEDULE_HORIZON_MS = 6 * 60 * 60 * 1000;
// How far ahead to fetch events. Wider than the alert-scheduling horizon above
// so the tray/"next meeting" lookup can find something even if the next event
// on an enabled calendar is more than a few hours out (e.g. next week) — the
// main window's own list still narrows this down to 48h for display.
const EVENT_FETCH_DAYS_AHEAD = 30;
// How far back to fetch events, for the main window's calendar view (1 week
// back). Past events are never scheduled for alerts — `reschedule()` already
// skips anything that already started — so widening the cache backward is safe.
const EVENT_FETCH_DAYS_BACK = 7;

let events: CalendarEvent[] = [];
let pollTimer: ReturnType<typeof setInterval> | null = null;
const alertTimers = new Map<string, ReturnType<typeof setTimeout>>();
const snoozeTimers = new Map<string, ReturnType<typeof setTimeout>>();
// Event key -> timestamp the snooze will re-show it. While an event has an
// active snooze, its other configured lead-time alerts must not interrupt it.
const snoozedUntil = new Map<string, number>();
const fired = new Set<string>();
const eventsChangedListeners = new Set<() => void>();
// Last known "any account has a dead token" / "OAuth client is invalid" state,
// so a background poll that discovers (or clears) either can nudge the UI to
// re-read status.
let lastReconnectState = false;
let lastCredentialsInvalidState = false;

function broadcastReconnectStateIfChanged(): void {
  const reconnect = anyAccountNeedsReconnect();
  const credentialsInvalid = credentialsAreInvalid();
  if (reconnect !== lastReconnectState || credentialsInvalid !== lastCredentialsInvalidState) {
    lastReconnectState = reconnect;
    lastCredentialsInvalidState = credentialsInvalid;
    ipcMain.broadcast("accounts:changed", {});
  }
}

/**
 * Registers a callback fired synchronously whenever `events` is refreshed
 * (including the very first fetch right after startup), so listeners like the
 * tray don't have to wait for their own poll interval to pick up fresh data.
 * Returns an unsubscribe function.
 */
export function onEventsChanged(callback: () => void): () => void {
  eventsChangedListeners.add(callback);
  return () => eventsChangedListeners.delete(callback);
}

function notifyEventsChanged(): void {
  for (const listener of eventsChangedListeners) {
    listener();
  }
}

function keyFor(event: CalendarEvent): string {
  return `${event.id}@${event.start}`;
}

function timerKeyFor(event: CalendarEvent, leadMinutes: number): string {
  return `${keyFor(event)}@${leadMinutes}`;
}

function isSnoozed(event: CalendarEvent): boolean {
  return snoozedUntil.has(keyFor(event));
}

export function getCachedEvents(): CalendarEvent[] {
  return events;
}

export async function isConnected(): Promise<boolean> {
  return (await isGoogleConfigured()) && hasAccounts();
}

export function startScheduler(): void {
  if (pollTimer) {
    return;
  }
  void migrateLegacyAccount().finally(() => void refresh());
  pollTimer = setInterval(() => void refresh(), POLL_INTERVAL_MS);
}

export function stopScheduler(): void {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  clearAlertTimers();
  for (const t of snoozeTimers.values()) {
    clearTimeout(t);
  }
  snoozeTimers.clear();
  snoozedUntil.clear();
}

function clearAlertTimers(): void {
  for (const t of alertTimers.values()) {
    clearTimeout(t);
  }
  alertTimers.clear();
}

/** Re-fetch events and reschedule alert timers. Broadcasts the fresh list. */
export async function refresh(): Promise<void> {
  if (!(await isConnected())) {
    events = [];
    clearAlertTimers();
    ipcMain.broadcast("events:changed", { events });
    notifyEventsChanged();
    broadcastReconnectStateIfChanged();
    return;
  }

  try {
    events = await getUpcomingEvents(EVENT_FETCH_DAYS_AHEAD, EVENT_FETCH_DAYS_BACK);
  } catch (error) {
    logger.error("scheduler", "Failed to refresh events", error);
    return;
  }

  reschedule();
  ipcMain.broadcast("events:changed", { events });
  notifyEventsChanged();
  broadcastReconnectStateIfChanged();
}

function reschedule(): void {
  const settings = getSettings();
  clearAlertTimers();

  if (!settings.alertsEnabled) {
    return;
  }

  const now = Date.now();
  // De-dupe identical lead times so an event never fires twice for the same offset.
  const leadTimes = [...new Set(settings.alertLeadTimes)];

  for (const event of events) {
    if (event.allDay) {
      continue;
    }

    const startMs = new Date(event.start).getTime();

    // Already started — never worth alerting for.
    if (startMs <= now) {
      continue;
    }

    // A snooze in progress for this event takes priority — don't arm its
    // other lead-time alerts while we're waiting to re-show it.
    if (isSnoozed(event)) {
      continue;
    }

    for (const leadMinutes of leadTimes) {
      const timerKey = timerKeyFor(event, leadMinutes);
      if (fired.has(timerKey)) {
        continue;
      }

      const fireAt = startMs - leadMinutes * 60_000;

      if (fireAt <= now) {
        // We're inside the lead window already; fire immediately.
        trigger(event, leadMinutes);
      } else if (fireAt - now <= SCHEDULE_HORIZON_MS) {
        const timer = setTimeout(() => trigger(event, leadMinutes), fireAt - now);
        alertTimers.set(timerKey, timer);
      }
    }
  }
}

function trigger(event: CalendarEvent, leadMinutes: number): void {
  const timerKey = timerKeyFor(event, leadMinutes);
  alertTimers.delete(timerKey);

  // A timer armed before the snooze started can still fire while it's
  // pending — an active snooze wins. Leave `fired` unset so this lead time
  // still gets a chance to fire (via the next reschedule) once the snooze
  // re-surfaces the event and clears.
  if (isSnoozed(event)) {
    return;
  }

  fired.add(timerKey);
  logger.info("scheduler", "Triggering alert", { title: event.title, leadMinutes });
  void showAlert(event);
}

/** Re-show the current/last event after `minutes`, suppressing its other lead-time alerts until then. */
export function snooze(event: CalendarEvent, minutes: number): void {
  const key = keyFor(event);
  const existing = snoozeTimers.get(key);
  if (existing) {
    clearTimeout(existing);
  }
  snoozedUntil.set(key, Date.now() + minutes * 60_000);
  const timer = setTimeout(() => {
    snoozeTimers.delete(key);
    snoozedUntil.delete(key);
    void showAlert(event);
  }, minutes * 60_000);
  snoozeTimers.set(key, timer);
}

/** Called when settings change so lead-time edits take effect immediately. */
export function onSettingsChanged(): void {
  reschedule();
}
