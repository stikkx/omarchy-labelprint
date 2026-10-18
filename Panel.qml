import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Label printer bar widget: a single themed dot that says whether the Brother
// PT-P710BT is connected over Bluetooth — green when it is, muted grey when
// not. The check is a plain `bluetoothctl info <mac>` poll; the print backend
// is never spawned for it (see brief). Clicking the widget opens the popup
// (cassette status, label entry, copies, print) which talks to the backend.
// Popup tasks print through that backend and rely on `connected` /
// `cassetteWidth` / `scalarSetting(key)` here.
//
// The popup's "Print API" switch runs `btprintbridge serve` as the transient
// user unit `btprintbridge-api` (systemd-run), so web apps such as
// BinaryStock print through this same backend at http://127.0.0.1:<apiPort>.
// The unit outlives shell reloads; the plugin re-asserts it at load.
Panel {
  id: root
  moduleName: "stikkx.labelprint"

  // IPC target "stikkx.labelprint": open/close/toggle the popup, e.g.
  // `qs ipc -p /usr/share/omarchy/shell call stikkx.labelprint toggle`.
  manageIpc: true
  ipcTarget: "stikkx.labelprint"

  // ---- Settings (shell.json bar entry, pomodoro persist pattern) ----------

  readonly property var _defaults: ({
    mac: "",
    channel: "1",
    backend: "~/.local/bin/btprintbridge",
    copies: 1,
    label: "",
    qrEnabled: false,
    qrValue: "",
    barcodeEnabled: false,
    barcodeValue: "",
    apiEnabled: false,
    apiPort: 8710,
    apiOrigins: "http://localhost:3000"
  })

  function scalarSetting(key) {
    var v = settings ? settings[key] : undefined
    if (v === undefined || v === null) return _defaults[key]
    return v
  }

  function expandPath(p) {
    var s = String(p || "")
    if (s.indexOf("~") === 0) s = Quickshell.env("HOME") + s.substring(1)
    return s
  }

  function persistSettings(extra, silent) {
    var entry = Object.assign({}, root.settings, extra || {})
    root.settings = entry
    if (silent) return
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function clampedCopies(v) {
    var n = Math.round(Number(v))
    if (isNaN(n)) n = 1
    return Math.min(100, Math.max(1, n))
  }

  // ---- Connection state ---------------------------------------------------

  property bool connected: false
  // Print width the paired printer reports, in dots (px of the 62 µm head);
  // 0 = unknown. Popup tasks read it to lay out labels.
  property int cassetteWidth: 0

  // Guard so a poll only lands when the answer actually changed — the dot
  // never paints (or animates) because of a repeated "yes".
  property bool _pollSeen: false

  property string mac: String(scalarSetting("mac") || "")
  readonly property bool macReady: mac.length > 0
  // Backend autodetects the printer when --mac is omitted.
  function macArgs() { return macReady ? ["--mac", mac] : [] }

  onSettingsChanged: {
    var next = String(scalarSetting("mac") || "")
    if (next !== mac) {
      mac = next
      _pollSeen = false
    }
    checkTimer.restart()
    // Deferred: sibling bindings (apiEnabled, apiPort, …) settle first.
    Qt.callLater(root.applyApiIfChanged)
  }

  function applyApiIfChanged() {
    if (apiConfigKey !== _apiAppliedKey) applyApi()
  }

  function applyPoll(stdout) {
    var c = /Connected: yes/.test(String(stdout))
    if (_pollSeen && c === connected) return
    connected = c
    _pollSeen = true
  }

  // Empty MAC: like the backend, use the first paired device named "PT-…".
  function poll() {
    if (pollProc.running) return
    pollProc.command = macReady
      ? ["bluetoothctl", "info", mac]
      : ["sh", "-c", "m=$(bluetoothctl devices Paired | awk '$3 ~ /^PT-/ {print $2; exit}'); [ -n \"$m\" ] && bluetoothctl info \"$m\""]
    pollProc.running = true
    pollKillTimer.restart()
  }

  // A wedged bluetoothctl must not wedge every future poll behind the
  // `running` guard — kill it and let the next tick go through.
  Timer {
    id: pollKillTimer
    interval: 15000
    onTriggered: if (pollProc.running) pollProc.signal(9)
  }

  Process {
    id: pollProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { pollKillTimer.stop(); root.applyPoll(text) } }
  }

  Timer {
    id: checkTimer
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.poll()
      root.pollApi()
    }
  }

  // ---- Print API (btprintbridge serve as a transient user unit) ----------

  readonly property string apiUnit: "btprintbridge-api"
  readonly property bool apiEnabled: !!scalarSetting("apiEnabled")
  readonly property int apiPort: {
    var n = Math.round(Number(scalarSetting("apiPort")))
    return (n >= 1 && n <= 65535) ? n : _defaults.apiPort
  }
  readonly property string apiOrigins: String(scalarSetting("apiOrigins") || "")
  readonly property string apiUrl: "http://127.0.0.1:" + apiPort
  // Everything the running server was started with; a change restarts it.
  // Stored in the unit Description so a reload can tell whether the running
  // unit is current.
  readonly property string apiConfigKey: apiEnabled
    ? ["btprintbridge API", apiPort, apiOrigins, String(scalarSetting("mac") || ""),
       String(scalarSetting("channel")), backendPath].join(" | ")
    : ""

  property bool apiRunning: false
  property bool apiBusy: false
  property string apiError: ""
  property string _apiAppliedKey: "-"

  function pollApi() {
    if (apiPollProc.running) return
    apiPollProc.command = ["systemctl", "--user", "is-active", "--quiet", apiUnit]
    apiPollProc.running = true
  }

  Process {
    id: apiPollProc
    onExited: function(code) { root.apiRunning = code === 0 }
  }

  // Start (or restart when the config changed) / stop the API unit so it
  // matches the `apiEnabled` setting. Idempotent; safe at every load.
  function applyApi() {
    if (apiCtlProc.running) {
      apiReapply = true
      return
    }
    apiReapply = false
    _apiAppliedKey = apiConfigKey
    console.log("stikkx.labelprint: print API " + (apiEnabled ? "ensure " + apiConfigKey : "stop"))
    apiError = ""
    apiBusy = true
    apiStderr = ""
    if (!apiEnabled) {
      apiCtlProc.command = ["/bin/sh", "-c",
        "systemctl --user stop \"$1\" 2>/dev/null; systemctl --user reset-failed \"$1\" 2>/dev/null; exit 0",
        "sh", apiUnit]
    } else {
      // Positional args only — no settings text is ever parsed by the shell.
      apiCtlProc.command = ["/bin/sh", "-c",
        "u=$1; desc=$2; backend=$3; port=$4; origins=$5; mac=$6; ch=$7\n" +
        "test -x \"$backend\" || { echo \"backend not found: $backend\" >&2; exit 3; }\n" +
        "cur=$(systemctl --user show -p Description --value \"$u\" 2>/dev/null)\n" +
        "if systemctl --user is-active --quiet \"$u\" && [ \"$cur\" = \"$desc\" ]; then exit 0; fi\n" +
        "systemctl --user stop \"$u\" 2>/dev/null; systemctl --user reset-failed \"$u\" 2>/dev/null\n" +
        "systemd-run --user --quiet --unit=\"$u\" --collect --description=\"$desc\" " +
        "-p Restart=on-failure -p RestartSec=5 -p StartLimitBurst=3 " +
        "\"$backend\" serve --port \"$port\" --origins \"$origins\" --channel \"$ch\" ${mac:+--mac \"$mac\"} || exit 4\n" +
        // Port conflicts etc. fail within a moment — surface them now.
        "sleep 1.5; systemctl --user is-active --quiet \"$u\" && exit 0\n" +
        "journalctl --user -u \"$u\" -n 3 --no-pager -o cat >&2; exit 5",
        "sh", apiUnit, apiConfigKey, backendPath, String(apiPort), apiOrigins,
        String(scalarSetting("mac") || ""), String(scalarSetting("channel"))]
    }
    apiCtlProc.running = true
  }

  property bool apiReapply: false
  property string apiStderr: ""

  Process {
    id: apiCtlProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apiStderr = text
    }
    onExited: function(code) {
      root.apiBusy = false
      if (code !== 0 && root.apiEnabled) {
        var lines = String(root.apiStderr || "").trim().split("\n")
        var reason = lines.length ? lines[lines.length - 1] : ""
        root.apiError = reason !== "" ? reason.slice(0, 160) : ("failed to start (exit " + code + ")")
        root.notify(true, "Print API: " + root.apiError)
        // Next settings change retries; don't loop on a hard failure.
      }
      root.pollApi()
      if (root.apiReapply) root.applyApi()
    }
  }

  function setApiEnabled(on) {
    persistSettings({ apiEnabled: !!on })
    applyApi()
  }

  // ---- Backend probe ------------------------------------------------------

  readonly property string backendPath: expandPath(scalarSetting("backend"))
  property bool backendFound: false

  function probeBackend() {
    backendProbe.running = false
    backendProbe.command = ["/bin/sh", "-c", "test -x \"$1\"", "sh", root.backendPath]
    backendProbe.running = true
  }

  Process {
    id: backendProbe
    onExited: function(code) {
      root.backendFound = code === 0
      if (root.opened && code === 0) root.refreshStatus()
    }
  }

  // ---- Popup state ----------------------------------------------------------

  // Parsed `status --json` payload: {connected, media_width, media_type,
  // error, ...}. Null until a status run succeeds.
  property var statusResult: null
  property bool statusBusy: false
  property string statusError: ""

  property bool busy: false
  property string labelDraft: ""
  property int copiesDraft: clampedCopies(scalarSetting("copies"))
  property bool qrEnabledDraft: false
  property string qrValueDraft: ""
  property bool barcodeEnabledDraft: false
  property string barcodeValueDraft: ""

  function persistLabel() {
    if (root.labelDraft === String(scalarSetting("label") || "")) return
    persistSettings({ label: root.labelDraft })
  }

  // QR/barcode drafts persist in one merged settings write; only keys that
  // actually drifted from the stored (or default) value go into the entry.
  function persistCodeSettings() {
    var extra = {}
    var pairs = [
      ["qrEnabled", root.qrEnabledDraft],
      ["qrValue", root.qrValueDraft],
      ["barcodeEnabled", root.barcodeEnabledDraft],
      ["barcodeValue", root.barcodeValueDraft]
    ]
    for (var i = 0; i < pairs.length; i++) {
      var key = pairs[i][0], draft = pairs[i][1]
      var stored = root.settings ? root.settings[key] : undefined
      var reference = (stored === undefined || stored === null) ? _defaults[key] : stored
      if (draft !== reference) extra[key] = draft
    }
    if (Object.keys(extra).length > 0) persistSettings(extra)
  }

  function persistCopies() {
    // "Stored" means the key set in shell.json — a draft back at the default
    // still counts as a change when the stored key says otherwise.
    var stored = root.settings ? root.settings.copies : undefined
    if (stored === undefined || stored === null) {
      if (root.copiesDraft === clampedCopies(_defaults.copies)) return
    } else if (Number(stored) === root.copiesDraft) {
      return
    }
    persistSettings({ copies: root.copiesDraft })
  }

  onOpenedChanged: {
    if (opened) {
      labelDraft = String(scalarSetting("label") || "")
      copiesDraft = clampedCopies(scalarSetting("copies"))
      qrEnabledDraft = !!scalarSetting("qrEnabled")
      qrValueDraft = String(scalarSetting("qrValue") || "")
      barcodeEnabledDraft = !!scalarSetting("barcodeEnabled")
      barcodeValueDraft = String(scalarSetting("barcodeValue") || "")
      statusError = ""
      probeBackend()
    } else {
      persistLabel()
      persistCopies()
      persistCodeSettings()
    }
  }

  Component.onCompleted: {
    probeBackend()
    apiSettleTimer.start()
  }

  // The bar hands `settings` over after creation; applying at onCompleted
  // would see the defaults and bounce a running API unit on every reload.
  Timer {
    id: apiSettleTimer
    interval: 1500
    onTriggered: root.applyApiIfChanged()
  }

  // ---- Status on open -------------------------------------------------------

  function lastJsonLine(raw) {
    // Tolerate leading noise: scan from the bottom for a parseable line.
    var lines = String(raw || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var s = lines[i].trim()
      if (s === "") continue
      if (s.charAt(0) !== "{" && s.charAt(0) !== "[") continue
      try { return JSON.parse(s) } catch (e) {}
    }
    return null
  }

  function refreshStatus() {
    if (!backendFound) return
    if (root.busy || statusProc.running) return
    statusBusy = true
    statusError = ""
    statusResult = null
    statusExit = -1
    statusOutput = ""
    statusProc.command = [root.backendPath, "status"].concat(root.macArgs(), ["--channel", String(scalarSetting("channel")), "--json"])
    statusProc.running = false
    statusProc.running = true
    statusKillTimer.restart()
  }

  // Settle pattern: stdout EOF and process exit may race in either order;
  // resolve only once both landed.
  property int statusExit: -1
  property string statusOutput: ""
  property bool statusOutputDone: false

  function settleStatus() {
    if (statusExit < 0 || !statusOutputDone) return
    statusKillTimer.stop()
    statusBusy = false
    var parsed = lastJsonLine(statusOutput)
    if (parsed !== null) {
      statusResult = parsed
      statusError = ""
      return
    }
    statusResult = null
    statusError = "Status failed (exit " + statusExit + ")"
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.statusOutput = text
        root.statusOutputDone = true
        root.settleStatus()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.statusExit = code
      root.settleStatus()
    }
  }

  // A wedged status call must not leave the chip on "Checking cassette…".
  Timer {
    id: statusKillTimer
    interval: 20000
    onTriggered: {
      if (statusProc.running) statusProc.signal(9)
    }
  }

  readonly property string statusChipText: {
    if (!backendFound) return "backend not found – run btprintbridge install.sh"
    if (statusBusy) return "Checking cassette…"
    if (statusError !== "") return statusError
    var r = statusResult
    if (!r) return "No status yet"
    if (!r.connected) return "Printer offline (" + String(r.error || "unknown") + ")"
    var w = Number(r.media_width)
    if (w > 0) return "Cassette: " + w + " mm"
    return "Cassette: " + String(r.media_type || "unknown")
  }

  // ---- Print job -------------------------------------------------------------

  function specForPrint() {
    // Contract: a disabled code is `false`; an enabled one is
    // {"value": <override or null>} — null hands the label text to the
    // backend (it then owns the ASCII check and error reporting). Text stays
    // raw (no trim()) — leading/trailing spaces are label content.
    function codeEntry(enabled, value) {
      if (!enabled) return false
      var v = String(value || "")
      return { value: v === "" ? null : v }
    }
    return {
      text: root.labelDraft,
      qr: codeEntry(root.qrEnabledDraft, root.qrValueDraft),
      barcode: codeEntry(root.barcodeEnabledDraft, root.barcodeValueDraft),
      copies: root.copiesDraft
    }
  }

  // The key goes backend stdout -> wl-copy stdin; it never appears in argv.
  function copyApiKey() {
    if (keyCopyProc.running) return
    keyCopyProc.command = ["/bin/sh", "-c", "k=$(\"$1\" api-key) && printf '%s' \"$k\" | wl-copy", "sh", root.backendPath]
    keyCopyProc.running = true
  }

  Process {
    id: keyCopyProc
    onExited: function(code) {
      root.notify(code !== 0, code === 0
        ? "Print API key copied — paste it into the web app's print dialog"
        : "Could not read the Print API key")
    }
  }

  function notify(critical, msg) {
    var argv = ["notify-send"]
    if (critical) argv.push("-u", "critical")
    argv.push("Label printer", String(msg))
    Quickshell.execDetached(argv)
  }

  function lastBtprintErrLine(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var s = lines[i].trim()
      if (s.indexOf("btprintbridge:") !== -1) return s
    }
    for (i = lines.length - 1; i >= 0; i--) {
      s = lines[i].trim()
      if (s !== "") return s.slice(0, 200)
    }
    return "Print failed (exit " + root.printExit + ")"
  }

  function removeSpec() {
    if (root.specPath === "") return
    var p = root.specPath
    root.specPath = ""
    rmSpecProc.command = ["/bin/sh", "-c", "rm -f \"$1\"", "sh", p]
    rmSpecProc.running = false
    rmSpecProc.running = true
  }

  function printLabel() {
    if (root.busy) return
    if (!backendFound) {
      notify(true, "btprintbridge backend not found – run install.sh")
      return
    }
    var dir = expandPath("~/.cache/stikkx.labelprint")
    root.specPath = dir + "/spec-" + Date.now() + ".json"
    root.busy = true
    printExit = -1
    printStdout = ""
    printStderr = ""
    printStdoutDone = false
    printStderrDone = false
    printTimedOut = false
    // printf '%s' "$2" writes the JSON verbatim — no shell expansion of the
    // label text; the payload reaches the file as one argument.
    mkSpecProc.command = [
      "/bin/sh", "-c", "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"", "sh",
      dir, JSON.stringify(specForPrint()), root.specPath
    ]
    mkSpecProc.running = false
    mkSpecProc.running = true
  }

  property string specPath: ""
  property int printExit: -1
  property string printStdout: ""
  property string printStderr: ""
  property bool printStdoutDone: false
  property bool printStderrDone: false
  property bool printTimedOut: false

  function settlePrint() {
    if (printExit < 0 || !printStdoutDone || !printStderrDone) return
    printKillTimer.stop()
    root.busy = false
    removeSpec()
    if (printTimedOut) {
      notify(true, "Print timed out — printer unresponsive")
      return
    }
    if (printExit === 0) {
      var printed = root.copiesDraft
      var r = lastJsonLine(printStdout)
      if (r && Number(r.printed) > 0) printed = Number(r.printed)
      notify(false, "Printed " + printed + " label(s)")
    } else {
      notify(true, lastBtprintErrLine(printStderr))
    }
  }

  Process {
    id: mkSpecProc
    onExited: function(code) {
      if (code !== 0) {
        root.busy = false
        root.specPath = ""
        root.notify(true, "Could not write print spec")
        return
      }
      printProc.command = [
        root.backendPath, "print", "--spec", root.specPath
      ].concat(root.macArgs(), [
        "--channel", String(scalarSetting("channel")),
        "--copies", String(root.copiesDraft)
      ])
      printProc.running = false
      printProc.running = true
      printKillTimer.restart()
    }
  }

  Process {
    id: printProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.printStdout = text
        root.printStdoutDone = true
        root.settlePrint()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.printStderr = text
        root.printStderrDone = true
        root.settlePrint()
      }
    }
    onExited: function(code) {
      root.printExit = code
      root.settlePrint()
    }
  }

  // Bluetooth printing is slow (pairing + feed + cut per copy); if the job
  // outlives this, un-wedge the busy state and report.
  Timer {
    id: printKillTimer
    interval: 120000
    onTriggered: {
      if (printProc.running) {
        root.printTimedOut = true
        printProc.signal(9)
      }
    }
  }

  Process {
    id: rmSpecProc
    command: []
  }

  // ---- Theme green ---------------------------------------------------------
  // The shell has no success/positive surface token, so the dot pulls the
  // theme's own `green` from colors.toml — the token themes already ship for
  // exactly this "it works" role. Falls to the grey token when off.

  property string _themeGreen: ""
  readonly property color dotOn: _themeGreen.length > 0 ? _themeGreen : "#9ece6a"
  readonly property color dotOff: Color.muted

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root._themeGreen = root.parseGreen(text())
    onFileChanged: reload()
    onLoadFailed: root._themeGreen = ""
  }

  function parseGreen(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*green\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) return m[1]
    }
    return ""
  }

  // ---- Bar visuals ---------------------------------------------------------

  readonly property bool vertical: root.bar ? root.bar.vertical : false
  readonly property int barSize: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  readonly property bool showLabel: !vertical

  implicitWidth: row.implicitWidth
  implicitHeight: barSize

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(6)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(4)
      height: Style.space(4)
      radius: width / 2
      color: root.connected ? root.dotOn : root.dotOff

      Behavior on color { ColorAnimation { duration: 250 } }
    }

    Text {
      visible: root.apiRunning
      textFormat: Text.PlainText
      text: "API"
      color: root.dotOn
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: root.showLabel
      textFormat: Text.PlainText
      text: "PT-P710BT"
      color: root.barForeground
      opacity: 0.85
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggle()
  }

  // ---- Popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: row
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: labelArea
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(popupColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: popupColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Header: title + cassette chip ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(popupTitle.implicitHeight, chipLabel.implicitHeight)

          Text {
            id: popupTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Label printer"
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            textFormat: Text.PlainText
          }

          Text {
            id: chipLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - popupTitle.implicitWidth - Style.space(12))
            text: root.statusChipText
            color: root.barForeground
            opacity: (root.backendFound && !root.statusBusy && root.statusResult && root.statusResult.connected) ? 1 : 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
          }
        }

        // ---------- Print API switch ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            id: apiTitle
            width: Style.space(56)
            anchors.verticalCenter: parent.verticalCenter
            text: "Print API"
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          ToggleSwitch {
            id: apiSwitch
            anchors.verticalCenter: parent.verticalCenter
            checked: root.apiEnabled
            busy: root.apiBusy
            foreground: root.barForeground
            accent: root.barForeground
            onToggled: root.setApiEnabled(!root.apiEnabled)
          }

          Text {
            width: Math.max(0, parent.width - apiTitle.width - apiSwitch.implicitWidth - parent.spacing * 2
                               - (keyBtn.visible ? keyBtn.width + parent.spacing : 0))
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (root.apiBusy) return root.apiEnabled ? "Starting…" : "Stopping…"
              if (root.apiError !== "" && root.apiEnabled) return root.apiError
              if (root.apiRunning) return root.apiUrl
              return root.apiEnabled ? "not running" : "off"
            }
            color: root.barForeground
            opacity: root.apiRunning ? 1 : 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          // Web apps need the API key (Authorization: Bearer …).
          Button {
            id: keyBtn
            visible: root.apiRunning
            anchors.verticalCenter: parent.verticalCenter
            text: "Copy key"
            fontSize: Style.font.caption
            foreground: root.barForeground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.copyApiKey()
          }
        }

        // ---------- Label entry ----------
        Rectangle {
          width: parent.width
          height: Style.space(96)
          radius: Style.cornerRadius
          color: Style.controlFill(labelArea.activeFocus, labelArea.hovered, root.barForeground, root.barForeground)

          QQC.TextArea {
            id: labelArea
            anchors.fill: parent
            anchors.margins: Style.space(8)
            wrapMode: QQC.TextArea.Wrap
            textFormat: Text.PlainText
            placeholderText: "Shelf A-3\nDrawer 2"
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            selectionColor: Style.selectionFillFor(root.barForeground, root.barForeground)
            selectedTextColor: root.barForeground
            placeholderTextColor: Qt.darker(root.barForeground, 1.8)
            background: null
            text: root.labelDraft
            onTextChanged: {
              if (text !== root.labelDraft) root.labelDraft = text
            }
            onEditingFinished: root.persistLabel()
            Keys.onEscapePressed: event.accepted = false
          }
        }

        // ---------- QR / Code128 toggle rows ----------
        // Switch + value override side by side. Fields stay free-form — no
        // validator here; the backend owns the ASCII 32-127 check and surfaces
        // violations through the print-error notification.
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: qrTitle
              width: Style.space(56)
              anchors.verticalCenter: parent.verticalCenter
              text: "QR"
              color: root.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            ToggleSwitch {
              id: qrSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.qrEnabledDraft
              foreground: root.barForeground
              accent: root.barForeground
              onToggled: root.qrEnabledDraft = !root.qrEnabledDraft
            }

            TextField {
              id: qrValueField
              width: Math.max(0, parent.width - qrTitle.width - qrSwitch.implicitWidth - parent.spacing * 2)
              anchors.verticalCenter: parent.verticalCenter
              text: root.qrValueDraft
              placeholderText: "override (empty = label text)"
              color: root.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              onTextChanged: if (text !== root.qrValueDraft) root.qrValueDraft = text
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: barcodeTitle
              width: Style.space(56)
              anchors.verticalCenter: parent.verticalCenter
              text: "Code128"
              color: root.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            ToggleSwitch {
              id: barcodeSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.barcodeEnabledDraft
              foreground: root.barForeground
              accent: root.barForeground
              onToggled: root.barcodeEnabledDraft = !root.barcodeEnabledDraft
            }

            TextField {
              id: barcodeValueField
              width: Math.max(0, parent.width - barcodeTitle.width - barcodeSwitch.implicitWidth - parent.spacing * 2)
              anchors.verticalCenter: parent.verticalCenter
              text: root.barcodeValueDraft
              placeholderText: "override (empty = label text)"
              color: root.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              onTextChanged: if (text !== root.barcodeValueDraft) root.barcodeValueDraft = text
            }
          }
        }

        // ---------- Copies + print ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          NumberField {
            id: copiesField
            label: "Copies"
            from: 1
            to: 100
            value: root.copiesDraft
            foreground: root.barForeground
            accent: root.barForeground
            fontFamily: root.bar.fontFamily
            onModified: function(v) { root.copiesDraft = clampedCopies(v) }
          }

          Item { width: Math.max(0, parent.width - copiesField.width - printBtn.width - parent.spacing * 2); height: 1 }

          Button {
            id: printBtn
            anchors.verticalCenter: parent.verticalCenter
            text: root.busy ? "Printing…" : "Print"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            opacity: root.busy ? 0.5 : 1
            onClicked: root.printLabel()
          }
        }
      }
    }
  }
}
