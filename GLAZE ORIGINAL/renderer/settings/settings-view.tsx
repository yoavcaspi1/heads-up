import { useState, useEffect } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Label,
  RadioGroup,
  RadioGroupItem,
  ScrollArea,
  Toolbar,
  ToolbarContent,
  ToolbarTitle,
  Field,
  FieldContent,
  FieldGroup,
  FieldLabel,
  FieldDescription,
  FieldSet,
  Button,
  Input,
  Switch,
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectItem,
  Slider,
  Callout,
  Text,
  toast,
} from "@glaze/core/components";
import type { NativeThemeInfo } from "@glaze/core/ipc";
import { CalendarDays, UserPlus, Mail, AlertTriangle } from "lucide-react";

import {
  api,
  onBroadcast,
  type AppSettings,
  type AuthStatus,
  type CalendarInfo,
  type GoogleAccount,
} from "../shared/api";

const LEAD_TIME_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "0", label: "At start time" },
  { value: "1", label: "1 minute before" },
  { value: "2", label: "2 minutes before" },
  { value: "5", label: "5 minutes before" },
  { value: "10", label: "10 minutes before" },
  { value: "15", label: "15 minutes before" },
  { value: "30", label: "30 minutes before" },
  { value: "60", label: "60 minutes before" },
];

const SNOOZE_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "1", label: "1 minute" },
  { value: "2", label: "2 minutes" },
  { value: "5", label: "5 minutes" },
  { value: "10", label: "10 minutes" },
  { value: "15", label: "15 minutes" },
  { value: "30", label: "30 minutes" },
  { value: "60", label: "60 minutes" },
];

export function SettingsView() {
  const qc = useQueryClient();
  const [themeInfo, setThemeInfo] = useState<NativeThemeInfo | null>(null);
  const [clientIdInput, setClientIdInput] = useState("");
  const [clientSecretInput, setClientSecretInput] = useState("");

  // Close on Escape (unless an interactive element/popover is focused).
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      const el = document.activeElement;
      if (
        el instanceof HTMLInputElement ||
        el instanceof HTMLTextAreaElement ||
        el instanceof HTMLSelectElement ||
        (el instanceof HTMLElement && el.isContentEditable)
      ) {
        return;
      }
      if (document.querySelector("[data-radix-popper-content-wrapper]")) return;
      event.preventDefault();
      window.glazeAPI.glaze.ipc.invoke("window:closeSettings");
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  useEffect(() => {
    void window.glazeAPI.nativeTheme.getInfo().then(setThemeInfo);
  }, []);

  useEffect(() => {
    const off = onBroadcast("accounts:changed", () => {
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["auth"] });
      void qc.invalidateQueries({ queryKey: ["calendars"] });
    });
    return off;
  }, [qc]);

  const authQuery = useQuery<AuthStatus>({ queryKey: ["auth"], queryFn: api.getAuthStatus });
  const accountsQuery = useQuery<GoogleAccount[]>({ queryKey: ["accounts"], queryFn: api.getAccounts });
  const settingsQuery = useQuery<AppSettings>({ queryKey: ["settings"], queryFn: api.getSettings });
  const calendarsQuery = useQuery<CalendarInfo[]>({
    queryKey: ["calendars"],
    queryFn: api.listCalendars,
    enabled: (accountsQuery.data?.length ?? 0) > 0,
  });

  const addMutation = useMutation({
    mutationFn: api.addAccount,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["auth"] });
    },
    onError: (e) => toast.error(`Couldn't add account: ${String(e)}`),
  });

  const removeMutation = useMutation({
    mutationFn: api.removeAccount,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["auth"] });
    },
    onError: (e) => toast.error(`Couldn't remove account: ${String(e)}`),
  });

  const reconnectMutation = useMutation({
    mutationFn: (id: string) => api.reconnectAccount(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["auth"] });
      void qc.invalidateQueries({ queryKey: ["calendars"] });
      toast.success("Account reconnected.");
    },
    onError: (e) => toast.error(`Couldn't reconnect: ${String(e)}`),
  });

  const setCredentialsMutation = useMutation({
    mutationFn: () => api.setCredentials(clientIdInput, clientSecretInput),
    onSuccess: () => {
      setClientIdInput("");
      setClientSecretInput("");
      void qc.invalidateQueries({ queryKey: ["auth"] });
      toast.success("Google credentials saved.");
    },
    onError: (e) => toast.error(`Couldn't save credentials: ${String(e)}`),
  });

  const clearCredentialsMutation = useMutation({
    mutationFn: api.clearCredentials,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["auth"] });
      void qc.invalidateQueries({ queryKey: ["accounts"] });
      void qc.invalidateQueries({ queryKey: ["calendars"] });
    },
    onError: (e) => toast.error(`Couldn't remove credentials: ${String(e)}`),
  });

  const setSettingsMutation = useMutation({
    mutationFn: api.setSettings,
    onSuccess: (next) => qc.setQueryData(["settings"], next),
  });

  const [blurIntensityDraft, setBlurIntensityDraft] = useState<number | null>(null);

  const setLeadTime = (index: 0 | 1, minutes: number) => {
    const next: [number, number] = settings ? [...settings.alertLeadTimes] : [30, 5];
    next[index] = minutes;
    setSettingsMutation.mutate({ alertLeadTimes: next });
  };

  const setSnoozeDuration = (index: 0 | 1, minutes: number) => {
    const next: [number, number] = settings ? [...settings.snoozeDurations] : [1, 5];
    next[index] = minutes;
    setSettingsMutation.mutate({ snoozeDurations: next });
  };

  const toggleCalendarMutation = useMutation({
    mutationFn: ({ key, enabled }: { key: string; enabled: boolean }) => api.setCalendarEnabled(key, enabled),
    onMutate: async ({ key, enabled }) => {
      await qc.cancelQueries({ queryKey: ["calendars"] });
      const previous = qc.getQueryData<CalendarInfo[]>(["calendars"]);
      qc.setQueryData<CalendarInfo[]>(["calendars"], (prev) =>
        prev?.map((c) => (c.key === key ? { ...c, enabled } : c)),
      );
      return { previous };
    },
    onError: (e, _vars, context) => {
      if (context?.previous) qc.setQueryData(["calendars"], context.previous);
      toast.error(`Couldn't update calendar: ${String(e)}`);
    },
    onSuccess: (next) => qc.setQueryData(["settings"], next),
  });

  const handleThemeChange = async (value: string) => {
    try {
      await window.glazeAPI.nativeTheme.setThemeSource(value as "system" | "light" | "dark");
      setThemeInfo(await window.glazeAPI.nativeTheme.getInfo());
    } catch (error) {
      toast.error(`Failed to set theme: ${error}`);
    }
  };

  const configured = authQuery.data?.configured ?? true;
  const clientId = authQuery.data?.clientId ?? null;
  const canSaveCredentials = clientIdInput.trim().length > 0 && clientSecretInput.trim().length > 0;
  const accounts = accountsQuery.data ?? [];
  const settings = settingsQuery.data;
  const blurIntensity = blurIntensityDraft ?? settings?.alertBlurIntensity ?? 30;
  const calendars = calendarsQuery.data ?? [];
  const multiAccount = accounts.length > 1;

  return (
    <ScrollArea
      toolbar={
        <Toolbar>
          <ToolbarContent>
            <ToolbarTitle>Settings</ToolbarTitle>
          </ToolbarContent>
        </Toolbar>
      }
    >
      <div className="px-4 flex flex-col gap-8 mb-8">
        <FieldSet title="Notifications">
          <FieldGroup>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>Notifications</FieldLabel>
                <FieldDescription>Show full-screen alerts before your meetings.</FieldDescription>
              </FieldContent>
              <Switch
                checked={settings?.alertsEnabled ?? true}
                disabled={!settings}
                onCheckedChange={(checked) => setSettingsMutation.mutate({ alertsEnabled: checked })}
              />
            </Field>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>Menu bar calendar</FieldLabel>
                <FieldDescription>
                  Show the next meeting in the menu bar. Click it to open the calendar, right-click for Settings.
                </FieldDescription>
              </FieldContent>
              <Switch
                checked={settings?.menuBarCalendarEnabled ?? true}
                disabled={!settings}
                onCheckedChange={(checked) => setSettingsMutation.mutate({ menuBarCalendarEnabled: checked })}
              />
            </Field>
          </FieldGroup>
        </FieldSet>

        {authQuery.data ? (
          <FieldSet
            title="Google connection"
            description="Heads Up connects to Google Calendar using your own OAuth client — no shared credentials are bundled with the app."
          >
            <FieldGroup>
              {configured && authQuery.data?.credentialsInvalid ? (
                <Callout color="red" icon={<AlertTriangle />}>
                  Google rejected this Client ID/Secret — it doesn't match a real OAuth client
                  (deleted, regenerated, or mistyped). Reconnecting accounts won't fix this; remove
                  these credentials and paste the correct ones from Google Cloud Console.
                </Callout>
              ) : null}
              {!configured ? (
                <>
                  <Callout color="orange" icon={<CalendarDays />}>
                    In the Google Cloud console, enable the Google Calendar API and create an OAuth client
                    (Application type: Web application) with{" "}
                    <Text variant="mono" color="primary">
                      https://www.glaze.app/api/oauth/callback
                    </Text>{" "}
                    as an authorized redirect URI. Then paste its client ID and secret below.
                  </Callout>
                  <Field>
                    <FieldContent>
                      <FieldLabel htmlFor="google-client-id">Client ID</FieldLabel>
                    </FieldContent>
                    <Input
                      id="google-client-id"
                      value={clientIdInput}
                      placeholder="1234567890-abc.apps.googleusercontent.com"
                      autoComplete="off"
                      spellCheck={false}
                      onChange={(e) => setClientIdInput(e.target.value)}
                    />
                  </Field>
                  <Field>
                    <FieldContent>
                      <FieldLabel htmlFor="google-client-secret">Client secret</FieldLabel>
                    </FieldContent>
                    <Input
                      id="google-client-secret"
                      type="password"
                      value={clientSecretInput}
                      placeholder="GOCSPX-…"
                      autoComplete="off"
                      spellCheck={false}
                      onChange={(e) => setClientSecretInput(e.target.value)}
                    />
                  </Field>
                  <Field>
                    <Button
                      variant="accent"
                      disabled={!canSaveCredentials || setCredentialsMutation.isPending}
                      onClick={() => setCredentialsMutation.mutate()}
                    >
                      {setCredentialsMutation.isPending ? "Saving…" : "Save credentials"}
                    </Button>
                  </Field>
                </>
              ) : (
                <Field orientation="horizontal">
                  <FieldContent>
                    <FieldLabel>OAuth client connected</FieldLabel>
                    <FieldDescription className="truncate">{clientId}</FieldDescription>
                  </FieldContent>
                  <Button
                    variant="transparent"
                    disabled={clearCredentialsMutation.isPending}
                    onClick={() => clearCredentialsMutation.mutate()}
                  >
                    {clearCredentialsMutation.isPending ? "Removing…" : "Remove"}
                  </Button>
                </Field>
              )}
            </FieldGroup>
          </FieldSet>
        ) : null}

        <FieldSet title="Accounts" description="Google accounts synced for meeting alerts.">
          <FieldGroup>
            {accounts.length === 0 ? (
              <Field>
                <FieldContent>
                  <FieldLabel>No accounts connected</FieldLabel>
                  <FieldDescription>Add a Google account to start syncing your calendars.</FieldDescription>
                </FieldContent>
              </Field>
            ) : (
              accounts.map((account) => (
                <Field key={account.id} orientation="horizontal">
                  <FieldContent>
                    <FieldLabel>
                      <span className="inline-flex items-center gap-2">
                        <Mail className="size-4 text-tertiary shrink-0" />
                        {account.email}
                      </span>
                    </FieldLabel>
                    {account.needsReconnect ? (
                      <FieldDescription className="inline-flex items-center gap-1.5 text-support-red">
                        <AlertTriangle className="size-3.5 shrink-0" />
                        Sign-in expired — reconnect to keep syncing.
                      </FieldDescription>
                    ) : account.name ? (
                      <FieldDescription>{account.name}</FieldDescription>
                    ) : null}
                  </FieldContent>
                  <div className="flex items-center gap-2">
                    {account.needsReconnect ? (
                      <Button
                        variant="accent"
                        disabled={reconnectMutation.isPending}
                        onClick={() => reconnectMutation.mutate(account.id)}
                      >
                        {reconnectMutation.isPending ? "Reconnecting…" : "Reconnect"}
                      </Button>
                    ) : null}
                    <Button
                      variant="transparent"
                      disabled={removeMutation.isPending}
                      onClick={() => removeMutation.mutate(account.id)}
                    >
                      Remove
                    </Button>
                  </div>
                </Field>
              ))
            )}
            <Field>
              <Button
                variant="accent"
                disabled={!configured || addMutation.isPending}
                onClick={() => addMutation.mutate()}
              >
                <UserPlus />
                {addMutation.isPending ? "Connecting…" : "Add account"}
              </Button>
            </Field>
          </FieldGroup>
        </FieldSet>

        {accounts.length > 0 ? (
          <FieldSet title="Calendars" description="Choose which calendars can show events and trigger alerts.">
            <FieldGroup>
              {calendars.length === 0 ? (
                <Field>
                  <FieldContent>
                    <FieldLabel>No calendars found</FieldLabel>
                    <FieldDescription>Calendars will appear here once your accounts finish syncing.</FieldDescription>
                  </FieldContent>
                </Field>
              ) : (
                calendars.map((cal) => (
                  <Field key={cal.key} orientation="horizontal">
                    <FieldContent>
                      <FieldLabel>{cal.calendarName}</FieldLabel>
                      {multiAccount ? <FieldDescription>{cal.accountEmail}</FieldDescription> : null}
                    </FieldContent>
                    <Switch
                      checked={cal.enabled}
                      disabled={toggleCalendarMutation.isPending}
                      onCheckedChange={(checked) => toggleCalendarMutation.mutate({ key: cal.key, enabled: checked })}
                    />
                  </Field>
                ))
              )}
            </FieldGroup>
          </FieldSet>
        ) : null}

        <FieldSet title="Alerts">
          <FieldGroup>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>First alert</FieldLabel>
                <FieldDescription>How early the first full-screen alert appears.</FieldDescription>
              </FieldContent>
              <Select
                value={String(settings?.alertLeadTimes[0] ?? 30)}
                onValueChange={(v) => setLeadTime(0, Number(v))}
              >
                <SelectTrigger size="medium" className="w-48">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {LEAD_TIME_OPTIONS.map((o) => (
                    <SelectItem key={o.value} value={o.value}>
                      {o.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>Second alert</FieldLabel>
                <FieldDescription>How early the second full-screen alert appears.</FieldDescription>
              </FieldContent>
              <Select
                value={String(settings?.alertLeadTimes[1] ?? 5)}
                onValueChange={(v) => setLeadTime(1, Number(v))}
              >
                <SelectTrigger size="medium" className="w-48">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {LEAD_TIME_OPTIONS.map((o) => (
                    <SelectItem key={o.value} value={o.value}>
                      {o.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>Alert background</FieldLabel>
                <FieldDescription>
                  Solid uses a plain light/dark surface; Blurred shows a native blur of whatever is on screen behind
                  it, with no color.
                </FieldDescription>
              </FieldContent>
              <RadioGroup
                value={settings?.alertBackground ?? "solid"}
                onValueChange={(v) => setSettingsMutation.mutate({ alertBackground: v as "solid" | "blur" })}
                orientation="horizontal"
              >
                <Label>
                  <RadioGroupItem value="solid" />
                  Solid
                </Label>
                <Label>
                  <RadioGroupItem value="blur" />
                  Blurred
                </Label>
              </RadioGroup>
            </Field>
            {settings?.alertBackground === "blur" ? (
              <Field orientation="horizontal">
                <FieldContent>
                  <FieldLabel>Blur strength</FieldLabel>
                  <FieldDescription>How heavily the alert tints the native blur behind it.</FieldDescription>
                </FieldContent>
                <Slider
                  variant="filled"
                  size="medium"
                  className="w-48"
                  min={0}
                  max={100}
                  step={5}
                  value={[blurIntensity]}
                  onValueChange={([v]) => setBlurIntensityDraft(v)}
                  onValueCommit={([v]) => {
                    setBlurIntensityDraft(null);
                    setSettingsMutation.mutate({ alertBlurIntensity: v });
                  }}
                  endContent={(v) => `${v}%`}
                />
              </Field>
            ) : null}
          </FieldGroup>
        </FieldSet>

        <FieldSet title="Snooze" description="Quick-snooze durations shown as buttons on the alert.">
          <FieldGroup>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>First snooze button</FieldLabel>
              </FieldContent>
              <Select
                value={String(settings?.snoozeDurations[0] ?? 1)}
                onValueChange={(v) => setSnoozeDuration(0, Number(v))}
              >
                <SelectTrigger size="medium" className="w-48">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SNOOZE_OPTIONS.map((o) => (
                    <SelectItem key={o.value} value={o.value}>
                      {o.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel>Second snooze button</FieldLabel>
              </FieldContent>
              <Select
                value={String(settings?.snoozeDurations[1] ?? 5)}
                onValueChange={(v) => setSnoozeDuration(1, Number(v))}
              >
                <SelectTrigger size="medium" className="w-48">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SNOOZE_OPTIONS.map((o) => (
                    <SelectItem key={o.value} value={o.value}>
                      {o.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          </FieldGroup>
        </FieldSet>

        <FieldSet title="Appearance">
          <FieldGroup>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel htmlFor="theme">Theme</FieldLabel>
              </FieldContent>
              <RadioGroup
                value={themeInfo?.themeSource ?? "system"}
                onValueChange={handleThemeChange}
                orientation="horizontal"
              >
                <Label>
                  <RadioGroupItem value="system" />
                  Auto
                </Label>
                <Label>
                  <RadioGroupItem value="light" />
                  Light
                </Label>
                <Label>
                  <RadioGroupItem value="dark" />
                  Dark
                </Label>
              </RadioGroup>
            </Field>
          </FieldGroup>
        </FieldSet>
      </div>
    </ScrollArea>
  );
}
