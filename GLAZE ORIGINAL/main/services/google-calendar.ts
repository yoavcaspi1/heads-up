/**
 * Google Calendar service — enumerates every calendar the connected accounts
 * can see (primary, secondary, shared, and delegated) and merges their
 * upcoming events into one normalized, de-duplicated list.
 */
import { logger } from "@glaze/core/backend";

import { listAccounts, getAccessTokenFor, type GoogleAccount } from "./google-accounts.js";
import { getSettings } from "./settings-store.js";

export interface CalendarInfo {
  /** Stable key for this calendar, `${accountId}::${calendarId}`. */
  key: string;
  accountEmail: string;
  calendarName: string;
  primary: boolean;
}

export interface CalendarEvent {
  id: string;
  title: string;
  /** ISO 8601 start time. */
  start: string;
  /** ISO 8601 end time. */
  end: string;
  allDay: boolean;
  location: string | null;
  /** Detected video-meeting URL, if any. */
  meetingUrl: string | null;
  /** "meet" | "zoom" | "teams" | "webex" | "other". */
  meetingProvider: string | null;
  /** Which connected account this event came from. */
  accountEmail: string | null;
  /** Human name of the source calendar. */
  calendarName: string | null;
  /** Google Calendar's own web view of this event, for "open in Calendar". */
  htmlLink: string | null;
}

interface GoogleEventDateTime {
  date?: string;
  dateTime?: string;
}

interface GoogleEntryPoint {
  entryPointType?: string;
  uri?: string;
}

interface GoogleEvent {
  id?: string;
  status?: string;
  summary?: string;
  location?: string;
  description?: string;
  hangoutLink?: string;
  htmlLink?: string;
  start?: GoogleEventDateTime;
  end?: GoogleEventDateTime;
  conferenceData?: { entryPoints?: GoogleEntryPoint[] };
}

interface CalendarListEntry {
  id?: string;
  summary?: string;
  summaryOverride?: string;
  primary?: boolean;
  deleted?: boolean;
  hidden?: boolean;
  accessRole?: string;
}

const MEETING_PATTERNS: Array<{ provider: string; re: RegExp }> = [
  { provider: "meet", re: /https:\/\/meet\.google\.com\/[^\s"'<>)]+/i },
  { provider: "zoom", re: /https:\/\/[a-z0-9.-]*zoom\.us\/[^\s"'<>)]+/i },
  { provider: "teams", re: /https:\/\/teams\.microsoft\.com\/[^\s"'<>)]+/i },
  { provider: "webex", re: /https:\/\/[a-z0-9.-]*webex\.com\/[^\s"'<>)]+/i },
];

function detectMeeting(event: GoogleEvent): { url: string | null; provider: string | null } {
  if (event.hangoutLink) {
    return { url: event.hangoutLink, provider: "meet" };
  }
  const video = event.conferenceData?.entryPoints?.find((p) => p.entryPointType === "video" && p.uri);
  if (video?.uri) {
    const match = MEETING_PATTERNS.find((m) => m.re.test(video.uri as string));
    return { url: video.uri, provider: match?.provider ?? "other" };
  }
  const haystack = `${event.location ?? ""}\n${event.description ?? ""}`;
  for (const { provider, re } of MEETING_PATTERNS) {
    const found = haystack.match(re);
    if (found) {
      return { url: found[0], provider };
    }
  }
  return { url: null, provider: null };
}

function normalize(
  event: GoogleEvent,
  accountEmail: string,
  calendarName: string,
): CalendarEvent | null {
  if (!event.id || event.status === "cancelled") {
    return null;
  }
  const allDay = Boolean(event.start?.date && !event.start?.dateTime);
  const start = event.start?.dateTime ?? event.start?.date;
  const end = event.end?.dateTime ?? event.end?.date;
  if (!start || !end) {
    return null;
  }
  const meeting = detectMeeting(event);
  return {
    id: event.id,
    title: event.summary?.trim() || "(No title)",
    start: new Date(start).toISOString(),
    end: new Date(end).toISOString(),
    allDay,
    location: event.location?.trim() || null,
    meetingUrl: meeting.url,
    meetingProvider: meeting.provider,
    accountEmail,
    calendarName,
    htmlLink: event.htmlLink?.trim() || null,
  };
}

async function apiGet<T>(url: string, accessToken: string): Promise<T> {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    logger.error("calendar", "Google request failed", { url, status: res.status, body });
    throw new Error(`Google Calendar API error (${res.status}).`);
  }
  return (await res.json()) as T;
}

async function listCalendars(accessToken: string): Promise<CalendarListEntry[]> {
  const data = await apiGet<{ items?: CalendarListEntry[] }>(
    "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&showHidden=false",
    accessToken,
  );
  return (data.items ?? []).filter((c) => c.id && !c.deleted && !c.hidden);
}

async function fetchCalendarEvents(
  calendarId: string,
  accessToken: string,
  timeMin: string,
  timeMax: string,
): Promise<GoogleEvent[]> {
  const params = new URLSearchParams({
    timeMin,
    timeMax,
    singleEvents: "true",
    orderBy: "startTime",
    maxResults: "50",
  });
  const url = `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events?${params.toString()}`;
  const data = await apiGet<{ items?: GoogleEvent[] }>(url, accessToken);
  return data.items ?? [];
}

function calendarKey(account: GoogleAccount, calendarId: string): string {
  return `${account.id}::${calendarId}`;
}

function calendarNameFor(cal: CalendarListEntry, account: GoogleAccount): string {
  return cal.summaryOverride || cal.summary || (cal.primary ? account.email : "Calendar");
}

/** Enumerate every calendar every connected account can see, for the settings UI. */
export async function listAllCalendars(): Promise<CalendarInfo[]> {
  const accounts = listAccounts();
  const perAccount = await Promise.all(
    accounts.map(async (account) => {
      const accessToken = await getAccessTokenFor(account);
      if (!accessToken) {
        return [];
      }
      try {
        const calendars = await listCalendars(accessToken);
        return calendars.map((cal) => ({
          key: calendarKey(account, cal.id as string),
          accountEmail: account.email,
          calendarName: calendarNameFor(cal, account),
          primary: Boolean(cal.primary),
        }));
      } catch (error) {
        logger.error("calendar", "Failed to list calendars", { email: account.email, error });
        return [];
      }
    }),
  );
  return perAccount.flat();
}

async function fetchAccountEvents(
  account: GoogleAccount,
  timeMin: string,
  timeMax: string,
  disabledKeys: Set<string>,
): Promise<CalendarEvent[]> {
  const accessToken = await getAccessTokenFor(account);
  if (!accessToken) {
    logger.warn("calendar", "No access token for account", { email: account.email });
    return [];
  }

  const calendars = (await listCalendars(accessToken)).filter(
    (cal) => !disabledKeys.has(calendarKey(account, cal.id as string)),
  );
  const perCalendar = await Promise.all(
    calendars.map(async (cal) => {
      const calendarName = calendarNameFor(cal, account);
      try {
        const events = await fetchCalendarEvents(cal.id as string, accessToken, timeMin, timeMax);
        return events
          .map((e) => normalize(e, account.email, calendarName))
          .filter((e): e is CalendarEvent => e !== null);
      } catch (error) {
        logger.error("calendar", "Failed to fetch a calendar", { calendar: cal.id, error });
        return [];
      }
    }),
  );

  return perCalendar.flat();
}

/**
 * Fetch events from every connected account and every calendar they can
 * access, from `daysBack` days ago through the next `daysAhead` days.
 */
export async function getUpcomingEvents(daysAhead = 2, daysBack = 0): Promise<CalendarEvent[]> {
  const accounts = listAccounts();
  if (accounts.length === 0) {
    return [];
  }

  const now = new Date();
  const timeMin = new Date(now.getTime() - daysBack * 24 * 60 * 60 * 1000).toISOString();
  const timeMax = new Date(now.getTime() + daysAhead * 24 * 60 * 60 * 1000).toISOString();
  const disabledKeys = new Set(getSettings().disabledCalendars);

  const perAccount = await Promise.all(
    accounts.map((account) =>
      fetchAccountEvents(account, timeMin, timeMax, disabledKeys).catch((error) => {
        logger.error("calendar", "Failed to fetch account events", { email: account.email, error });
        return [] as CalendarEvent[];
      }),
    ),
  );

  // De-duplicate the same meeting appearing on multiple calendars/accounts.
  const seen = new Set<string>();
  const merged: CalendarEvent[] = [];
  for (const event of perAccount.flat()) {
    const key = `${event.title}|${event.start}|${event.end}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    merged.push(event);
  }

  return merged.sort((a, b) => a.start.localeCompare(b.start));
}
