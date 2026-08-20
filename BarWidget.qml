import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar entry point: a microphone that lights up when the song playing has
// lyrics, and opens the reader when clicked.
BarWidget {
  id: root
  moduleName: "crmne.lyrics"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("crmne.lyrics") : null
  readonly property string lookupState: service ? service.lookupState : "idle"
  readonly property bool hasMedia: service ? service.hasMedia : false
  readonly property bool ready: lookupState === "ready"

  readonly property bool hideWhenIdle: setting("hideWhenIdle", true) === true
  readonly property int panelWidthPercent: Math.max(20, Math.min(100, Number(setting("panelWidthPercent", 34))))
  readonly property int panelHeightPercent: Math.max(30, Math.min(100, Number(setting("panelHeightPercent", 100))))

  property bool popupOpen: false

  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  onPopupOpenChanged: if (service) service.panelOpen = popupOpen

  visible: hasMedia || !hideWhenIdle
  implicitWidth: visible ? (vertical ? barSize : button.implicitWidth) : 0
  implicitHeight: barSize

  Connections {
    target: root.service
    function onToggleRequested() { root.toggle() }
    function onOpenRequested() { root.popupOpen = true }
    function onCloseRequested() { root.popupOpen = false }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0370}"
    dimmed: !root.ready
    tooltipText: {
      if (!root.hasMedia) return "Lyrics"
      var song = root.service ? root.service.nowPlaying : ""
      switch (root.lookupState) {
      case "searching": return "Looking for lyrics\n" + song
      case "ready": {
        // While a synced track plays, the line being sung is more useful than
        // the name of the song, which the bar already shows elsewhere.
        var line = root.service ? root.service.currentLine : ""
        if (line) return line
        return song + (root.service && root.service.hasSynced ? "\nSynced lyrics" : "\nLyrics")
      }
      case "empty": return root.service && root.service.instrumental
        ? "Instrumental\n" + song
        : "No lyrics found\n" + song
      case "error": return root.service ? root.service.errorText : "Lyrics"
      }
      return song
    }

    // WidgetButton owns the mouse area and registers its click region with the
    // bar; a MouseArea laid over the top never gets the events, only hover.
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.service) root.service.refresh()
      } else {
        root.toggle()
      }
    }
  }

  // No centerOnBar: the card anchors under this widget and slides to stay on
  // screen, so a bar icon on the right opens a panel on the right.
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(
      reader.expanded && popup.screenW > 0
        ? popup.screenW * root.panelWidthPercent / 100
        : Style.space(420))
    contentHeight: popup.fittedContentHeight(reader.implicitHeight)
    onOpenChanged: if (!open) root.popupOpen = false

    LyricsView {
      id: reader
      anchors.fill: parent
      bar: root.bar
      service: root.service
      active: root.popupOpen
      maxPanelHeight: popup.availableCardHeight > 0
        ? popup.availableCardHeight * root.panelHeightPercent / 100 - popup.verticalContentInset
        : 0
    }
  }
}
