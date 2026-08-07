/**
 * Thin typed wrappers around the backend IPC handlers so both the main window
 * and the alert window share one contract.
 */

export interface CalendarEvent {
  id: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  location: string | null;
  meetingUrl: string | null;
  meetingProvider: string | null;
  accountEmail?: string | null;
  calendarName?: string | null;
  htmlLink?: string | null;
  isTest?: boolean;
}

export interface AppSettings {
  alertLeadTimes: [number, number];
  snoozeDurations: [number, number];
  alertsEnabled: boolean;
  disabledCalendars: string[];
  menuBarCalendarEnabled: boolean;
  alertBackground: "solid" | "blur";
  /** Strength of the frosted tint over the native blur, 0 (barely tinted) to 100 (near-opaque). */
  alertBlurIntensity: number;
}

export interface CalendarInfo {
  key: string;
  accountEmail: string;
  calendarName: string;
  primary: boolean;
  enabled: boolean;
}

export interface AuthStatus {
  configured: boolean;
  connected: boolean;
  /** The saved OAuth client ID (for display). Null when not yet configured. */
  clientId: string | null;
  /** True when at least one connected account's token is dead and needs re-auth. */
  needsReconnect: boolean;
  /** True when Google rejected the Client ID/Secret itself — fix in Settings, reconnect won't help. */
  credentialsInvalid: boolean;
}

export interface GoogleAccount {
  id: string;
  email: string;
  name: string | null;
  /** True when this account's refresh token was rejected (invalid_grant). */
  needsReconnect: boolean;
}

function invoke<T>(channel: string, ...args: unknown[]): Promise<T> {
  return window.glazeAPI.glaze.ipc.invoke<T>(channel, ...args);
}

/** Subscribe to a backend broadcast; returns an unsubscribe function. */
export function onBroadcast(channel: string, callback: (payload: unknown) => void): () => void {
  return window.glazeAPI.glaze.ipc.on(channel, (_event, payload) => callback(payload));
}

export const api = {
  getAuthStatus: () => invoke<AuthStatus>("auth:status"),
  setCredentials: (clientId: string, clientSecret: string) =>
    invoke<{ configured: boolean }>("auth:setCredentials", { clientId, clientSecret }),
  clearCredentials: () => invoke<{ configured: boolean }>("auth:clearCredentials"),
  getAccounts: () => invoke<GoogleAccount[]>("auth:accounts"),
  addAccount: () => invoke<GoogleAccount>("auth:addAccount"),
  reconnectAccount: (id: string) => invoke<GoogleAccount>("auth:reconnectAccount", id),
  removeAccount: (id: string) => invoke<void>("auth:removeAccount", id),
  disconnect: () => invoke<{ connected: boolean }>("auth:disconnect"),

  getEvents: () => invoke<CalendarEvent[]>("calendar:getEvents"),
  refreshEvents: () => invoke<CalendarEvent[]>("calendar:refresh"),
  listCalendars: () => invoke<CalendarInfo[]>("calendar:listAll"),
  setCalendarEnabled: (key: string, enabled: boolean) =>
    invoke<AppSettings>("calendar:setEnabled", { key, enabled }),
  openEvent: (event: { id: string; start: string }) => invoke<void>("calendar:openEvent", event),

  getSettings: () => invoke<AppSettings>("settings:get"),
  setSettings: (patch: Partial<AppSettings>) => invoke<AppSettings>("settings:set", patch),

  openSettings: () => invoke<void>("window:openSettings"),

  getCurrentAlert: () => invoke<CalendarEvent | null>("alert:getCurrent"),
  dismissAlert: () => invoke<void>("alert:dismiss"),
  snoozeAlert: (minutes: number) => invoke<void>("alert:snooze", minutes),
  joinMeeting: () => invoke<void>("alert:join"),
  testAlert: () => invoke<void>("alert:test"),
};
