import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "peteonrails.next-meeting"

  property var meeting: null

  readonly property string label: formatLabel(meeting)
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
    return "Next: " + formatPrefix(d) + "  ·  " + shortTitle(d.title)
  }

  property bool acknowledged: false
  property string lastUrgentKey: ""

  function urgencyKey(d) {
    if (!d || !d.title) return ""
    return String(d.title) + "@" + String(d.start_iso || "")
  }

  onMeetingChanged: {
    var k = urgencyKey(meeting)
    if (k !== lastUrgentKey) {
      lastUrgentKey = k
      acknowledged = false
    }
  }

  function refresh() {
    if (!proc.running) proc.running = true
  }

  // Any command printing the documented JSON on stdout works here -- see
  // README. Run through `bash -lc` so a login PATH applies and a plain
  // `agenda` resolves from ~/.local/bin without the path being baked in.
  readonly property string agendaCommand: String(setting("agendaCommand", "agenda --next-json"))

  // Tracks whether the most recent run produced usable output, so a missing or
  // broken agenda command surfaces as a visible state instead of leaving the
  // label stuck on "loading…" forever (bash exits 127 for a missing command).
  property bool lastRunProduced: false

  Process {
    id: proc
    command: ["bash", "-lc", root.agendaCommand]
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
  function expandCommand(tpl, title, url) {
    return String(tpl)
      .replace(/\{\{title\}\}/g, function () { return Util.shellQuote(String(title || "")) })
      .replace(/\{\{url\}\}/g,   function () { return Util.shellQuote(String(url || "")) })
  }

  function activateMeeting() {
    if (!root.meeting || !root.meeting.url || !root.bar) return
    var tpl = root.willJoin ? root.joinCommand : root.openCommand
    root.bar.run(expandCommand(tpl, root.meeting.title || "", root.meeting.url))
  }

  readonly property bool inProgressClicked: !!(meeting && meeting.ongoing && acknowledged)
  readonly property string inProgressColor: "#7eb56c"

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    active: root.urgent
    activeColor: root.inProgressClicked ? root.inProgressColor : (root.bar ? root.bar.urgent : "#a55555")
    foreground:  root.inProgressClicked ? root.inProgressColor : (root.bar ? root.bar.barForeground : "#cacccc")
    tooltipText: root.tooltipForLink

    onPressed: function(b) {
      root.acknowledged = true
      if (b === Qt.RightButton) {
        if (root.bar && root.agendaViewCommand) root.bar.run(root.agendaViewCommand)
      } else {
        root.activateMeeting()
      }
    }
  }

  SequentialAnimation {
    id: blinkAnim
    loops: Animation.Infinite
    running: root.urgent && !root.acknowledged
    alwaysRunToEnd: true
    NumberAnimation { target: button; property: "opacity"; to: 0.25; duration: 450; easing.type: Easing.InOutQuad }
    NumberAnimation { target: button; property: "opacity"; to: 1.0;  duration: 450; easing.type: Easing.InOutQuad }
    onRunningChanged: if (!running) button.opacity = 1.0
  }
}
