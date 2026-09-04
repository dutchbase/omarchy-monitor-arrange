pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

Item {
  id: root

  // --- State ---
  property bool opened: false
  property var monitors: []
  property var rawSnapshot: []
  property string selectedMonitor: ""
  property string draggingMonitor: ""
  property string operationState: "idle" // idle | applying | awaitingConfirmation | reverting | persisting
  property int revertSecondsLeft: 0
  property string applyError: ""
  property bool fetchInFlight: false

  // --- Canvas geometry (declared on root so every child can reach root.canvasScale) ---
  // Live monitor coordinates are never shifted (Task 2's note on why there's
  // no re-zeroing step) and Hyprland genuinely supports negative positions,
  // so the visible bounding box can have a negative min edge -- e.g. an
  // external monitor dragged to the left of/above the fixed internal panel.
  // minX/minY are a RENDERING-ONLY offset (subtracted per-delegate at draw
  // time in Task 3/4); they are never written back into root.monitors.
  readonly property real canvasPadding: 40
  readonly property real canvasMaxWidth: 640
  readonly property real canvasMaxHeight: 360
  function visibleMonitors() { return root.monitors.filter(function(m) { return !m.disabled }) }
  readonly property real minX: {
    var v = root.visibleMonitors()
    return v.length === 0 ? 0 : Math.min.apply(null, v.map(function(m) { return m.x }))
  }
  readonly property real minY: {
    var v = root.visibleMonitors()
    return v.length === 0 ? 0 : Math.min.apply(null, v.map(function(m) { return m.y }))
  }
  readonly property real boundsWidth: {
    var v = root.visibleMonitors()
    if (v.length === 0) return 1
    return Math.max.apply(null, v.map(function(m) { return m.x + Model.logicalSize(m).width })) - root.minX
  }
  readonly property real boundsHeight: {
    var v = root.visibleMonitors()
    if (v.length === 0) return 1
    return Math.max.apply(null, v.map(function(m) { return m.y + Model.logicalSize(m).height })) - root.minY
  }
  readonly property real canvasScale: Math.min(
    (canvasMaxWidth - canvasPadding * 2) / boundsWidth,
    (canvasMaxHeight - canvasPadding * 2) / boundsHeight
  )

  readonly property var selected: root.monitors.find(function(m) { return m.name === root.selectedMonitor }) || null
  readonly property bool selectedIsMirroring: root.selected ? root.selected.mirroringOf !== "" : false
  readonly property var resGroups: selected ? Model.groupModesByResolution(selected.availableModes) : []
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  // Filtered once, reused for both the ComboBox's model and its currentIndex --
  // computing currentIndex against the unfiltered scalePresets instead (an
  // earlier draft did this) indexes the wrong list whenever presets collapse
  // to fewer distinct effective scales than there are presets.
  readonly property var availableScalesForSelected: root.selected ? Model.availableScales(root.scalePresets, root.selected.width, root.selected.height) : []

  function open() { root.opened = true; root.fetchLive() }
  function close() {
    if (root.operationState === "awaitingConfirmation") {
      root.revertToSnapshot() // fire-and-forget: the Process runs independent of window visibility
      root.opened = false     // close immediately -- don't wait on operationState, which revertToSnapshot() just changed
      return
    }
    if (root.operationState === "idle") root.opened = false
    // while applying/reverting/persisting, ignore close -- let it finish first
  }

  function stopMirroring() {
    if (root.operationState !== "idle" || root.fetchInFlight || stopMirrorProc.running) return
    root.applyError = ""
    stopMirrorProc.running = true
  }

  function fetchLive() {
    if (root.operationState !== "idle" || root.fetchInFlight || stopMirrorProc.running) return // never fetch mid-transaction, while one is already running, or mid stop-mirroring
    root.fetchInFlight = true
    fetchProc.fetchExitKnown = false
    fetchProc.fetchStreamKnown = false
    fetchProc.running = true
  }

  function finalizeFetch() {
    if (!fetchProc.fetchExitKnown || !fetchProc.fetchStreamKnown) return
    var exitCode = fetchProc.lastExitCode
    var stdoutText = fetchProc.lastStdoutText
    var stderrText = fetchProc.lastStderrText
    fetchProc.fetchExitKnown = false
    fetchProc.fetchStreamKnown = false
    root.fetchInFlight = false
    if (root.operationState !== "idle") return // a transaction started while this fetch was in flight
    if (exitCode !== 0) {
      root.applyError = "Could not read monitor state: " + (stderrText || ("hyprctl exited " + exitCode))
      return
    }
    var parsed
    try { parsed = Model.parseMonitors(JSON.parse(stdoutText || "[]")) }
    catch (e) { root.applyError = "Could not read monitor state: " + String(e); return }
    root.rawSnapshot = JSON.parse(JSON.stringify(parsed))
    root.monitors = JSON.parse(JSON.stringify(parsed))
    root.selectedMonitor = ""
  }

  function updateMonitorPosition(name, x, y) {
    root.monitors = root.monitors.map(function(m) {
      return m.name === name ? Object.assign({}, m, { x: x, y: y }) : m
    })
  }

  // No client-side "last enabled external" guard here. apply.sh's live-query
  // check (checked against monitors NOT in the payload, e.g. the internal
  // panel) is the sole authority on whether disabling this monitor is safe --
  // a pre-emptive UI block here would have to duplicate that same live check
  // or, worse, contradict it (an earlier draft always blocked the last
  // external regardless of whether the internal panel was on, which is wrong).
  // A rejected Apply surfaces root.applyError instead.
  function updateMonitorField(name, field, value) {
    var target = root.monitors.find(function(m) { return m.name === name })
    if (!target || target.isInternal) return
    root.monitors = root.monitors.map(function(m) {
      if (m.name !== name) return m
      var updated = Object.assign({}, m)
      updated[field] = value
      return updated
    })
  }

  function updateMonitorMode(name, width, height, refreshRate, modeString) {
    var target = root.monitors.find(function(m) { return m.name === name })
    if (!target || target.isInternal) return
    root.monitors = root.monitors.map(function(m) {
      return m.name === name ? Object.assign({}, m, { width: width, height: height, refreshRate: refreshRate, modeString: modeString }) : m
    })
  }

  function applyLayout() {
    root.applyError = ""
    var payload = root.externalPayload(root.monitors)
    // JSON.stringify([]) is exactly "[]" — nothing this plugin manages is left
    // to apply, so don't start a run that would fail and then fail again on the
    // automatic revert.
    if (payload === "[]") {
      root.applyError = "Nothing to apply — every external monitor is mirrored or managed by Omarchy."
      return
    }
    root.operationState = "applying"
    applyProc.applyExitKnown = false
    applyProc.applyStderrKnown = false
    applyProc.payload = payload
    applyProc.running = true
  }

  function finalizeApply() {
    if (!applyProc.applyExitKnown || !applyProc.applyStderrKnown) return
    var exitCode = applyProc.lastExitCode
    var errText = applyProc.lastStderrText
    applyProc.applyExitKnown = false
    applyProc.applyStderrKnown = false
    if (exitCode === 0) {
      root.operationState = "awaitingConfirmation"
      root.startRevertCountdown()
    } else {
      root.applyError = errText || "Apply failed"
      root.revertToSnapshot() // auto-heal: apply.sh may have partially mutated live state before failing
    }
  }

  function externalPayload(monitors) {
    return JSON.stringify(monitors.filter(function(m) { return !m.isInternal && !m.mirroringOf }).map(function(m) {
      return { name: m.name, mode: m.modeString, x: m.x, y: m.y, scale: m.scale, transform: m.transform, disabled: m.disabled }
    }))
  }

  function startRevertCountdown() {
    if (root.operationState !== "awaitingConfirmation") return
    root.revertSecondsLeft = 15
    revertTimer.running = true
  }

  function revertToSnapshot() {
    if (root.operationState !== "awaitingConfirmation" && root.operationState !== "applying") return
    revertTimer.running = false
    root.operationState = "reverting"
    revertProc.revertExitKnown = false
    revertProc.revertStderrKnown = false
    revertProc.payload = root.externalPayload(root.rawSnapshot)
    revertProc.running = true
  }

  function finalizeRevert() {
    if (!revertProc.revertExitKnown || !revertProc.revertStderrKnown) return
    var exitCode = revertProc.lastExitCode
    var errText = revertProc.lastStderrText
    revertProc.revertExitKnown = false
    revertProc.revertStderrKnown = false
    root.operationState = "idle"
    if (exitCode !== 0) root.applyError = "Revert failed: " + errText
    root.fetchLive() // re-sync with whatever the live state now actually is
  }

  function confirmAndPersist() {
    if (root.operationState !== "awaitingConfirmation") return
    revertTimer.running = false // must stop before persisting, or a timeout mid-persist launches a concurrent revert
    root.operationState = "persisting"
    persistProc.persistExitKnown = false
    persistProc.persistStderrKnown = false
    persistProc.payload = root.externalPayload(root.monitors)
    persistProc.running = true
  }

  function finalizePersist() {
    if (!persistProc.persistExitKnown || !persistProc.persistStderrKnown) return
    var exitCode = persistProc.lastExitCode
    var errText = persistProc.lastStderrText
    persistProc.persistExitKnown = false
    persistProc.persistStderrKnown = false
    root.operationState = "idle"
    if (exitCode !== 0) root.applyError = "Save failed: " + errText
    root.fetchLive()
  }

  // Commands run via bash so a missing script is a normal nonzero exit; Process has no start-failure signal in this Quickshell.
  Process {
    id: fetchProc
    property bool fetchExitKnown: false
    property bool fetchStreamKnown: false
    property int lastExitCode: -1
    property string lastStdoutText: ""
    property string lastStderrText: ""
    command: ["bash", "-c", "exec hyprctl monitors all -j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { fetchProc.lastStdoutText = text || ""; fetchProc.fetchStreamKnown = true; root.finalizeFetch() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { fetchProc.lastStderrText = String(text || "").trim() }
    }
    onExited: function(exitCode) { fetchProc.lastExitCode = exitCode; fetchProc.fetchExitKnown = true; root.finalizeFetch() }
  }

  Process {
    id: applyProc
    property string payload: ""
    property bool applyExitKnown: false
    property bool applyStderrKnown: false
    property int lastExitCode: -1
    property string lastStderrText: ""
    command: ["bash", Quickshell.env("HOME") + "/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/apply.sh"]
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        applyProc.lastStderrText = String(text || "").trim()
        applyProc.applyStderrKnown = true
        root.finalizeApply()
      }
    }
    onStarted: {
      write(applyProc.payload)
      applyProc.payload = ""
      stdinEnabled = false // closes the write channel, delivering EOF to `cat`
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      applyProc.lastExitCode = exitCode
      applyProc.applyExitKnown = true
      root.finalizeApply()
    }
  }

  Timer {
    id: revertTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.revertSecondsLeft -= 1
      if (root.revertSecondsLeft <= 0) { running = false; root.revertToSnapshot() }
    }
  }

  Process {
    id: revertProc
    property string payload: ""
    property bool revertExitKnown: false
    property bool revertStderrKnown: false
    property int lastExitCode: -1
    property string lastStderrText: ""
    command: ["bash", Quickshell.env("HOME") + "/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/apply.sh"]
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { revertProc.lastStderrText = String(text || "").trim(); revertProc.revertStderrKnown = true; root.finalizeRevert() }
    }
    onStarted: { write(revertProc.payload); revertProc.payload = ""; stdinEnabled = false }
    onExited: function(exitCode) { stdinEnabled = true; revertProc.lastExitCode = exitCode; revertProc.revertExitKnown = true; root.finalizeRevert() }
  }

  Process {
    id: persistProc
    property string payload: ""
    property bool persistExitKnown: false
    property bool persistStderrKnown: false
    property int lastExitCode: -1
    property string lastStderrText: ""
    command: ["bash", Quickshell.env("HOME") + "/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/persist.sh"]
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { persistProc.lastStderrText = String(text || "").trim(); persistProc.persistStderrKnown = true; root.finalizePersist() }
    }
    onStarted: { write(persistProc.payload); persistProc.payload = ""; stdinEnabled = false }
    onExited: function(exitCode) { stdinEnabled = true; persistProc.lastExitCode = exitCode; persistProc.persistExitKnown = true; root.finalizePersist() }
  }

  // `omarchy-hyprland-monitor-internal-mirror off` deletes the toggle file but
  // does not reload Hyprland (its on() does, its off() doesn't), so reload here.
  Process {
    id: stopMirrorProc
    command: ["bash", "-c", "omarchy-hyprland-monitor-internal-mirror off && hyprctl reload"]
    onExited: function(exitCode) {
      if (exitCode !== 0) root.applyError = "Could not stop mirroring (exit " + exitCode + ")"
      // Deferred: `running` may not have settled false yet, and fetchLive() refuses while it is true.
      Qt.callLater(root.fetchLive)
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-monitor-arrange"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; visible: root.opened; color: "#88000000" }
    MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.close() }

    Item {
      id: card
      visible: root.opened
      width: Math.min(parent.width - 80, 960)
      height: Math.min(parent.height - 80, 560)
      anchors.centerIn: parent

      MouseArea { anchors.fill: parent; onClicked: {} } // swallow clicks so the scrim doesn't close on inner click

      Item {
        id: canvasArea
        width: root.canvasMaxWidth; height: root.canvasMaxHeight
        anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 16

        Repeater {
          model: root.monitors.filter(function(m) { return !m.disabled })
          delegate: Item {
            id: delegateRoot
            required property var modelData
            x: root.canvasPadding + (delegateRoot.modelData.x - root.minX) * root.canvasScale
            y: root.canvasPadding + (delegateRoot.modelData.y - root.minY) * root.canvasScale
            width: Model.logicalSize(delegateRoot.modelData).width * root.canvasScale
            height: Model.logicalSize(delegateRoot.modelData).height * root.canvasScale

            property real frozenCanvasScale: root.canvasScale
            property real frozenMinX: root.minX
            property real frozenMinY: root.minY

            Rectangle {
              anchors.fill: parent
              color: delegateRoot.modelData.isInternal ? "#333" : (delegateRoot.modelData.focused ? "#3a6ea5" : "#444")
              border.color: delegateRoot.modelData.isInternal ? "#777" : "white"
              border.width: (!delegateRoot.modelData.isInternal && root.selectedMonitor === delegateRoot.modelData.name) ? 2 : 1
              opacity: delegateRoot.modelData.isInternal ? 0.6 : (root.draggingMonitor === delegateRoot.modelData.name ? 0.4 : 1)
              radius: 4

              Text {
                anchors.centerIn: parent
                text: delegateRoot.modelData.description
                    + (delegateRoot.modelData.isInternal ? " (fixed)" : "")
                    + (delegateRoot.modelData.mirroringOf ? " (mirroring " + delegateRoot.modelData.mirroringOf + ")" : "")
                color: "white"
                wrapMode: Text.WordWrap
                width: parent.width - 8
                horizontalAlignment: Text.AlignHCenter
              }
            }

            // Preview follows the pointer without touching root.monitors until release.
            Rectangle {
              id: preview
              visible: root.draggingMonitor === delegateRoot.modelData.name
              width: delegateRoot.width; height: delegateRoot.height
              color: "transparent"
              border.color: "#3a6ea5"; border.width: 2
              x: 0; y: 0
            }

            TapHandler {
              enabled: !delegateRoot.modelData.isInternal
              onTapped: root.selectedMonitor = delegateRoot.modelData.name
            }

            DragHandler {
              id: dragHandler
              target: null
              property bool wasCanceled: false
              enabled: !delegateRoot.modelData.isInternal && !delegateRoot.modelData.mirroringOf && (root.draggingMonitor === "" || root.draggingMonitor === delegateRoot.modelData.name) && root.operationState === "idle" && !root.fetchInFlight && !stopMirrorProc.running
              onActiveChanged: {
                if (active) {
                  root.draggingMonitor = delegateRoot.modelData.name
                  root.selectedMonitor = delegateRoot.modelData.name
                  delegateRoot.frozenCanvasScale = root.canvasScale
                  delegateRoot.frozenMinX = root.minX
                  delegateRoot.frozenMinY = root.minY
                  dragHandler.wasCanceled = false
                  preview.x = 0; preview.y = 0
                  return
                }
                if (root.draggingMonitor !== delegateRoot.modelData.name) return
                // Defer the actual commit decision: Qt's DragHandler sets `active`
                // false BEFORE emitting `canceled` (verified against Qt's own
                // pointer-handler source), so `onCanceled` has not necessarily run
                // yet at this point. Qt.callLater always runs after the current
                // batch of synchronous signal handling finishes, so by the time this
                // runs, onCanceled (if it fires at all for this gesture) is
                // guaranteed to already have set wasCanceled -- regardless of which
                // handler Qt happened to call first.
                var capturedX = delegateRoot.x + preview.x
                var capturedY = delegateRoot.y + preview.y
                var frozenScale = delegateRoot.frozenCanvasScale
                var frozenMinX = delegateRoot.frozenMinX
                var frozenMinY = delegateRoot.frozenMinY
                Qt.callLater(function() {
                  root.draggingMonitor = ""
                  if (dragHandler.wasCanceled) return
                  var others = root.monitors.filter(function(m) { return !m.disabled && m.name !== delegateRoot.modelData.name })
                    .map(function(m) {
                      var size = Model.logicalSize(m)
                      return { x: root.canvasPadding + (m.x - frozenMinX) * frozenScale, y: root.canvasPadding + (m.y - frozenMinY) * frozenScale,
                               width: size.width * frozenScale, height: size.height * frozenScale }
                    })
                  var draggedCanvasRect = { x: capturedX, y: capturedY, width: delegateRoot.width, height: delegateRoot.height }
                  var snapped = Model.snapPositionCanvas(draggedCanvasRect, others, 10)
                  var logicalX = Math.round((snapped.x - root.canvasPadding) / frozenScale + frozenMinX)
                  var logicalY = Math.round((snapped.y - root.canvasPadding) / frozenScale + frozenMinY)
                  root.updateMonitorPosition(delegateRoot.modelData.name, logicalX, logicalY)
                })
              }
              onCanceled: {
                dragHandler.wasCanceled = true
                preview.x = 0; preview.y = 0
              }
              onActiveTranslationChanged: {
                if (!active) return
                preview.x = activeTranslation.x
                preview.y = activeTranslation.y
              }
            }
          }
        }
      }

      Column {
        id: sidePanel
        visible: root.selected !== null
        enabled: root.operationState === "idle" && !root.fetchInFlight && !stopMirrorProc.running
        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 16
        width: 260
        spacing: 8

        Text { text: root.selected ? root.selected.description : ""; color: "white" }

        Column {
          visible: root.selectedIsMirroring
          width: parent.width
          spacing: 6
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: "#ffcc66"
            text: "Mirroring " + (root.selected ? root.selected.mirroringOf : "")
                + " — Omarchy's mirror toggle loads after this plugin's config, so mode, scale and position can't be set here."
          }
          Button { text: "Stop mirroring"; onClicked: root.stopMirroring() }
        }

        Column {
          enabled: !root.selectedIsMirroring
          width: parent.width
          spacing: 8

          ComboBox {
            id: resCombo
            width: parent.width
            model: root.resGroups.map(function(g) { return g.resolution })
            currentIndex: root.resGroups.findIndex(function(g) {
              return root.selected && g.resolution === (root.selected.width + "x" + root.selected.height)
            })
            onActivated: {
              var group = root.resGroups[currentIndex]
              var firstMode = group.modes[0]
              var res = group.resolution.split("x")
              root.updateMonitorMode(root.selected.name, parseInt(res[0]), parseInt(res[1]), firstMode.refreshRate, firstMode.label)
            }
          }

          ComboBox {
            id: rateCombo
            width: parent.width
            model: {
              var g = root.resGroups.find(function(g) { return g.resolution === resCombo.currentText })
              return g ? g.modes.map(function(m) { return m.refreshRate + " Hz" }) : []
            }
            currentIndex: {
              var g = root.resGroups.find(function(g) { return g.resolution === resCombo.currentText })
              if (!g || !root.selected) return -1
              return g.modes.findIndex(function(m) { return m.refreshRate === root.selected.refreshRate })
            }
            onActivated: {
              var g = root.resGroups.find(function(g) { return g.resolution === resCombo.currentText })
              if (!g) return
              var m = g.modes[currentIndex]
              var res = g.resolution.split("x")
              root.updateMonitorMode(root.selected.name, parseInt(res[0]), parseInt(res[1]), m.refreshRate, m.label)
            }
          }

          ComboBox {
            id: scaleCombo
            width: parent.width
            model: root.availableScalesForSelected
            currentIndex: root.selected ? Model.matchingScaleIndex(root.availableScalesForSelected, root.selected.scale, root.selected.width, root.selected.height) : -1
            onActivated: root.updateMonitorField(root.selected.name, "scale",
              parseFloat(Model.cleanScale(currentText, root.selected.width, root.selected.height)))
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: "#aaaaaa"
            text: {
              if (!root.selected) return ""
              var s = Model.logicalSize(root.selected)
              return root.selected.width + "×" + root.selected.height
                   + " at scale " + root.selected.scale
                   + "  →  " + Math.round(s.width) + "×" + Math.round(s.height) + " usable"
            }
          }

          ComboBox {
            id: rotationCombo
            width: parent.width
            model: ["0°", "90°", "180°", "270°"]
            currentIndex: root.selected ? root.selected.transform : 0
            onActivated: root.updateMonitorField(root.selected.name, "transform", currentIndex)
          }

          CheckBox {
            text: "Enabled"
            checked: root.selected ? !root.selected.disabled : true
            onToggled: root.updateMonitorField(root.selected.name, "disabled", !checked)
          }
        }
      }

      Row {
        anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: 16
        spacing: 8
        Text { text: root.applyError; color: "#ff8080"; visible: root.applyError !== "" }
        Button {
          text: root.operationState === "applying" ? "Applying…" : "Apply"
          enabled: root.operationState === "idle" && !root.fetchInFlight && !stopMirrorProc.running
          onClicked: root.applyLayout()
        }
      }

      Rectangle {
        visible: root.operationState === "awaitingConfirmation"
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: 360; height: 60; color: "#222"; radius: 6
        Row {
          anchors.centerIn: parent
          spacing: 12
          Text { text: "Keep these display settings? (" + root.revertSecondsLeft + "s)"; color: "white" }
          Button { text: "Keep changes"; onClicked: root.confirmAndPersist() }
          Button { text: "Revert"; onClicked: root.revertToSnapshot() }
        }
      }

      Keys.onEscapePressed: root.close()
      focus: root.opened
    }
  }

  // The window is instantiated hidden, so focus is re-acquired after mapping —
  // verified pattern, not a guess: identical to shell/Ui/SpeedTestOverlay.qml's
  // onOpenChanged handler (see Global Constraints for the precise citation).
  onOpenedChanged: {
    if (root.opened) Qt.callLater(function() {
      if (!root.opened) return
      card.forceActiveFocus()
    })
  }
}
