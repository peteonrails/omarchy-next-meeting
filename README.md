# Next Meeting — an Omarchy bar widget

An always-visible bar label showing what's next on your calendar:

```
Next: in 12m  ·  Standup
Next: NOW  ·  Design review
Next: (none)
```

It pulses when a meeting is within 5 minutes or already running, and stops the
moment you click it. Clicking opens the event — or runs a custom join command
for video conferences.

**This widget has no calendar integration of its own.** It runs a command you
choose and reads JSON from its stdout. That means it works with Google
Calendar, CalDAV, Outlook, a local `.ics` file, or anything else you can
persuade to emit six fields — see [the contract](#the-json-contract).

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
| `ongoing` | boolean | Meeting is running now — renders `NOW` and pulses |
| `url` | string | Opened on click |
| `is_conference` | boolean | Event is a video call — selects `joinCommand` over `openCommand` |
| `empty` | boolean | Nothing upcoming — renders `Next: (none)` |
| `error` | boolean | Provider failed — renders `Next: agenda error` |

A minimal working example:

```json
{"title":"Standup","start_iso":"2026-08-07T12:00","start_label":"12:00pm","minutes_until":12,"ongoing":false,"url":"https://meet.example.com/abc","is_conference":true}
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

### Reference provider

The author's provider is a [gcalcli](https://github.com/insanum/gcalcli)
wrapper. Any script works — here's the shape of a trivial one:

```bash
#!/bin/bash
# agenda --next-json
gcalcli --nocolor agenda --nostarted --details=all --tsv "$(date +%Y-%m-%dT%H:%M)" "$(date -d '+7 days' +%Y-%m-%d)" \
  | head -1 \
  | your-tsv-to-json-filter
```

## Settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `agendaCommand` | string | `agenda --next-json` | Command printing the JSON above |
| `openCommand` | string | `xdg-open {{url}}` | Opens an event |
| `joinCommand` | string | `""` | Used instead of `openCommand` when `is_conference` is true. Blank falls back to `openCommand` |
| `agendaViewCommand` | string | `omarchy-launch-floating-terminal-with-presentation agenda` | Right-click — show the full agenda |
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
| Right click | Runs `agendaViewCommand` |

## Requirements

- Omarchy 4 (Quattro) or newer
- A command satisfying the JSON contract
- `xdg-open` for the default open behaviour

## License

MIT — see [LICENSE](LICENSE).
