import { useEffect, useState } from "react";
import {
  Button,
  Text,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@glaze/core/components";
import { Video, CalendarDays, MoreHorizontal } from "lucide-react";

import { api, onBroadcast, type AppSettings, type CalendarEvent } from "../shared/api";

function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

function formatClock(iso: string): string {
  return new Date(iso).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function humanizeDuration(totalMinutes: number): string {
  if (totalMinutes < 60) {
    return `${totalMinutes} minute${totalMinutes === 1 ? "" : "s"}`;
  }
  const hours = Math.floor(totalMinutes / 60);
  const mins = totalMinutes % 60;
  const hourPart = `${hours} hour${hours === 1 ? "" : "s"}`;
  return mins ? `${hourPart} ${mins} minute${mins === 1 ? "" : "s"}` : hourPart;
}

function startsInLabel(startMs: number, now: number): string {
  const diffMin = Math.round((startMs - now) / 60000);
  if (diffMin <= 0) return "The event is starting now";
  return `The event will start in ${humanizeDuration(diffMin)}`;
}

const EXTRA_SNOOZE = [10, 15, 30, 60];

export function AlertView() {
  const [event, setEvent] = useState<CalendarEvent | null>(null);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const now = useNow();

  useEffect(() => {
    void api.getCurrentAlert().then(setEvent);
    const off = onBroadcast("alert:update", (payload) => setEvent(payload as CalendarEvent));
    return off;
  }, []);

  useEffect(() => {
    void api.getSettings().then(setSettings);
    const off = onBroadcast("settings:changed", (payload) => setSettings((payload as { value: AppSettings }).value));
    return off;
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") void api.dismissAlert();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!event) {
    return <div className="h-full w-full" />;
  }

  const startMs = new Date(event.start).getTime();
  const minutesUntilStart = Math.min(120, Math.max(1, Math.ceil((startMs - now) / 60000)));
  const canSnoozeUntilEvent = startMs - now > 90_000; // >1.5 min away
  const [firstSnooze, secondSnooze] = settings?.snoozeDurations ?? [1, 5];

  return (
    <div className="h-full w-full flex flex-col items-center justify-between py-[6vh] px-10 text-center select-none">
      {/* Spacer to visually center the hero block */}
      <div />

      <div className="flex flex-col items-center gap-6">
        <div className="flex items-stretch gap-4 max-w-[85vw]">
          <div
            className="w-1.5 rounded-full shrink-0"
            style={{ backgroundColor: "#34C759" }}
            aria-hidden
          />
          <Text
            variant="heading1"
            className="!text-[clamp(2.5rem,6vw,4.5rem)] !leading-[1.05] font-bold text-left"
          >
            {event.title}
          </Text>
        </div>

        <div className="flex flex-col items-center gap-1.5">
          <Text variant="extra-large" className="tabular-nums">
            {formatClock(event.start)} – {formatClock(event.end)}
          </Text>
          <Text variant="large" color="secondary" className="tabular-nums">
            {event.isTest ? "This is a preview alert" : startsInLabel(startMs, now)}
          </Text>
          {event.location ? (
            <Text variant="regular" color="tertiary" truncate className="max-w-[40ch]">
              {event.location}
            </Text>
          ) : null}
        </div>

        <div className="flex size-14 items-center justify-center rounded-card border border-field bg-well">
          {event.meetingUrl ? (
            <Video className="size-6 text-secondary" />
          ) : (
            <CalendarDays className="size-6 text-secondary" />
          )}
        </div>

        <div className="flex flex-col items-center gap-3 mt-2">
          {event.meetingUrl ? (
            <Button variant="accent" size="large" onClick={() => void api.joinMeeting()}>
              <Video />
              Join meeting
            </Button>
          ) : null}
          <Button
            variant={event.meetingUrl ? "filled" : "accent"}
            size="large"
            className="min-w-52"
            onClick={() => void api.dismissAlert()}
          >
            Dismiss
          </Button>
        </div>
      </div>

      <div className="flex flex-col items-center gap-2">
        <Text variant="small" color="secondary">
          Snooze
        </Text>
        <div className="flex items-center gap-2">
          <Button variant="filled" size="large" onClick={() => void api.snoozeAlert(firstSnooze)}>
            {humanizeDuration(firstSnooze)}
          </Button>
          <Button variant="filled" size="large" onClick={() => void api.snoozeAlert(secondSnooze)}>
            {humanizeDuration(secondSnooze)}
          </Button>
          <Button
            variant="filled"
            size="large"
            disabled={!canSnoozeUntilEvent}
            onClick={() => void api.snoozeAlert(minutesUntilStart)}
          >
            Until event
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="filled" size="large" iconOnly aria-label="More snooze options">
                <MoreHorizontal />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent side="top" align="end">
              {EXTRA_SNOOZE.filter((m) => m !== firstSnooze && m !== secondSnooze).map((m) => (
                <DropdownMenuItem key={m} onSelect={() => void api.snoozeAlert(m)}>
                  {humanizeDuration(m)}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
    </div>
  );
}
