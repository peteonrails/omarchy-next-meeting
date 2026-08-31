import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "peteonrails.next-meeting"

  property var meeting: null

  // The event after the one being counted down, when the provider supplies it.
  // Only used while the current meeting is running -- that's when "what's next"
  // is the useful half of the label.
  readonly property var following: {
    var n = meeting && meeting.next
    return (n && n.title) ? n : null
  }

  readonly property string label: formatLabel(meeting)

  // Minutes before the following meeting at which it displaces the running one
  // from the label. 0 keeps the running meeting on screen for its whole length.
  readonly property int handoverMinutes: {
    var n = parseInt(setting("handoverMinutes", 10), 10)
    return (isNaN(n) || n < 0) ? 10 : n
  }
  readonly property bool urgent: {
    if (!meeting || meeting.empty) return false
    if (meeting.ongoing) return true
    return meeting.minutes_until !== undefined && meeting.minutes_until <= 5
  }

  function shortTitle(t) {
    var max = parseInt(setting("maxTitleLength", 32), 10) || 32
    var s = String(t || "")
    if (s.length <= max) return s
    return s.substring(0, max - 1) + "…"
  }

  function formatPrefix(d) {
    if (d.ongoing) return "NOW"
    var m = d.minutes_until
    if (m === undefined) return d.start_label || ""
    if (m < 60) return "in " + m + "m"
    if (m < 24 * 60) {
      var h = Math.floor(m / 60)
      var rem = m % 60
      return "in " + h + "h" + (rem ? " " + rem + "m" : "")
    }
    var dt = new Date(d.start_iso)
    if (isNaN(dt.getTime())) return d.start_label || ""
    return Qt.formatDate(dt, "ddd") + " " + (d.start_label || "")
  }

  function formatLabel(d) {
    if (!d) return "Next: loading…"
    if (d.error) return d.exitCode === 127 ? "Next: agenda not found" : "Next: agenda error"
    if (d.empty || !d.title) return "Next: (none)"
    // A running meeting leads with itself: the countdown is spent, so the
    // question the label should answer becomes "what comes after this one".
    // Once that one is close enough to need leaving for, it takes the whole
    // label -- the meeting you're sitting in is the one you already know about.
    if (d.ongoing) {
      var f = root.following
      if (root.handoverMinutes > 0 && f && f.minutes_until !== undefined
          && f.minutes_until <= root.handoverMinutes)
        return "Next: " + formatPrefix(f) + "  ·  " + shortTitle(f.title)
      var now = "NOW: " + shortTitle(d.title)
      if (!f) return now
      // A provider may name the following event without dating it; say what it
      // knows rather than trailing an empty gap.
      var when = formatPrefix(f)
      return now + "  ·  Next: " + shortTitle(f.title) + (when ? " " + when : "")
    }
    return "Next: " + formatPrefix(d) + "  ·  " + shortTitle(d.title)
  }

  // The event a warning is about: whatever is being counted down. While a
  // meeting is running that is the FOLLOWING event, not the one on screen --
  // and a back-to-back day is exactly when the warning matters most, because
  // the meeting you're in runs right up to the start of the one you're late
  // for. Reading warnings off the main slot alone stays silent all day.
  readonly property var upcoming: {
    var d = meeting
    if (!d || d.empty || d.error || !d.title) return null
    return d.ongoing ? following : d
  }

  property bool acknowledged: false
  property string lastUrgentKey: ""

  function urgencyKey(d) {
    if (!d || !d.title) return ""
    return String(d.title) + "@" + String(d.start_iso || "")
  }

  onMeetingChanged: {
    // An empty key means the payload carries no event -- an error blip, or a
    // finished day. Holding the previous key through it keeps a transient
    // provider failure from clearing an acknowledgement or re-arming a warning
    // that already fired for the meeting still on screen.
    var k = urgencyKey(meeting)
    if (k !== "" && k !== lastUrgentKey) {
      lastUrgentKey = k
      acknowledged = false
      pruneAnnounced()
    }
    maybeAnnounce()
  }

  function refresh() {
    if (!proc.running) proc.running = true
  }

  // ~/.local/bin is prepended explicitly in front of every command this widget
  // runs. A desktop session's PATH is NOT the interactive-shell PATH: the
  // compositor spawns the shell with a minimal environment, and `bash -l` only
  // sources the login profile, which on many setups does not add ~/.local/bin
  // (that happens later, in .bashrc). Without this, the conventional home for
  // user scripts -- `agenda`, `say`, a join hook -- is invisible and the
  // default command fails with 127.
  readonly property string pathPrefix: "export PATH=\"$HOME/.local/bin:$HOME/bin:$PATH\"; "

  function runCommand(cmd) {
    if (!cmd || !root.bar) return
    root.bar.run(root.pathPrefix + cmd)
  }

  // Any command printing the documented JSON on stdout works here -- see README.
  readonly property string agendaCommand: String(setting("agendaCommand", "agenda --next-json"))
  readonly property string wrappedCommand: pathPrefix + agendaCommand

  // Tracks whether the most recent run produced usable output, so a missing or
  // broken agenda command surfaces as a visible state instead of leaving the
  // label stuck on "loading…" forever (bash exits 127 for a missing command).
  property bool lastRunProduced: false

  Process {
    id: proc
    command: ["bash", "-lc", root.wrappedCommand]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          root.meeting = JSON.parse(raw)
          root.lastRunProduced = true
        } catch (e) {
          // Keep last-good payload on parse failure.
        }
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.lastRunProduced) {
        root.meeting = { error: true, exitCode: exitCode }
      }
      root.lastRunProduced = false
    }
  }

  Timer {
    id: pollTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: countdownTimer
    interval: 30000
    running: !!root.meeting && !root.meeting.empty
    repeat: true
    onTriggered: {
      if (!root.meeting || root.meeting.empty) return
      var copy = JSON.parse(JSON.stringify(root.meeting))
      if (copy.minutes_until !== undefined) {
        copy.minutes_until = Math.max(0, copy.minutes_until - 0.5)
        copy.minutes_until = Math.round(copy.minutes_until)
      }
      if (copy.next && copy.next.minutes_until !== undefined) {
        copy.next.minutes_until = Math.max(0, Math.round(copy.next.minutes_until - 0.5))
      }
      root.meeting = copy
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool hasConference: !!(root.meeting && root.meeting.is_conference && root.meeting.url)

  // Command templates. {{title}} and {{url}} are substituted with SHELL-QUOTED
  // values. `joinCommand` is used instead of `openCommand` when the event is a
  // video conference and a join command is configured -- that's the hook for
  // starting a transcriber/recorder before the browser opens.
  readonly property string openCommand: String(setting("openCommand", "xdg-open {{url}}"))
  readonly property string joinCommand: String(setting("joinCommand", ""))
  readonly property string agendaViewCommand: String(
    setting("agendaViewCommand", "omarchy-launch-floating-terminal-with-presentation agenda"))

  readonly property bool willJoin: hasConference && joinCommand !== ""

  readonly property string tooltipForLink: {
    if (!root.meeting || !root.meeting.url) return ""
    return willJoin ? "Join meeting" : "Open event"
  }

  // Replacements are supplied as FUNCTIONS on purpose: a plain string
  // replacement would let `$&`/`$1` sequences inside a shell-quoted title or
  // URL be reinterpreted by String.replace and corrupt the command.
  function expandVars(tpl, vars) {
    var out = String(tpl)
    for (var key in vars) {
      var quoted = Util.shellQuote(String(vars[key] === undefined ? "" : vars[key]))
      out = out.replace(new RegExp("\\{\\{" + key + "\\}\\}", "g"),
                        (function (v) { return function () { return v } })(quoted))
    }
    return out
  }

  function expandCommand(tpl, title, url) {
    return expandVars(tpl, { title: title || "", url: url || "" })
  }

  function activateMeeting() {
    if (!root.meeting || !root.meeting.url) return
    var tpl = root.willJoin ? root.joinCommand : root.openCommand
    root.runCommand(expandCommand(tpl, root.meeting.title || "", root.meeting.url))
  }

  // ---------------------------------------------------------------------
  // Warnings
  //
  // A spoken warning is the right channel while you're at the desk and wrong
  // the moment you're already in a call -- the microphone would carry it to
  // everyone else. So the check command decides: exit 0 ("a meeting app is
  // up") routes the warning to a notification instead of the speakers.
  // ---------------------------------------------------------------------
  readonly property string announceCommand: String(setting("announceCommand", "say {{text}}"))
  readonly property string notifyCommand: String(
    setting("notifyCommand", "notify-send -u critical -a 'Next Meeting' {{title}} {{text}}"))
  // Exit 0 == "you are already in a call". Covers both a native Zoom binary
  // and Zoom opened as a browser web app, whose window class carries the
  // host (chrome-app.zoom.us__...). Matched on class, never title, so a
  // terminal that merely mentions zoom does not count as a meeting.
  readonly property string inMeetingCheckCommand: String(setting("inMeetingCheckCommand",
    "pgrep -x zoom >/dev/null 2>&1 || hyprctl clients -j 2>/dev/null | grep -qi '\"class\": *\"[^\"]*zoom'"))

  // Minutes-before-start at which to warn, largest first. Each threshold fires
  // at most once per meeting.
  readonly property var announceMinutes: {
    var out = []
    var parts = String(setting("announceMinutes", "5,1")).split(/[^0-9]+/)
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] === "") continue
      var n = parseInt(parts[i], 10)
      if (!isNaN(n) && n >= 0 && out.indexOf(n) === -1) out.push(n)
    }
    out.sort(function (a, b) { return b - a })
    return out
  }

  // "<event key>@<threshold>" -> true. Keyed by the event WARNED ABOUT, not by
  // whatever occupies the main slot: an event warned about while it sat in
  // `next` is promoted to the main slot when the meeting before it ends, and
  // must not re-arm a threshold it has already crossed. Keying it this way also
  // means the 60s poll landing twice on the same minute cannot double-announce.
  property var announcedThresholds: ({})

  // Only the two live events can still be warned about, so anything else is
  // dead weight; dropping it bounds the map across a long-running shell.
  function pruneAnnounced() {
    var live = [urgencyKey(meeting), urgencyKey(following)]
    var kept = ({})
    for (var mark in announcedThresholds) {
      for (var i = 0; i < live.length; i++) {
        if (live[i] !== "" && mark.indexOf(live[i] + "@") === 0) {
          kept[mark] = true
          break
        }
      }
    }
    announcedThresholds = kept
  }

  // Small numbers as English words. Digits reach a speech engine as characters
  // it has to guess at; words are unambiguous, and "oh" is how a person says a
  // leading zero in a time.
  function numberWord(n) {
    var ones = ["zero", "one", "two", "three", "four", "five", "six", "seven",
                "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    var tens = ["twenty", "thirty", "forty", "fifty"]
    var v = Math.floor(Math.abs(Number(n)))
    if (isNaN(v)) return String(n)
    if (v < 20) return ones[v]
    if (v < 60) {
      var rest = v % 10
      return tens[Math.floor(v / 10) - 2] + (rest ? " " + ones[rest] : "")
    }
    return String(v)
  }

  function minutesPhrase(m, spoken) {
    var n = Math.max(0, Math.round(m))
    if (n <= 0) return "now"
    if (n === 1) return "in 1 minute".replace("1", spoken ? "one" : "1")
    return "in " + (spoken ? numberWord(n) : n) + " minutes"
  }

  // A clock time as a person reads it aloud: "nine oh five am", "eleven thirty".
  // Handing a speech engine the digits invites it to perform the punctuation --
  // a colon becomes a long pause, and a leading zero is read as "zero" rather
  // than "oh". On the hour the minutes go entirely; nobody says "twelve zero
  // zero pm". Anything that isn't a clock time falls back to splitting the
  // colon, which is still better than leaving it in.
  function spokenTime(label) {
    var s = String(label || "").trim()
    var parts = s.match(/^(\d{1,2}):(\d{2})\s*(?:([ap])\.?\s*m\.?)?$/i)
    if (!parts) {
      return s.replace(/\s*([ap])\.?\s*m\.?$/i, " $1m").replace(/(\d):(\d)/g, "$1 $2")
    }
    var minute = parseInt(parts[2], 10)
    var out = numberWord(parseInt(parts[1], 10))
    if (minute > 0) out += (minute < 10 ? " oh " : " ") + numberWord(minute)
    if (parts[3]) out += " " + parts[3].toLowerCase() + "m"
    return out
  }

  // The same sentence, tuned for its channel: spoken for the speakers, written
  // as the calendar shows it for a notification nobody has to listen to.
  function announcementText(d, minutes, spoken) {
    var when = spoken ? spokenTime(d.start_label) : String(d.start_label || "")
    return "Your meeting, " + String(d.title || "")
         + (when ? " at " + when : "")
         + ", starts " + minutesPhrase(minutes, spoken) + "."
  }

  function warningVars(d, minutes, spoken) {
    return {
      text: announcementText(d, minutes, spoken),
      title: String(d.title || ""),
      start: spoken ? spokenTime(d.start_label) : String(d.start_label || ""),
      minutes: String(Math.max(0, Math.round(minutes)))
    }
  }

  function maybeAnnounce() {
    var d = root.upcoming
    if (!d || !d.title) return
    var m = d.minutes_until
    if (m === undefined || m === null || m < 0) return

    var key = urgencyKey(d)
    if (key === "") return

    var thresholds = root.announceMinutes
    for (var i = 0; i < thresholds.length; i++) {
      if (m > thresholds[i]) continue
      var mark = key + "@" + thresholds[i]
      if (root.announcedThresholds[mark]) continue
      root.announcedThresholds[mark] = true
      root.fireWarning(d, m, thresholds[i])
      // Only the largest unfired threshold speaks. A shell that starts up two
      // minutes before a meeting warns once, not once per threshold it has
      // already slept through.
      return
    }
  }

  // One bar is instantiated per monitor, each with its own timers and its own
  // fired-threshold map, so a two-screen desk speaks every warning twice. In-QML
  // state cannot fix that -- the instances share nothing. The claim is therefore
  // made where the side effect happens: `mkdir` either creates the marker or
  // fails, atomically, so exactly one instance proceeds and the rest exit
  // quietly. Markers live in the session runtime dir and so are discarded at
  // logout; stale ones are swept after four hours to bound the directory.
  function singleFireGuard(eventKey, threshold) {
    var marker = String(threshold + "-" + eventKey)
      .replace(/[^A-Za-z0-9]+/g, "_").substring(0, 120)
    var dir = "\"${XDG_RUNTIME_DIR:-/tmp}/omarchy-next-meeting\""
    return "d=" + dir + "; mkdir -p \"$d\" 2>/dev/null; "
         + "find \"$d\" -mindepth 1 -maxdepth 1 -type d -mmin +240 -exec rmdir {} + 2>/dev/null; "
         + "mkdir \"$d\"/" + Util.shellQuote(marker) + " 2>/dev/null || exit 0; "
  }

  // `threshold` is the configured step this warning belongs to, and is what the
  // marker is keyed on. `minutes` is what this instance happened to observe --
  // two bars polling on offset timers can see 5 and 4 for the same crossing, so
  // keying the marker on it would let both through.
  function fireWarning(d, minutes, threshold) {
    var speak = root.announceCommand
      ? expandVars(root.announceCommand, warningVars(d, minutes, true)) : ""
    var notify = root.notifyCommand
      ? expandVars(root.notifyCommand, warningVars(d, minutes, false)) : ""
    var check = root.inMeetingCheckCommand

    var cmd = ""
    if (speak && notify && check) cmd = "if " + check + "; then " + notify + "; else " + speak + "; fi"
    else if (speak && check && !notify) cmd = "if " + check + "; then :; else " + speak + "; fi"
    else cmd = speak || notify
    if (!cmd) return

    root.runCommand(singleFireGuard(urgencyKey(d), threshold) + cmd)
  }

  // Polled only while a meeting is imminent or running -- there is no reason to
  // scan the process table the rest of the day.
  property bool meetingAppRunning: false

  Process {
    id: presenceProc
    command: ["bash", "-lc", root.pathPrefix + root.inMeetingCheckCommand]
    onExited: function (exitCode) {
      root.meetingAppRunning = (exitCode === 0)
    }
  }

  Timer {
    id: presenceTimer
    interval: 20000
    running: root.inMeetingCheckCommand !== "" && !!root.meeting && !root.meeting.empty
             && (root.urgent || !!root.meeting.ongoing)
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!presenceProc.running) presenceProc.running = true
    onRunningChanged: if (!running) root.meetingAppRunning = false
  }

  // Green means "you're in it". Clicking the widget says so explicitly; so does
  // joining by any other route, which the presence check notices within 20s.
  readonly property bool joined: acknowledged || meetingAppRunning
  readonly property bool inProgress: !!(meeting && meeting.ongoing && joined)
  readonly property string inProgressColor: "#7eb56c"

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    active: root.urgent
    activeColor: root.inProgress ? root.inProgressColor : (root.bar ? root.bar.urgent : "#a55555")
    foreground:  root.inProgress ? root.inProgressColor : (root.bar ? root.bar.barForeground : "#cacccc")
    tooltipText: root.tooltipForLink

    onPressed: function(b) {
      root.acknowledged = true
      if (b === Qt.RightButton) {
        root.runCommand(root.agendaViewCommand)
      } else {
        root.activateMeeting()
      }
    }
  }

  SequentialAnimation {
    id: blinkAnim
    loops: Animation.Infinite
    running: root.urgent && !root.joined
    alwaysRunToEnd: true
    NumberAnimation { target: button; property: "opacity"; to: 0.25; duration: 450; easing.type: Easing.InOutQuad }
    NumberAnimation { target: button; property: "opacity"; to: 1.0;  duration: 450; easing.type: Easing.InOutQuad }
    onRunningChanged: if (!running) button.opacity = 1.0
  }
}
