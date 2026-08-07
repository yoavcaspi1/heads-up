/**
 * Menu bar (status item) integration: shows the next upcoming meeting at a
 * glance. Left-click toggles the main window, right-click opens a context
 * menu (Settings, Quit). Refreshes immediately whenever the scheduler's cached
 * events change (`onEventsChanged`, including the first fetch after launch),
 * plus a 30s poll to keep the countdown text current between refreshes.
 */
import { app, Menu, Tray } from "@glaze/core/backend";

import type { CalendarEvent } from "../services/google-calendar.js";
import { getCachedEvents, onEventsChanged } from "../services/scheduler.js";
import { getSettings } from "../services/settings-store.js";
import { openSettingsWindow } from "./settings-window.js";

const TICK_INTERVAL_MS = 30_000;

// SF Symbol glyph, not the app's own bitmap icon: the bell's gradients/glass
// reflections read as a blurry smudge once shrunk to actual menu-bar size
// (~16-18px), and this bridge has no HiDPI scale channel to compensate (a
// larger source bitmap renders oversized instead of sharper — see git history
// on this file). A vector SF Symbol stays crisp at any size and free of that
// problem entirely. Outline (non-".fill") variant — passing `color` switches
// the Tray image from template (monochrome, adapts to light/dark) to
// full-color rendering. Color reflects today's meeting state: blue while a
// meeting is still upcoming, green once none remain.
const TRAY_ICON = "bell";
const TRAY_ICON_COLOR_ACTIVE = "blue";
const TRAY_ICON_COLOR_DONE = "green";

let tray: Tray | null = null;
let onToggleCalendar: (() => void) | null = null;
let currentIconColor: string | null = null;
let tickTimer: ReturnType<typeof setInterval> | null = null;
let unsubscribeEventsChanged: (() => void) | null = null;
let creatingTray = false;

function formatClock(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function formatCountdown(startMs: number, now: number): string {
  const diffMin = Math.round((startMs - now) / 60_000);
  if (diffMin <= 0) return "starting now";
  if (diffMin < 60) return `in ${diffMin} min`;
  const hours = Math.floor(diffMin / 60);
  const mins = diffMin % 60;
  if (hours < 24) return mins ? `in ${hours}h ${mins}m` : `in ${hours}h`;
  const days = Math.round(hours / 24);
  return `in ${days}d`;
}

/** True if `iso` falls on today's local calendar date. */
function isToday(iso: string): boolean {
  const d = new Date(iso);
  const now = new Date();
  return (
    d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  );
}

/** All events sharing `event`'s start time, so simultaneous meetings display together. */
function simultaneousWith(event: CalendarEvent, pool: CalendarEvent[]): CalendarEvent[] {
  const startMs = new Date(event.start).getTime();
  return pool.filter((e) => new Date(e.start).getTime() === startMs);
}

/** The next event(s) to show — more than one when several meetings start at the same time. */
function nextEvents(events: CalendarEvent[]): CalendarEvent[] {
  const now = Date.now();
  const timed = events.filter((e) => !e.allDay);

  // Prefer the next meeting(s) that haven't started yet — an ongoing meeting
  // shouldn't keep showing once a later one is coming up.
  const upcoming = timed
    .filter((e) => new Date(e.start).getTime() > now)
    .sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime());
  if (upcoming[0]) {
    return simultaneousWith(upcoming[0], upcoming);
  }

  // Nothing hasn't-started-yet — fall back to one still in progress (end still
  // in the future) so the tray doesn't go blank while a meeting is ongoing.
  const ongoing = timed
    .filter((e) => new Date(e.end).getTime() > now)
    .sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime());
  return ongoing[0] ? simultaneousWith(ongoing[0], ongoing) : [];
}

/** Swaps the tray glyph's tint, skipping the call when the color is already current. */
function setIconColor(color: string): void {
  if (!tray || color === currentIconColor) {
    return;
  }
  currentIconColor = color;
  tray.setImage(TRAY_ICON, { color });
}

/** Refresh the tray's title/tooltip/icon color with the next upcoming event. */
function tick(): void {
  if (!tray || tray.isDestroyed()) {
    return;
  }

  const events = nextEvents(getCachedEvents());
  const event = events[0] ?? null;
  // No event left today (none at all, or the next one is tomorrow+) — clear
  // the title so only the icon shows, instead of jumping ahead to a future
  // day's meeting. The tooltip still explains the icon-only state on hover.
  if (!event || !isToday(event.start)) {
    tray.setTitle("");
    tray.setToolTip("Heads Up — no more meetings today");
    setIconColor(TRAY_ICON_COLOR_DONE);
    return;
  }

  // Several meetings can start at the same time — join their titles ("Meeting
  // 1 & Meeting 2") rather than picking one and hiding the rest.
  const titleText = events.map((e) => e.title).join(" & ");
  const startMs = new Date(event.start).getTime();
  tray.setTitle(`${titleText} · ${formatClock(event.start)} (${formatCountdown(startMs, Date.now())})`);

  const details = [
    `${formatClock(event.start)}–${formatClock(event.end)}`,
    event.calendarName,
    event.location,
  ].filter(Boolean);
  tray.setToolTip(`${titleText}\n${details.join(" · ")}`);
  setIconColor(TRAY_ICON_COLOR_ACTIVE);
}

async function createTray(): Promise<void> {
  if (tray || creatingTray) {
    return;
  }
  creatingTray = true;

  try {
    if (tray) {
      return;
    }

    tray = new Tray(TRAY_ICON, { color: TRAY_ICON_COLOR_ACTIVE });
    currentIconColor = TRAY_ICON_COLOR_ACTIVE;
    const menu = Menu.buildFromTemplate([
      { label: "Settings…", click: () => void openSettingsWindow() },
      { type: "separator" },
      { label: "Quit", click: () => app.quit() },
    ]);
    // Not setContextMenu(): on macOS that shows the menu on every click (left and
    // right), not just right-click. Pop it manually so left-click stays free to
    // toggle the calendar.
    tray.on("click", () => onToggleCalendar?.());
    tray.on("right-click", () => tray?.popUpContextMenu(menu));

    tick();
    tickTimer = setInterval(tick, TICK_INTERVAL_MS);
    unsubscribeEventsChanged = onEventsChanged(tick);
  } finally {
    creatingTray = false;
  }
}

function removeTray(): void {
  if (tickTimer) {
    clearInterval(tickTimer);
    tickTimer = null;
  }
  unsubscribeEventsChanged?.();
  unsubscribeEventsChanged = null;
  tray?.destroy();
  tray = null;
  currentIconColor = null;
}

/** Create the menu bar icon (if the "Menu bar calendar" setting is on). Click toggles the calendar; right-click shows Settings/Quit. */
export function initTray(handlers: { onToggleCalendar: () => void }): void {
  onToggleCalendar = handlers.onToggleCalendar;
  if (getSettings().menuBarCalendarEnabled) {
    void createTray();
  }
}

/** Call after settings change so the tray icon appears/disappears immediately. */
export function applyTraySetting(): void {
  if (getSettings().menuBarCalendarEnabled) {
    void createTray();
  } else {
    removeTray();
  }
}

export function destroyTray(): void {
  removeTray();
}
