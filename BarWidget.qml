// Read the daemon's sanitised state; third-party widgets cannot access its service.
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "NotificationLogic.js" as NotificationLogic

BarWidget {
  id: root
  moduleName: "shavanced.notification-center"

  property bool popupOpen: false
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }
  onPopupOpenChanged: {
    if (popupOpen) Qt.callLater(function() {
      if (root.popupOpen) popupContent.forceActiveFocus()
    })
  }
  property var filteredRows: []
  property var liveRows: []
  property var historyRows: []
  // shortcut: dismissals hide history for this shell session; use a daemon API when one exists.
  property var hiddenHistoryKeys: ({})
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  readonly property int unattendedCount: filteredRows.length
  property bool dndOn: false
  readonly property bool dndSupported: true
  readonly property string icon: dndOn ? "󰂛" : unattendedCount > 0 ? "󱅫" : "󰂚"

  readonly property color colForeground: Commons.Color.foreground
  readonly property color colDim: Qt.darker(Commons.Color.foreground, 1.4)
  readonly property color colBorder: Style.normalBorderFor(colForeground, colAccent)
  readonly property color colSurface: Style.normalFillFor(colForeground, colAccent)
  readonly property color colAccent: Commons.Color.accent
  readonly property int cardRadius: Style.cornerRadius
  readonly property color notifText: Commons.Color.notifications.text
  readonly property color notifDim: Qt.darker(notifText, 1.4)
  readonly property color notifBody: Qt.darker(notifText, 1.15)
  readonly property color notifBorder: Commons.Color.notifications.border
  readonly property color notifCountdown: Commons.Color.notifications.countdown

  function rebuildRows() {
    var rows = NotificationLogic.mergeCurrentRows(liveRows, historyRows, hiddenHistoryKeys)
    if (JSON.stringify(rows) !== JSON.stringify(filteredRows)) filteredRows = rows
  }
  onLiveRowsChanged: rebuildRows()
  onHistoryRowsChanged: rebuildRows()

  function toggleDnd() {
    if (!dndCall.running) dndCall.running = true
  }
  Process {
    id: dndCall
    command: ["omarchy-shell", "notifications", "toggleDnd"]
    stdout: StdioCollector {
      onStreamFinished: {
        var state = text.trim()
        if (state === "on" || state === "off") root.dndOn = state === "on"
      }
    }
  }

  Process {
    id: actionCall
    stdout: StdioCollector { id: actionReply }
    stderr: StdioCollector { id: actionError }
    onExited: function(code) {
      if (code !== 0) console.warn("Notification center action failed:", actionError.text)
    }
  }

  function dismiss(row) {
    if (!row || actionCall.running) return
    var hidden = Object.assign({}, hiddenHistoryKeys)
    hidden[row.key] = true
    hiddenHistoryKeys = hidden
    // shortcut: Omarchy dismisses by summary substring; identical summaries close together.
    if (row.isLive && row.summary !== "") {
      actionCall.command = ["omarchy-shell", "notifications", "dismiss", row.summary]
      actionCall.running = true
    }
    rebuildRows()
  }

  function clearAll() {
    if (actionCall.running) return
    var hidden = Object.assign({}, hiddenHistoryKeys)
    for (var i = 0; i < filteredRows.length; i++) hidden[filteredRows[i].key] = true
    hiddenHistoryKeys = hidden
    actionCall.command = ["omarchy-shell", "notifications", "dismissAll"]
    actionCall.running = true
    rebuildRows()
  }

  IpcHandler {
    target: root.moduleName
    function toggle(): string { root.toggle(); return "ok" }
    function close(): string { root.broadcast("close"); return "ok" }
    function toggleDnd(): string { root.toggleDnd(); return "ok" }
    function dismissKey(key: string): string {
      var row = root.filteredRows.filter(function(row) { return row.key === key })[0]
      if (!row) return "missing"
      root.dismiss(row)
      return "ok"
    }
    function probe(): string {
      return JSON.stringify({ live: root.liveRows.length, history: root.historyRows.length,
        action: actionReply.text.trim(), shown: root.filteredRows.length, hidden: Object.keys(root.hiddenHistoryKeys).length, dnd: root.dndOn, opened: root.popupOpen })
    }
  }

  FileView {
    id: liveFile
    path: root.stateDir + "/live.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.liveRows = NotificationLogic.parseCurrentRows(text(), true)
    onLoadFailed: root.liveRows = []
  }
  FileView {
    id: historyFile
    path: root.stateDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.historyRows = NotificationLogic.parseCurrentRows(text(), false)
    onLoadFailed: root.historyRows = []
  }
  FileView {
    id: quietFile
    path: root.stateDir + "/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.dndOn = JSON.parse(text()).dnd === true } catch (e) {}
    }
  }
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: { liveFile.reload(); historyFile.reload(); quietFile.reload() }
  }

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
            textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignTop
              visible: rowCard.modelData.glyph !== "" && !rowCard.collapseRedundantIcon
              text: rowCard.modelData.glyph
              color: rowCard.modelData.urgency === 2 ? Commons.Color.urgent
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
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: rowCard.modelData.app
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.notifDim
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.formatTimestamp(rowCard.modelData.timestamp)
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.notifDim
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: rowCard.sanitizedBody.length > 0
                text: rowCard.sanitizedBody
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
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            text: "󰂚"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colBorder
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            textFormat: Text.PlainText
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
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Dismiss hides history until shell restart · Esc closes"
        font.family: root.bar ? root.bar.fontFamily : ""
        color: Qt.darker(root.colForeground, 1.55)
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
