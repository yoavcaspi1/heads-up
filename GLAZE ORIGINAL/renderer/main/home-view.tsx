import { useEffect, useRef, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  ScrollArea,
  Toolbar,
  ToolbarRow,
  ToolbarContent,
  ToolbarTitle,
  ToolbarActions,
  Button,
  Callout,
  EmptyState,
  Text,
  Badge,
  List,
  toast,
} from "@glaze/core/components";
import { cn } from "@glaze/core/utils";
import { CalendarDays, Video, RefreshCw, MonitorPlay, Settings, AlertTriangle } from "lucide-react";

import { api, onBroadcast, type CalendarEvent, type AuthStatus } from "../shared/api";

function useNow(intervalMs = 30_000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

function relativeTime(startMs: number, now: number): string {
  const diffMin = Math.round((startMs - now) / 60000);
  if (diffMin <= 0) return "now";
  if (diffMin < 60) return `in ${diffMin} min`;
  const hours = Math.floor(diffMin / 60);
  const mins = diffMin % 60;
  if (hours < 24) return mins ? `in ${hours} h ${mins} min` : `in ${hours} h`;
  const days = Math.round(hours / 24);
  return `in ${days} day${days > 1 ? "s" : ""}`;
}

/** Whole calendar days between `iso`'s local day and today's local day (negative = past). */
function dayDiff(iso: string): number {
  const d = new Date(iso);
  d.setHours(0, 0, 0, 0);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.round((d.getTime() - today.getTime()) / (24 * 60 * 60 * 1000));
}

function dayLabel(iso: string): string {
  const diff = dayDiff(iso);
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  if (diff === -1) return "Yesterday";
  return new Date(iso).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}

function clock(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

interface DaySection {
  dayKey: string;
  diff: number;
  events: CalendarEvent[];
}

/** Groups already-sorted events into consecutive same-day buckets. */
function groupByDay(events: CalendarEvent[]): DaySection[] {
  const sections: DaySection[] = [];
  for (const event of events) {
    const dayKey = new Date(event.start).toDateString();
    const last = sections[sections.length - 1];
    if (last && last.dayKey === dayKey) {
      last.events.push(event);
    } else {
      sections.push({ dayKey, diff: dayDiff(event.start), events: [event] });
    }
  }
  return sections;
}

export function HomeView() {
  const qc = useQueryClient();
  const now = useNow();

  const authQuery = useQuery<AuthStatus>({ queryKey: ["auth"], queryFn: api.getAuthStatus });
  const eventsQuery = useQuery<CalendarEvent[]>({
    queryKey: ["events"],
    queryFn: api.getEvents,
    enabled: authQuery.data?.connected ?? false,
  });

  // Live updates pushed from the backend scheduler.
  useEffect(() => {
    const offEvents = onBroadcast("events:changed", (payload) => {
      const p = payload as { events?: CalendarEvent[] };
      if (p?.events) qc.setQueryData(["events"], p.events);
    });
    const offAccounts = onBroadcast("accounts:changed", () => {
      void qc.invalidateQueries({ queryKey: ["auth"] });
      void qc.invalidateQueries({ queryKey: ["events"] });
    });
    return () => {
      offEvents();
      offAccounts();
    };
  }, [qc]);

  const connectMutation = useMutation({
    mutationFn: api.addAccount,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["auth"] });
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["events"] });
    },
    onError: (e) => toast.error(`Couldn't connect: ${String(e)}`),
  });

  const refreshMutation = useMutation({
    mutationFn: api.refreshEvents,
    onSuccess: (events) => qc.setQueryData(["events"], events),
    onError: (e) => toast.error(`Refresh failed: ${String(e)}`),
  });

  const openEventMutation = useMutation({
    mutationFn: api.openEvent,
    onError: (e) => toast.error(`Couldn't open event: ${String(e)}`),
  });

  const status = authQuery.data;
  const allEvents = eventsQuery.data ?? [];
  // The backend fetches a much wider window (1 week back, 30 days ahead) so
  // the tray can always find the next meeting — narrow the visible calendar
  // down to 1 week back / 1 week forward around today.
  const events = allEvents.filter((e) => Math.abs(dayDiff(e.start)) <= 7);
  const daySections = groupByDay(events);
  const multiAccount = new Set(events.map((e) => e.accountEmail).filter(Boolean)).size > 1;

  // Open the calendar scrolled to today (or the next upcoming day) so the past
  // week sits above the fold rather than being what you land on. Runs once, as
  // soon as the anchored section has rendered.
  const todayAnchorKey = daySections.find((s) => s.diff >= 0)?.dayKey ?? null;
  const didScrollToTodayRef = useRef(false);
  useEffect(() => {
    if (didScrollToTodayRef.current || !todayAnchorKey) return;
    const el = document.getElementById("calendar-today-anchor");
    if (el) {
      el.scrollIntoView({ block: "start" });
      didScrollToTodayRef.current = true;
    }
  }, [todayAnchorKey, events.length]);

  return (
    <ScrollArea
      className="h-full"
      toolbar={
        <Toolbar>
          <ToolbarRow>
            <ToolbarContent>
              <ToolbarTitle>Upcoming</ToolbarTitle>
            </ToolbarContent>
            <ToolbarActions>
              <Button
                variant="glass"
                size="large"
                onClick={() => void api.testAlert()}
                title="Preview the full-screen alert"
              >
                <MonitorPlay />
                Test alert
              </Button>
              {status?.connected ? (
                <Button
                  variant="glass"
                  size="large"
                  iconOnly
                  disabled={refreshMutation.isPending}
                  onClick={() => refreshMutation.mutate()}
                  title="Refresh events"
                >
                  <RefreshCw className={refreshMutation.isPending ? "animate-spin" : undefined} />
                </Button>
              ) : null}
              <Button
                variant="glass"
                size="large"
                iconOnly
                onClick={() => void api.openSettings()}
                title="Settings"
              >
                <Settings />
              </Button>
            </ToolbarActions>
          </ToolbarRow>
        </Toolbar>
      }
    >
      <div className="px-4 pb-10 flex flex-col gap-6">
        {status && !status.configured ? (
          <Callout
            color="orange"
            icon={<CalendarDays />}
            actions={
              <Button variant="transparent" onClick={() => void api.openSettings()}>
                Open Settings
              </Button>
            }
          >
            Google Calendar isn't set up yet. Add your Google OAuth client ID and secret in Settings to
            enable calendar sync.
          </Callout>
        ) : null}

        {status && status.configured && status.credentialsInvalid ? (
          <Callout
            color="orange"
            icon={<AlertTriangle />}
            actions={
              <Button variant="transparent" onClick={() => void api.openSettings()}>
                Open Settings
              </Button>
            }
          >
            Google rejected your OAuth Client ID/Secret, so meetings can't sync right now. Check them
            against the OAuth client in Google Cloud Console and re-enter them in Settings.
          </Callout>
        ) : null}

        {status && status.connected && status.needsReconnect ? (
          <Callout
            color="orange"
            icon={<AlertTriangle />}
            actions={
              <Button variant="transparent" onClick={() => void api.openSettings()}>
                Open Settings
              </Button>
            }
          >
            Your Google sign-in expired, so meetings can't sync right now. Reconnect your account in
            Settings to keep getting alerts.
          </Callout>
        ) : null}

        {status && status.configured && !status.connected ? (
          <EmptyState
            className="mt-10"
            media={<CalendarDays className="size-6 text-tertiary" />}
            title="Connect your calendar"
            description="Sign in with Google to pull in your meetings and get a full-screen heads-up before each one."
            actions={
              <Button
                variant="accent"
                disabled={connectMutation.isPending}
                onClick={() => connectMutation.mutate()}
              >
                {connectMutation.isPending ? "Connecting…" : "Connect Google Calendar"}
              </Button>
            }
          />
        ) : null}

        {status?.connected ? (
          <section className="flex flex-col gap-2">
            <Text variant="strong">Calendar</Text>
            {events.length === 0 ? (
              <EmptyState
                placement="inline"
                className="py-10"
                title="No meetings this week"
                description="Nothing in the last or next 7 days. New events will appear here automatically."
              />
            ) : (
              <List.Root items={events} getItemKey={(e) => `${e.accountEmail ?? ""}:${e.id}`}>
                {daySections.map((section) => {
                  const isToday = section.diff === 0;
                  const isFuture = section.diff > 0;
                  // Today: blue + bold (stands out). Future: black, not bold
                  // (recedes). Past: greyed out.
                  const titleClass = isToday ? "text-accent" : isFuture ? "!font-normal" : undefined;
                  return (
                    <List.Section
                      key={section.dayKey}
                      id={section.dayKey === todayAnchorKey ? "calendar-today-anchor" : undefined}
                      className={cn("scroll-mt-2", section.diff < 0 && "opacity-60")}
                    >
                      <List.SectionTitle className={isToday ? "text-accent" : undefined}>
                        {dayLabel(section.events[0].start)}
                      </List.SectionTitle>
                      {section.events.map((event) => (
                        <List.Item
                          key={`${event.accountEmail ?? ""}:${event.id}`}
                          item={event}
                          onClick={() => openEventMutation.mutate({ id: event.id, start: event.start })}
                          title="Open in Calendar"
                        >
                          <List.ItemIcon>
                            {event.meetingUrl ? <Video /> : <CalendarDays />}
                          </List.ItemIcon>
                          <List.ItemContent>
                            <List.ItemTitle className={titleClass}>{event.title}</List.ItemTitle>
                            <List.ItemDescription>
                              {event.allDay ? "All day" : clock(event.start)}
                              {event.calendarName ? ` · ${event.calendarName}` : ""}
                              {multiAccount && event.accountEmail ? ` · ${event.accountEmail}` : ""}
                            </List.ItemDescription>
                          </List.ItemContent>
                          <List.ItemAccessory>
                            <div className="flex items-center gap-2">
                              {event.meetingUrl ? <Badge color="blue">Video</Badge> : null}
                              {isToday && !event.allDay ? (
                                <Text variant="small" color="secondary" className="tabular-nums">
                                  {relativeTime(new Date(event.start).getTime(), now)}
                                </Text>
                              ) : null}
                            </div>
                          </List.ItemAccessory>
                        </List.Item>
                      ))}
                    </List.Section>
                  );
                })}
              </List.Root>
            )}
          </section>
        ) : null}
      </div>
    </ScrollArea>
  );
}
