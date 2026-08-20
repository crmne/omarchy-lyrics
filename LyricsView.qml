import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Contents of the bar popup. Everything network-facing lives in Service.qml;
// this file only renders what the service has already loaded.
//
// Header and controls are pinned to the top, the source line to the bottom,
// and the lyrics fill whatever is left.
Item {
  id: root

  property QtObject bar: null
  property QtObject service: null
  property bool active: false
  property real maxPanelHeight: 0

  readonly property string lookupState: service ? service.lookupState : "idle"
  readonly property bool ready: lookupState === "ready"
  readonly property bool hasSynced: !!(service && service.hasSynced)
  readonly property var lines: {
    if (!service || !ready) return []
    return hasSynced ? service.syncedLines : service.plainLines
  }
  readonly property int activeIndex: hasSynced && service ? service.activeIndex : -1
  readonly property real position: service ? service.position : 0
  readonly property real trackLength: service ? service.trackLength : 0

  // Only art the player points at on disk or over https. Track metadata can
  // name any URL, and loading one is a request we never asked for.
  readonly property string coverSource: {
    var url = root.service ? String(root.service.artUrl || "") : ""
    return /^(file:|https:)/i.test(url) ? url : ""
  }

  readonly property color foreground: bar ? bar.barForeground : Color.popups.text
  readonly property color accent: Color.accent
  readonly property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)

  // Reading preferences outlive the popup, and there is no shell API to write
  // back into a widget's shell.json entry, so they get their own state file.
  // Auto by default: the size follows the shell's own font scale and the room
  // the panel has. Touching the size buttons pins it until Auto is pressed.
  property bool fontSizeAuto: true
  property int manualFontSize: 15
  property bool expanded: false
  property bool preferencesLoaded: false
  // Keeping the sung line in view, until the reader scrolls somewhere else.
  property bool following: true

  readonly property int minFontSize: 11
  readonly property int maxFontSize: 30

  // Anchored on the shell's body size, so a bigger `font` base in shell.json
  // carries through here rather than being second-guessed. Growth with the
  // panel is damped: twice the width does not want twice the type, only enough
  // of a step to read it from further away.
  readonly property int autoFontSize: {
    var base = Style.font.body * 1.25
    var compact = Style.space(420)
    var growth = width > 0 && compact > 0 ? Math.max(1, width / compact) : 1
    var wanted = base * (1 + 0.7 * (growth - 1))
    return Math.round(Math.max(minFontSize, Math.min(maxFontSize, wanted)))
  }
  readonly property int fontSize: fontSizeAuto ? autoFontSize : manualFontSize
  readonly property int gap: Style.space(8)
  readonly property real compactBodyHeight: Style.space(300)
  // Lyrics wrap, so their real height is not known until they are laid out.
  // Estimating from the line count keeps the popup's size out of the text's.
  readonly property real naturalBodyHeight: Math.max(Style.space(120), lines.length * lineFont.height * 1.6)
  readonly property real chromeHeight: chrome.implicitHeight + gap * 2

  implicitWidth: Style.space(420)
  implicitHeight: {
    var bodyHeight = expanded ? naturalBodyHeight : Math.min(naturalBodyHeight, compactBodyHeight)
    var wanted = chromeHeight + bodyHeight
    return maxPanelHeight > 0 ? Math.min(maxPanelHeight, wanted) : wanted
  }

  FontMetrics {
    id: lineFont
    font.family: Style.font.family
    font.pixelSize: root.fontSize
  }

  function applyPreferences(raw) {
    try {
      var stored = JSON.parse(String(raw || "{}"))
      if (stored.fontSize) manualFontSize = Math.max(minFontSize, Math.min(maxFontSize, Number(stored.fontSize)))
      // Files written before Auto existed only ever hold the default size, so
      // they should not be read as somebody having pinned it.
      if (stored.fontSizeAuto !== undefined) fontSizeAuto = stored.fontSizeAuto === true
      if (stored.expanded !== undefined) expanded = stored.expanded === true
      if (stored.offset !== undefined && service) service.offset = Number(stored.offset) || 0
    } catch (error) {
      // A corrupt state file just means defaults.
    }
    preferencesLoaded = true
  }

  function savePreferences() {
    if (!preferencesLoaded) return
    preferencesFile.setText(JSON.stringify({
      fontSize: manualFontSize,
      fontSizeAuto: fontSizeAuto,
      expanded: expanded,
      offset: service ? service.offset : 0
    }, null, 2) + "\n")
  }

  function setFontSize(size) {
    var next = Math.max(minFontSize, Math.min(maxFontSize, Math.round(size)))
    // Stepping the size is what pins it; the button reads from whatever is on
    // screen now, so the first press nudges the automatic size rather than
    // jumping back to some size chosen ages ago.
    manualFontSize = next
    fontSizeAuto = false
    savePreferences()
  }

  function useAutoFontSize() {
    if (fontSizeAuto) return
    fontSizeAuto = true
    savePreferences()
  }

  function setExpanded(value) {
    if (expanded === value) return
    expanded = value
    savePreferences()
  }

  function nudgeOffset(delta) {
    if (!service) return
    service.offset = Math.round((service.offset + delta) * 10) / 10
    savePreferences()
  }

  function scrollToActive() {
    if (!following || !ready || !lines.length) return
    if (hasSynced) {
      if (activeIndex >= 0 && activeIndex < lines.length) {
        lyricsList.positionViewAtIndex(activeIndex, ListView.Center)
      } else {
        // Before the first line there is nothing to highlight, and the song is
        // in its intro. Without this the view stays wherever it was left, so
        // replaying a finished track sat at the end of the words.
        lyricsList.positionViewAtBeginning()
      }
      return
    }
    // Plain lyrics carry no timestamps, so how far through the track we are is
    // the only guide to which part of the words is being sung.
    var span = Math.max(0, lyricsList.contentHeight - lyricsList.height)
    lyricsList.contentY = span * Model.progressFraction(position, trackLength)
  }

  FileView {
    id: preferencesFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/lyrics.json"
    printErrors: false
    onLoaded: root.applyPreferences(text())
    onLoadFailed: root.preferencesLoaded = true
  }

  onActiveIndexChanged: scrollToActive()

  // Changing the type size or the panel size reflows every line, so wherever
  // the sung line had been is no longer where it is. Qt.callLater both waits
  // for the new layout and collapses the two into a single scroll.
  onFontSizeChanged: Qt.callLater(scrollToActive)
  onExpandedChanged: Qt.callLater(scrollToActive)
  onActiveChanged: {
    if (!active) return
    // Coming back to an open panel should land on the line being sung.
    following = true
    Qt.callLater(scrollToActive)
  }

  Connections {
    target: root.service
    function onRecordChanged() {
      root.following = true
      lyricsList.contentY = 0
      Qt.callLater(root.scrollToActive)
    }

    // Synced lyrics move on the active line; plain ones have only the clock.
    function onPositionChanged() {
      if (!root.hasSynced) root.scrollToActive()
    }
  }

  // --- header, pinned to the top -------------------------------------------

  Column {
    id: chrome
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: root.gap

    Item {
      width: parent.width
      height: Math.max(albumArt.height, heading.implicitHeight)

      // Whatever cover the player is offering. Hidden rather than left as an
      // empty square when a track has none, or while it is still loading.
      Rectangle {
        id: albumArt
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? Style.space(42) : 0
        height: Style.space(42)
        radius: Style.space(6)
        clip: true
        visible: cover.status === Image.Ready
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        Image {
          id: cover
          anchors.fill: parent
          source: root.coverSource
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          sourceSize.width: 128
          sourceSize.height: 128
        }
      }

      Column {
        id: heading
        anchors.left: albumArt.visible ? albumArt.right : parent.left
        anchors.leftMargin: albumArt.visible ? Style.space(10) : 0
        anchors.right: headerActions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.service && root.service.title ? root.service.title : "Nothing playing"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.service ? root.service.artist : ""
          color: root.subtle
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          visible: text !== ""
        }
      }

      Row {
        id: headerActions
        anchors.right: parent.right
        anchors.verticalCenter: heading.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: "\u{F0450}"
          tooltipText: "Look the lyrics up again"
          foreground: root.foreground
          enabled: !!(root.service && root.service.hasMedia)
          onClicked: if (root.service) root.service.refresh()
        }

        PanelActionButton {
          iconText: root.expanded ? "\u{F0294}" : "\u{F0293}"
          tooltipText: root.expanded ? "Back to the compact reader" : "Give the lyrics more room"
          foreground: root.expanded ? Color.accent : root.foreground
          onClicked: root.setExpanded(!root.expanded)
        }
      }
    }

    // Only synced lyrics have anything to follow or to nudge.
    Item {
      width: parent.width
      height: Math.max(timing.implicitHeight, textSize.implicitHeight)
      visible: root.ready && root.hasSynced

      // Two groups anchored to their own edges. Sizing a spacer between them by
      // hand is what pushed the text-size buttons off the panel: the row holds
      // seven items and six gaps, and the arithmetic counted neither correctly.
      Row {
        id: timing
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F04FE}"
          tooltipText: root.following ? "Following the song" : "Follow the song again"
          foreground: root.following ? Color.accent : root.foreground
          onClicked: {
            root.following = true
            root.scrollToActive()
          }
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0374}"
          tooltipText: "Lyrics run early: hold them back"
          foreground: root.foreground
          onClicked: root.nudgeOffset(-0.5)
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          horizontalAlignment: Text.AlignHCenter
          text: {
            var value = root.service ? root.service.offset : 0
            if (!value) return "in time"
            return (value > 0 ? "+" : "") + value.toFixed(1) + "s"
          }
          color: root.service && root.service.offset ? root.accent : root.subtle
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0415}"
          tooltipText: "Lyrics run late: bring them forward"
          foreground: root.foreground
          onClicked: root.nudgeOffset(0.5)
        }
      }

      // Its own icons rather than a second pair of plus and minus, which read
      // as more timing controls sitting oddly far from the first pair.
      Row {
        id: textSize
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0068}"
          tooltipText: root.fontSizeAuto
            ? "Text size follows the panel"
            : "Let the text size follow the panel again"
          foreground: root.fontSizeAuto ? Color.accent : root.foreground
          onClicked: root.useAutoFontSize()
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F09F3}"
          tooltipText: "Smaller text"
          foreground: root.foreground
          enabled: root.fontSize > root.minFontSize
          onClicked: root.setFontSize(root.fontSize - 1)
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F09F4}"
          tooltipText: "Bigger text"
          foreground: root.foreground
          enabled: root.fontSize < root.maxFontSize
          onClicked: root.setFontSize(root.fontSize + 1)
        }
      }
    }

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
      visible: root.ready
    }
  }

  // --- the lyrics, filling everything below the header --------------------

  ListView {
    id: lyricsList
    anchors.top: chrome.bottom
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.gap
    anchors.bottomMargin: root.gap
    visible: root.ready
    clip: true
    model: root.lines
    boundsBehavior: Flickable.StopAtBounds
    cacheBuffer: Math.max(0, Math.round(height))

    // Scrolling by hand means the reader wants to look elsewhere; following
    // resumes on the button, or when the track changes.
    onDragStarted: root.following = false

    // Long lyrics run past the panel; a bar makes that visible.
    // Gated on real overflow: AsNeeded compares height to contentHeight, and
    // when they match the ratio rounds to just under 1, leaving a full-length
    // handle that cannot move.
    ScrollBar.vertical: ScrollBar {
      id: lyricsVBar
      policy: lyricsList.contentHeight > lyricsList.height + 1
        ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      contentItem: Rectangle {
        implicitWidth: Style.space(4)
        radius: width / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                       lyricsVBar.pressed ? 0.55 : 0.28)
      }
    }

    delegate: Item {
      id: lineItem
      required property var modelData
      required property int index

      readonly property bool synced: root.hasSynced
      // Synced entries are {time, text}; plain lyrics are bare strings.
      readonly property string lineText: synced ? String(modelData.text || "") : String(modelData || "")
      readonly property bool current: synced && index === root.activeIndex

      width: ListView.view.width
      height: Math.max(root.fontSize * 0.9, lineLabel.implicitHeight) + Style.space(6)

      Text {
        textFormat: Text.PlainText
        id: lineLabel
        width: parent.width - Style.space(4)
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: lineItem.lineText
        color: lineItem.current ? root.accent : root.subtle
        font.family: Style.font.family
        font.pixelSize: root.fontSize
        font.bold: lineItem.current
        wrapMode: Text.WordWrap

        Behavior on color {
          ColorAnimation { duration: 220 }
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: lineItem.synced && !!(root.service && root.service.activePlayer)
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        // Timestamps are only worth having if they can take you there.
        onClicked: if (root.service) root.service.seekTo(lineItem.modelData.time)
      }
    }
  }

  // --- everything that is not loaded lyrics --------------------------------

  Item {
    anchors.fill: lyricsList
    visible: !root.ready

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      color: root.subtle
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
      text: {
        switch (root.lookupState) {
        case "idle": return "Play something and its lyrics show up here."
        case "searching": return "Looking for lyrics…"
        case "empty": return root.service && root.service.instrumental
          ? "This one is instrumental."
          : "No lyrics found for this one."
        case "error": return root.service ? root.service.errorText : "Something went wrong."
        }
        return ""
      }
    }
  }

}
