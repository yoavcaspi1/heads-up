/**
 * Full-screen meeting alert. Opens one always-on-top window on every display so
 * the alert is impossible to miss (opaque or native-blurred per settings), and
 * tears them all down on dismiss.
 */
import { BrowserWindow, screen, ipcMain, logger } from "@glaze/core/backend";

import type { CalendarEvent } from "../services/google-calendar.js";
import { getSettings } from "../services/settings-store.js";
import { getPreloadPath, getWindowUrl } from "./window-paths.js";

export interface AlertPayload extends CalendarEvent {
  /** True when triggered by the "Test alert" button rather than a real event. */
  isTest?: boolean;
}

let alertWindows: BrowserWindow[] = [];
let currentEvent: AlertPayload | null = null;
// True from the moment we commit to building the windows until they're all created.
// Window creation spans several `await`s before the first window lands in
// `alertWindows`, so two triggers firing close together (e.g. an event's two lead
// times, or a relaunch re-arming both) would each see an empty `alertWindows`, pass
// the guard, and stack a second set of windows under the same windowKey. This flag
// closes that gap synchronously so the second call swaps content instead.
let opening = false;

export function getCurrentAlert(): AlertPayload | null {
  return currentEvent;
}

export function isAlertOpen(): boolean {
  return alertWindows.length > 0 || opening;
}

export async function showAlert(event: AlertPayload): Promise<void> {
  currentEvent = event;

  // If an alert is already on screen (or mid-creation), just swap its content —
  // the mounting/existing windows read the latest `currentEvent`, so no new window.
  if (alertWindows.length > 0 || opening) {
    ipcMain.broadcast("alert:update", event);
    return;
  }
  opening = true;

  try {
    const displays = screen.getAllDisplays();
    const primaryId = screen.getPrimaryDisplay().id;
    let primaryWin: BrowserWindow | null = null;
    const settings = getSettings();
    const blurred = settings.alertBackground === "blur";
    logger.info("alert", "Showing full-screen alert", { title: event.title, displays: displays.length, blurred });

    const baseUrl = await getWindowUrl("alert-window.html");
    const url = blurred ? `${baseUrl}?bg=blur&intensity=${settings.alertBlurIntensity}` : baseUrl;

    for (const display of displays) {
      const { x, y, width, height } = display.bounds;

      // Both modes are frameless and edge-to-edge so the alert covers the ENTIRE
      // display (including the menu bar) with square corners — the right shape for a
      // full-screen overlay. A native frame would inset the window below the menu bar
      // and round its corners, making the blur read as a floating panel with the
      // desktop showing around it. The solid surface paints its own opaque fill; the
      // blurred surface stays transparent and gets a native vibrancy material applied
      // after creation (see below), which the transparent renderer lets show through.
      const win = new BrowserWindow({
        windowKey: `alert-${display.id}`,
        x,
        y,
        width,
        height,
        frame: false,
        transparent: blurred,
        backgroundColor: blurred ? "#00000000" : "#ececec",
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        hasShadow: false,
        alwaysOnTop: true,
        show: false,
        webPreferences: {
          preload: getPreloadPath(),
        },
      });

      if (blurred) {
        // Native macOS blur of whatever is behind the (transparent) window. Applied
        // after creation because the frameless window itself supplies the full-screen
        // shape — vibrancy is only the material painted into it.
        win.setVibrancy("fullscreen-ui");
      }

      // "screen-saver" is the highest standard level — it sits above the menu bar,
      // the Dock, and other full-screen apps.
      win.setAlwaysOnTop(true, "screen-saver");
      win.setBounds({ x, y, width, height });
      // Without this, the window is pinned to whichever Space was active when it was
      // created and won't follow the user if they switch Spaces (or a full-screen app)
      // before/while the alert is up — defeating "unmissable". skipTransformProcessType
      // is required here: this app runs with activationPolicy "accessory" (no Dock icon),
      // and without that flag setVisibleOnAllWorkspaces briefly flips the process to a
      // regular app to join all Spaces, then flips back — which drops the window's
      // all-Spaces membership right after, leaving it visible only on its origin Space.
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });

      win.once("ready-to-show", () => {
        win.show();
        win.moveTop();
      });

      win.on("closed", () => {
        alertWindows = alertWindows.filter((w) => w !== win);
      });

      if (display.id === primaryId) {
        primaryWin = win;
      }
      alertWindows.push(win);
      await win.loadURL(url);
    }

    // Focus the primary-display window so buttons receive clicks and keys.
    (primaryWin ?? alertWindows[0])?.focus();
  } finally {
    opening = false;
  }
}

export function dismissAlert(): void {
  logger.info("alert", "Dismissing alert", { windows: alertWindows.length });
  currentEvent = null;
  opening = false;
  const toClose = alertWindows;
  alertWindows = [];
  for (const win of toClose) {
    if (!win.isDestroyed()) {
      win.close();
    }
  }
}
