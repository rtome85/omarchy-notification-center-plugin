// Self-contained bar widget: the popup lives right here, anchored to the
// icon button via PopupCard, exactly like the original widget (this is what
// made the old widget position/size itself correctly — PopupCard anchors to
// anchorItem automatically, no manual screen-edge math needed).
//
// Data layer is rewired to the service surface confirmed working in the
// newer plugin (popupModel for live notifications, historyDir for on-disk
// history) instead of the old pendingModel/pastModel calls, which is why
// notifications weren't showing.
//
// UI: no more Pending/Recently tabs — a "Recent and live notifications"
// label with a Clear all button, then a single merged, newest-first list
// below (live + history combined).
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "NotificationLogic.js" as NotificationLogic

BarWidget {
  id: root
  moduleName: "shavanced.notification-center"

  property bool popupOpen: false
  function close() { popupOpen = false }

  property var filteredRows: []
  property var historyRows: []

  // Locally-dismissed history entries, hidden until they drop out of the
  // on-disk history on their own (see dismiss()).
  property var hiddenHistoryKeys: ({})
  function historyKey(row) {
    if (row.id !== undefined && row.id !== null && row.id !== 0) return "id:" + row.id
    return "k:" + row.app + "|" + row.summary + "|" + row.timestamp
  }

  // Look up the long-running notifications service through the shell host.
  readonly property var hostShell: bar && bar.shell ? bar.shell : null
  readonly property var notificationService: hostShell && hostShell.firstPartyServiceFor
    ? hostShell.firstPartyServiceFor("omarchy.notifications") : null

  readonly property string historyDir: notificationService && notificationService.historyDir
    ? String(notificationService.historyDir) : ""

  // Notifications still waiting to be looked at: everything the list shows
  // (live toasts + recent history), not just what's currently on screen —
  // a toast that already expired off-screen is still unattended.
  readonly property int unattendedCount: root.filteredRows.length

  // ---- DND (guarded: lives on Omarchy's first-party service, not here).
  readonly property bool dndSupported: !!notificationService
    && typeof notificationService.doNotDisturb === "boolean"
    && typeof notificationService.setDoNotDisturb === "function"
  readonly property bool dndOn: dndSupported && notificationService.doNotDisturb
  function toggleDnd() {
    if (dndSupported) notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
  }

  readonly property string icon: {
    if (root.dndOn) return "󰂛"
    if (root.unattendedCount > 0) return "󱅫"
    return "󰂚"
  }

  // Theme palette (mirrors the old widget's tokens).
  readonly property color colForeground: Color.foreground
  readonly property color colDim: Qt.darker(Color.foreground, 1.4)
  readonly property color colBorder: Style.normalBorderFor(Color.foreground, Color.accent)
  readonly property color colSurface: Style.normalFillFor(Color.foreground, Color.accent)
  readonly property color colAccent: Color.accent
  readonly property int cardRadius: notificationService && notificationService.cornerRadius
    ? notificationService.cornerRadius : Style.cornerRadius

  // Notification-content palette: mirrors the first-party NotificationCard so
  // a row in this list matches the same notification's toast appearance,
  // distinct from the surrounding popup chrome (which uses colForeground).
  readonly property color notifText: Color.notifications.text
  readonly property color notifDim: Qt.darker(Color.notifications.text, 1.4)
  readonly property color notifBody: Qt.darker(Color.notifications.text, 1.15)
  readonly property color notifBorder: Color.notifications.border
  readonly property color notifCountdown: Color.notifications.countdown

  function notificationIconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    return Quickshell.iconPath(value, true)
  }

  function formatTimestamp(ms) {
    var date = new Date(Number(ms) || Date.now())
    var now = new Date()
    var sameDay = date.getFullYear() === now.getFullYear()
      && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()
    var time = date.toLocaleTimeString(Qt.locale(), "hh:mm")
    return sameDay ? time : date.toLocaleDateString(Qt.locale(), "MMM d") + " · " + time
  }

  // ListView.model is bound directly to this plain array, so any reassignment
  // — even to structurally-identical content — is a full model reset: every
  // delegate (and its per-row hover state) is destroyed and recreated. The
  // 500ms poll timer calls rebuildRows() continuously while the popup is
  // open, so without this guard a row hovered mid-poll would flicker/appear
  // to double-render on every tick.
  function rowsEqual(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      var x = a[i], y = b[i]
      if (x.id !== y.id || x.isLive !== y.isLive || x.sourceIndex !== y.sourceIndex
        || x.app !== y.app || x.appIcon !== y.appIcon || x.summary !== y.summary
        || x.body !== y.body || x.glyph !== y.glyph || x.urgency !== y.urgency
        || x.timestamp !== y.timestamp) return false
    }
    return true
  }

  function rebuildRows() {
    var rows = []
    for (var h = 0; h < root.historyRows.length; ++h) {
      var history = root.historyRows[h]
      if (root.hiddenHistoryKeys[root.historyKey(history)]) continue
      rows.push({
        sourceIndex: -1,
        isLive: false,
        id: history.id,
        app: history.app,
        appIcon: history.appIcon,
        summary: history.summary,
        body: history.body,
        glyph: history.glyph,
        urgency: history.urgency,
        timestamp: history.timestamp
      })
    }
    var model = root.notificationService ? root.notificationService.popupModel : null
    if (!model) {
      if (!rowsEqual(rows, root.filteredRows)) root.filteredRows = rows
      return
    }
    for (var i = 0; i < model.count; ++i) {
      var row = model.get(i)
      if (!row) continue
      rows.push({
        sourceIndex: i,
        isLive: true,
        id: row.id !== undefined ? row.id : null,
        app: String(row.appName || row.app || "Unknown application"),
        appIcon: String(row.appIcon || ""),
        summary: String(row.summary || "Notification"),
        body: String(row.body || ""),
        glyph: String(row.glyph || NotificationLogic.glyphFromHints(row.hints)),
        urgency: Number(row.urgency || 1),
        timestamp: Number(row.timestamp || 0)
      })
    }
    rows.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    if (!rowsEqual(rows, root.filteredRows)) root.filteredRows = rows
  }

  function dismiss(row) {
    if (!row) return
    if (row.isLive) {
      if (root.notificationService && typeof root.notificationService.dismissPopup === "function")
        root.notificationService.dismissPopup(row.sourceIndex)
    } else {
      var key = root.historyKey(row)
      var next = Object.assign({}, root.hiddenHistoryKeys)
      next[key] = true
      root.hiddenHistoryKeys = next
      if (root.notificationService && typeof root.notificationService.removeHistoryEntry === "function")
        root.notificationService.removeHistoryEntry(row.id)
    }
    rebuildRows()
  }

  function clearAll() {
    if (!root.notificationService) return
    if (typeof root.notificationService.clearPopups === "function") root.notificationService.clearPopups()
    if (typeof root.notificationService.clearHistory === "function") root.notificationService.clearHistory()
    root.historyRows = []
    root.hiddenHistoryKeys = ({})
    rebuildRows()
  }

  function parseHistory(raw) {
    var parsed = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; ++i) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var value = JSON.parse(line)
        if (!value || typeof value !== "object") continue
        parsed.push({
          id: value.id !== undefined ? value.id : (value.originalId !== undefined ? value.originalId : null),
          app: String(value.app || "Unknown application"),
          appIcon: String(value.appIcon || ""),
          summary: String(value.summary || "Notification"),
          body: String(value.body || ""),
          glyph: String(value.glyph || ""),
          urgency: Number(value.urgency === undefined ? 1 : value.urgency),
          timestamp: Number(value.timestamp || 0)
        })
      } catch (e) {
        // A torn write is ignored, matching the first-party parser.
      }
    }
    parsed.sort(function(a, b) { return b.timestamp - a.timestamp })
    root.historyRows = parsed.slice(0, root.notificationService && root.notificationService.historyLimit
      ? Number(root.notificationService.historyLimit) : 10)
    rebuildRows()
  }

  function refreshHistory() {
    if (!root.historyDir || historyReader.running) return
    historyReader.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    historyReader.running = true
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      refreshHistory()
      rebuildRows()
      // wlr-layer-shell popups can render and accept mouse clicks while
      // still not reliably routing keystrokes without an explicit grab.
      Qt.callLater(function() { if (root.popupOpen) popupContent.forceActiveFocus() })
    }
  }

  // Keeps polling regardless of popupOpen: the bar icon's unattendedCount
  // depends on historyRows too, and a toast that expires or gets dismissed
  // while the popup is closed still needs to flip it back on. Gating this
  // on popupOpen (as before) left the icon stuck reporting "no notifications"
  // between the toast's own timeout and the next time the popup was opened.
  // DND-silenced notifications never touch popupModel at all — polling is
  // also the only way those ever reach the icon.
  Timer {
    interval: 500
    repeat: true
    running: true
    onTriggered: root.refreshHistory()
  }

  Component.onCompleted: root.refreshHistory()

  Process {
    id: historyReader
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseHistory(text)
    }
  }

  Connections {
    target: root.notificationService ? root.notificationService.popupModel : null
    function onCountChanged() { root.rebuildRows() }
    function onDataChanged() { root.rebuildRows() }
    function onRowsInserted() { root.rebuildRows() }
    // A row leaving popupModel (dismissed or expired) means the service is
    // archiving it into history right about now — refresh instead of just
    // rebuilding from the stale cache, so the icon doesn't gap between "left
    // the live model" and "picked up from history" on the next poll tick.
    function onRowsRemoved() { root.refreshHistory(); root.rebuildRows() }
    function onModelReset() { root.refreshHistory(); root.rebuildRows() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.unattendedCount > 0 && !root.dndOn
    tooltipText: root.dndOn ? "DND on — right-click to turn off"
      : (root.unattendedCount > 0
        ? root.unattendedCount + (root.unattendedCount === 1 ? " notification" : " notifications")
        : "Notification Center")

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.toggleDnd()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(440))
    contentHeight: popup.cappedContentHeight(Style.space(540))

    ColumnLayout {
      id: popupContent
      anchors.fill: parent
      spacing: Style.space(10)
      focus: true
      Keys.onEscapePressed: root.close()

      // ----------------------------------------- header
      PanelHero {
        Layout.fillWidth: true
        title: "Notifications"
        meta: root.unattendedCount === 1 ? "1 notification" : root.unattendedCount + " notifications"
        foreground: root.colForeground
        fontFamily: root.bar ? root.bar.fontFamily : ""
        iconOpacity: root.unattendedCount > 0 ? 1.0 : 0.6

        iconComponent: Component {
          Text {
            text: root.icon
            color: root.dndOn ? root.colDim : (root.unattendedCount > 0 ? root.colAccent : root.colForeground)
            font.family: root.bar ? root.bar.fontFamily : ""
            font.pixelSize: Style.font.display
          }
        }

        // Compact on/off switch on the trailing edge of the hero, mirroring
        // how first-party panels (e.g. Tailscale) place their power switch.
        trailingControl: Component {
          Row {
            visible: root.dndSupported
            spacing: Style.space(6)

            Text {
              text: root.dndOn ? "DND on" : "DND off"
              font.family: root.bar ? root.bar.fontFamily : ""
              color: root.colDim
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: dndSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.dndOn
              foreground: root.colForeground
              accent: root.colAccent
              onToggled: root.toggleDnd()

              PanelToolTip {
                visible: dndSwitch.containsMouse
                text: root.dndOn ? "Allow notifications" : "Silence notifications"
                fontFamily: root.bar ? root.bar.fontFamily : ""
              }
            }
          }
        }
      }

      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.colForeground
      }

      // ----------------------------------------- label + clear all
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: "Recent and live notifications"
          font.family: root.bar ? root.bar.fontFamily : ""
          color: root.colDim
          font.pixelSize: Style.font.caption
        }

        Button {
          text: "Clear all"
          foreground: root.colForeground
          accent: root.colAccent
          fontFamily: root.bar ? root.bar.fontFamily : ""
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          bordered: true
          onClicked: root.clearAll()
        }
      }

      // ----------------------------------------- list
      ListView {
        id: listView
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(8)
        model: root.filteredRows
        visible: count > 0

        delegate: CursorSurface {
          id: rowCard
          required property var modelData

          readonly property string smallIconSource: root.notificationIconSource(modelData.appIcon)
          readonly property string sanitizedBody: NotificationLogic.sanitizeBody(modelData.body, modelData.app, modelData.appIcon)
          readonly property bool singleLineToast: sanitizedBody.length === 0
          readonly property bool summaryStartsWithGlyph: NotificationLogic.summaryStartsWithGlyph(modelData.summary)
          // Some senders (e.g. omarchy-action toasts) bake the glyph into the
          // summary text itself when there's no body to pair it with — skip
          // the separate glyph slot so it isn't shown twice.
          readonly property bool collapseRedundantIcon: singleLineToast && modelData.glyph === "" && summaryStartsWithGlyph
          readonly property bool hasIcon: modelData.glyph === "" && smallIconSource.length > 0

          width: listView.width
          implicitHeight: rowContent.implicitHeight + Style.spacing.panelGap
          radius: root.cardRadius
          bordered: true
          hasCursor: rowHover.hovered
          foreground: root.notifBorder
          accent: root.colAccent

          // HoverHandler (not MouseArea.containsMouse) tracks row hover: the
          // dismiss PanelActionButton below has its own hoverEnabled
          // MouseArea, and a classic MouseArea covering the row would lose
          // "contains mouse" the instant the pointer crosses onto that
          // button (the topmost MouseArea claims hover exclusively) — flipping
          // the button's `visible` off, which put the pointer back over the
          // row-only area, flipping it on again: a flicker loop right where
          // you'd hover to dismiss. HoverHandler is a non-exclusive pointer
          // handler, so it keeps reporting hovered while the pointer is over
          // a child's own MouseArea. Mirrors NotificationCard.qml's own
          // hoverTracker.
          HoverHandler {
            id: rowHover
          }

          // Left click dismisses.
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismiss(rowCard.modelData)
          }

          RowLayout {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: rowCard.borderLeft + Style.space(12)
            anchors.rightMargin: rowCard.borderRight + Style.space(12)
            spacing: Style.space(10)

            Text {
              Layout.alignment: Qt.AlignTop
              visible: rowCard.modelData.glyph !== "" && !rowCard.collapseRedundantIcon
              text: rowCard.modelData.glyph
              color: rowCard.modelData.urgency === 2 ? Color.urgent
                : (rowCard.modelData.urgency === 0 ? root.notifDim : root.notifCountdown)
              font.family: root.bar ? root.bar.fontFamily : ""
              font.pixelSize: Style.font.icon
            }

            Item {
              Layout.preferredWidth: Style.space(32)
              Layout.preferredHeight: Style.space(32)
              Layout.alignment: Qt.AlignVCenter
              visible: rowCard.hasIcon && rowIconImage.status !== Image.Error

              Image {
                id: rowIconImage
                anchors.fill: parent
                source: rowCard.smallIconSource
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                asynchronous: true
                smooth: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  text: rowCard.modelData.app
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.notifDim
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  text: root.formatTimestamp(rowCard.modelData.timestamp)
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.notifDim
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                Layout.fillWidth: true
                visible: rowCard.modelData.summary.length > 0
                text: rowCard.modelData.summary
                font.family: "Liberation Sans"
                color: root.notifText
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
              }

              Text {
                Layout.fillWidth: true
                visible: rowCard.sanitizedBody.length > 0
                text: rowCard.sanitizedBody
                textFormat: Text.PlainText
                font.family: "Liberation Sans"
                color: root.notifBody
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 3
              }
            }

            // Close (x): visible ONLY while hovering this row.
            PanelActionButton {
              Layout.alignment: Qt.AlignVCenter
              visible: rowHover.hovered
              iconText: "✕"
              tooltipText: "Dismiss"
              foreground: root.notifDim
              fontFamily: root.bar ? root.bar.fontFamily : ""
              fontSize: Style.font.bodySmall
              onClicked: function() { root.dismiss(rowCard.modelData) }
            }
          }
        }
      }

      // ----------------------------------------- empty state
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: listView.count === 0

        ColumnLayout {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "󰂚"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colBorder
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "No notifications"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colDim
            font.pixelSize: Style.font.body
          }
        }
      }

      // ----------------------------------------- footer legend
      Text {
        Layout.fillWidth: true
        text: "Left-click or hover the ✕ to dismiss · Esc closes"
        font.family: root.bar ? root.bar.fontFamily : ""
        color: Qt.darker(root.colForeground, 1.55)
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
