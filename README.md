# Next Meeting — an Omarchy bar widget

An always-visible bar label showing what's next on your calendar:

```
Next: in 12m  ·  Standup
NOW: Design review  ·  Next: Retro in 48m
Next: in 7m  ·  Retro
Next: (none)
```

A meeting in progress leads with itself and names what follows — until that one
is within `handoverMinutes` (10 by default), at which point it takes the whole
label. The meeting you're sitting in is the one you already know about; the one
you have to leave for is not. Where meetings overlap and both have started, the
later one takes the label outright.

It pulses red when a meeting is within 5 minutes or already running, and turns
green once you're in the meeting — either because you clicked the widget, or
because it noticed a call app running. Clicking opens the event, or runs a
custom join command for video conferences.

Five minutes and one minute out, it **says the meeting out loud**. If you're
already on a call it sends a critical notification instead, so the warning
doesn't go down your microphone to everyone else.

**This widget has no calendar integration of its own.** It runs a command you
choose and reads JSON from its stdout. That means it works with Google
Calendar, CalDAV, Outlook, a local `.ics` file, or anything else you can
persuade to emit a handful of fields — see [the contract](#the-json-contract).

## Install

```bash
omarchy plugin add https://github.com/peteonrails/omarchy-next-meeting.git
omarchy plugin enable peteonrails.next-meeting center
```

Then point `agendaCommand` at your provider. Until you do, the label reads
`Next: agenda not found`.

## The JSON contract

`agendaCommand` must print a single JSON object on stdout. Every field is
optional except the ones noted.

| Field | Type | Meaning |
|---|---|---|
| `title` | string | Event title. **Required** unless `empty` is true |
| `start_iso` | string | ISO 8601 start, e.g. `2026-08-07T12:00`. Used for day-of-week when the event is >24h out |
| `start_label` | string | Human start time, e.g. `12:00pm`. Fallback display |
| `minutes_until` | number | Minutes until start. Drives `in 12m` / `in 2h 5m` and the urgent pulse |
| `ongoing` | boolean | Meeting is running now — renders `NOW` and pulses. Optional: a `minutes_until` at or below zero is treated as running regardless, so a provider that cannot see end times still renders correctly |
| `url` | string | Opened on click |
| `is_conference` | boolean | Event is a video call — selects `joinCommand` over `openCommand` |
| `empty` | boolean | Nothing upcoming — renders `Next: (none)` |
| `error` | boolean | Provider failed — renders `Next: agenda error` |
| `next` | object | The event *after* this one. Shown while `ongoing` is true, and displaces it entirely inside `handoverMinutes`. Takes `title`, `start_iso`, `start_label` and `minutes_until` — same meanings as above |

A minimal working example:

```json
{"title":"Standup","start_iso":"2026-08-07T12:00","start_label":"12:00pm","minutes_until":12,"ongoing":false,"url":"https://meet.example.com/abc","is_conference":true}
```

A meeting in progress, with the one after it:

```json
{"title":"Design review","start_label":"12:00pm","ongoing":true,"minutes_until":0,
 "next":{"title":"Retro","start_iso":"2026-08-07T13:00","start_label":"1:00pm","minutes_until":48}}
```

Nothing upcoming:

```json
{"empty":true}
```

The widget re-runs the command every 60 seconds and counts `minutes_until` down
locally between polls, so a slow provider still gives a smooth countdown. The
last good payload is kept if a later run fails or emits malformed JSON.

If the command exits non-zero without producing output, the label shows
`Next: agenda not found` for exit 127, `Next: agenda error` otherwise.

### The bundled provider

The plugin ships one, in `bin/agenda` — a [gcalcli](https://github.com/insanum/gcalcli)
wrapper that emits the contract above. It needs `gcalcli` (authenticated) and
Python 3; it has no other dependencies.

You do not have to configure anything to use it. The plugin's own `bin/` is
**appended** to `PATH`, so `agenda --next-json` finds the bundled copy on a
fresh install, while an `agenda` already on your `PATH` continues to win. That
ordering is deliberate: bundling is there to make the plugin work out of the
box, not to override a provider you maintain yourself.

To use something else entirely, point `agendaCommand` at it — see
[the contract](#the-json-contract).

### Rolling your own

Any script works — here's the shape of a trivial one:

```bash
#!/bin/bash
# agenda --next-json
gcalcli --nocolor agenda --nostarted --details=all --tsv "$(date +%Y-%m-%dT%H:%M)" "$(date -d '+7 days' +%Y-%m-%d)" \
  | head -2 \
  | your-tsv-to-json-filter   # first row is the event, second becomes "next"
```

## Settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `agendaCommand` | string | `agenda --next-json` | Command printing the JSON above |
| `openCommand` | string | `xdg-open {{url}}` | Opens an event |
| `joinCommand` | string | `""` | Used instead of `openCommand` when `is_conference` is true. Blank falls back to `openCommand` |
| `agendaViewCommand` | string | `omarchy-launch-floating-terminal-with-presentation agenda` | Right-click — show the full agenda |
| `announceMinutes` | string | `5,1` | Minutes before the start at which to warn. Blank disables warnings |
| `announceCommand` | string | `say {{text}}` | Speaks the warning |
| `notifyCommand` | string | `notify-send -u critical -a 'Next Meeting' {{title}} {{text}}` | Used instead of `announceCommand` when `inMeetingCheckCommand` succeeds |
| `inMeetingCheckCommand` | string | a Zoom check — see below | Exit 0 means "a call is already running" |
| `handoverMinutes` | integer | `10` | While a meeting is running, the following one takes the whole label this many minutes before it starts. `0` keeps the running meeting on screen for its full length |
| `maxTitleLength` | integer | `32` | Titles longer than this are ellipsised |

### Command templates

`openCommand` and `joinCommand` accept `{{url}}` and `{{title}}`, which are
substituted with **shell-quoted** values — a meeting titled `Bob's "1:1"; rm -rf ~`
cannot break out into your shell.

Chain commands to do something before the browser opens. The author starts a
transcriber:

```json
{ "joinCommand": "voxtype meeting start --title {{title}} && xdg-open {{url}}" }
```

## Warnings

Each threshold in `announceMinutes` fires once per meeting. `5,1` gives you the
five-minute heads-up and the one-minute "go now":

> Your meeting, Weekly Leadership Team Meeting at 11:00 am, starts in 5 minutes.

Both `announceCommand` and `notifyCommand` take four substitutions, all
shell-quoted: `{{text}}` (the whole sentence), `{{title}}`, `{{start}}` and
`{{minutes}}`.

`{{text}}` and `{{start}}` render differently per channel: spoken for
`announceCommand`, written as the calendar shows it for `notifyCommand`.

The spoken form rewrites the start time as a person would read it aloud,
because punctuation a reader skims is punctuation a speech engine performs. A
colon becomes a long pause, a leading zero is read as "zero" rather than "oh",
and on the hour nobody says "twelve zero zero pm".

| `start_label` | spoken as |
|---|---|
| `9:05am` | `nine oh five am` |
| `11:30am` | `eleven thirty am` |
| `1:15pm` | `one fifteen pm` |
| `12:00pm` | `twelve pm` |

A label that isn't a clock time is left alone apart from splitting the colon.
The minute count is spelled out the same way, pluralised, and zero becomes
"now" rather than "in 0 minutes".

The default `announceCommand` is [`say`](https://ss64.com/mac/say.html)'s Linux
habit: any command that speaks its argument works — `spd-say`, `espeak-ng`, a
Piper or Kokoro wrapper. Set it blank to warn only by notification.

### One warning, however many bars

Omarchy instantiates a bar per monitor, so a two-screen desk runs two copies of
this widget — each with its own timers, each reaching the five-minute mark on
its own. They share no state, so nothing in the widget can stop them both
warning you.

The claim is made at the side effect instead. Before speaking, the command
`mkdir`s a marker named for the event and the threshold; `mkdir` either creates
the directory or fails, atomically, so exactly one instance proceeds and the
rest exit quietly. Markers live under `$XDG_RUNTIME_DIR` and are discarded at
logout, with stale ones swept after four hours.

### Not speaking over a call

Speech is the wrong channel once you're already in a meeting; your microphone
would carry it to everyone else. `inMeetingCheckCommand` decides. It runs just
before the warning, and **exit 0 routes the warning to `notifyCommand` instead
of the speakers**.

The default covers Zoom two ways — a native `zoom` binary, and Zoom opened as a
browser web app, whose window class carries the host:

```bash
pgrep -x zoom >/dev/null 2>&1 || hyprctl clients -j 2>/dev/null | grep -qi '"class": *"[^"]*zoom'
```

It matches on window *class*, never title, so a terminal that happens to mention
zoom is not mistaken for a call. Widen it for whatever else you use:

```json
{ "inMeetingCheckCommand": "pgrep -x 'zoom|Slack|teams' >/dev/null 2>&1" }
```

Set it blank to always speak.

## Colours

| State | Look |
|---|---|
| More than 5 minutes out | Normal bar foreground |
| Within 5 minutes, or running | Red, pulsing |
| Running, and you're in it | Green, steady |

"You're in it" means either you clicked the widget, or `inMeetingCheckCommand`
succeeded — so joining from the Zoom app, a calendar reminder, or a link
someone pasted in Slack settles the widget just as clicking it does. That check
polls every 20 seconds, and only while a meeting is imminent or running.

### A note on PATH

Commands run through `bash -lc`, with `$HOME/.local/bin` and `$HOME/bin`
prepended to `PATH` first.

That prepend matters more than it looks. A compositor spawns the shell with a
minimal environment, and `bash -l` sources only your *login* profile — on many
setups `~/.local/bin` is added by `.bashrc` instead, which a login shell never
reads. So the conventional home for user scripts is invisible to the widget
unless it is added back explicitly, and a default of `agenda --next-json` fails
with exit 127 despite `agenda` working perfectly in your terminal.

If your provider lives somewhere else entirely, give `agendaCommand` an absolute
path — `$HOME` expands normally:

```json
{ "agendaCommand": "$HOME/src/scripts/my-agenda --json" }
```

## Mouse

| Action | Result |
|---|---|
| Left click | Opens/joins the meeting, and stops the pulse |
| (no click) | The pulse stops on its own once `inMeetingCheckCommand` sees a call |
| Right click | Runs `agendaViewCommand` |

## Requirements

- Omarchy 4 (Quattro) or newer
- A command satisfying the JSON contract — or nothing, to use the bundled
  provider, which needs Python 3 and an authenticated `gcalcli`
- `xdg-open` for the default open behaviour
- Something that speaks — `say`, `spd-say`, `espeak-ng` — for spoken warnings
- `notify-send` and `hyprctl` for the notification fallback and its Zoom check

## License

MIT — see [LICENSE](LICENSE).
