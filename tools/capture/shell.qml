// Isolated screenshot host: the production widget, reader and service with an
// invented track. The copied service reads no MPRIS player and runs no lookup.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons

ShellRoot {
  id: host
  property var fixtures: ({})
  Component.onCompleted: Style.cornerRadius = 10
  FileView {
    path: Quickshell.env("LYRICS_FIXTURES")
    onLoaded: host.fixtures = JSON.parse(text())
  }

  // Stands in for an MPRIS player, with the fields the service reads.
  QtObject {
    id: player
    property string trackTitle: ""
    property string trackArtist: ""
    property string trackAlbum: ""
    property string trackArtUrl: ""
    property bool isPlaying: true
    property bool positionSupported: true
    property bool lengthSupported: true
    property real length: 0
    property real position: 0
    property bool canSeek: true
  }

  Loader { id: service; source: "file://" + Quickshell.env("LYRICS_PLUGIN") + "/Service.qml" }
  QtObject {
    id: bar
    property string position: "top"
    property real barSize: 26
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property color urgent: Color.urgent
    property color barForeground: Color.bar.text
    property color foreground: Color.bar.text
    property string fontFamily: Style.font.family
    property var activePopout: null
    property var shell: QtObject { function serviceFor(name) { return service.item } }
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function showTooltip(item, text) {}
    function hideTooltip(item) {}
  }
  FloatingWindow {
    implicitWidth: 1400; implicitHeight: 26
    color: Color.bar.background
    Loader {
      id: widget
      anchors.right: parent.right
      anchors.rightMargin: 40
      height: 26
      width: item ? item.implicitWidth : 0
      source: service.item ? "file://" + Quickshell.env("LYRICS_PLUGIN") + "/BarWidget.qml" : ""
      onLoaded: {
        item.settings = { panelWidthPercent: 45, panelHeightPercent: 72, hideWhenIdle: true }
        item.bar = bar
      }
    }
  }

  FloatingWindow {
    id: preview
    implicitWidth: 2560; implicitHeight: 1600
    visible: false
    color: "#090503"
    Item {
      id: composition
      width: 2560; height: 1600
      Image {
        anchors.fill: parent
        source: Quickshell.env("LYRICS_WALLPAPER")
        fillMode: Image.PreserveAspectCrop
        layer.enabled: true
        layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: 0.7 }
      }
      Rectangle { anchors.fill: parent; color: "#a6000000" }
      Image {
        id: expandedShot
        x: 255; y: (1600 - height) / 2
        width: sourceSize.width; height: sourceSize.height
        source: preview.visible ? "file://" + Quickshell.env("LYRICS_OUTPUT") + "/expanded.png" : ""
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.8; shadowOpacity: 0.6; shadowVerticalOffset: 20 }
      }
      Image {
        x: 1465; y: 1600 - 110 - height
        width: sourceSize.width; height: sourceSize.height
        source: preview.visible ? "file://" + Quickshell.env("LYRICS_OUTPUT") + "/compact.png" : ""
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.8; shadowOpacity: 0.6; shadowVerticalOffset: 20 }
      }
    }
  }

  IpcHandler {
    target: "capture"
    function ready(): bool { return !!widget.item && !!service.item && !!host.fixtures.record }
    function play(): string {
      var f = host.fixtures
      player.trackTitle = f.title
      player.trackArtist = f.artist
      player.trackAlbum = f.album
      player.trackArtUrl = f.cover
      player.length = f.length
      player.position = f.position
      service.item.activePlayer = player
      service.item.adopt(f.record)
      widget.item.popupOpen = true
      var s = service.item.statusObject()
      return JSON.stringify({ state: s.state, synced: s.synced, activeIndex: s.activeIndex, line: service.item.currentLine })
    }
    function reader(expanded: bool): void {
      widget.item.captureReader.setExpanded(expanded)
    }
    function lyricsList() {
      var reader = widget.item.captureReader
      for (var i = 0; i < reader.children.length; i++)
        if (reader.children[i].contentY !== undefined) return reader.children[i]
      return null
    }
    // How much of a line the list cuts off at its top and bottom edges.
    function cuts(): string {
      var list = lyricsList()
      var top = list.itemAt(0, list.contentY + 1)
      var bottom = list.itemAt(0, list.contentY + list.height - 1)
      return JSON.stringify({
        fontSize: widget.item.captureReader.fontSize,
        activeIndex: service.item.activeIndex,
        top: top ? list.contentY - top.y : -1,
        bottom: bottom ? bottom.y + bottom.height - (list.contentY + list.height) : -1,
        topText: top ? top.lineText : "", bottomText: bottom ? bottom.lineText : ""
      })
    }
    // Scrolls by three lines at most so both edges fall on a whole line,
    // or on a blank one, where a cut shows nothing. The sung line stays in
    // view; it is only no longer exactly centred.
    function align(): string {
      var list = lyricsList()
      var top = list.itemAt(0, list.contentY + 1)
      if (!top) return cuts()
      var start = list.contentY
      // Item tops from three rows above to three below, nearest first.
      var options = [top.y]
      var below = top, above = top
      for (var k = 0; k < 3; k++) {
        if (below) below = list.itemAt(0, below.y + below.height + 1)
        if (below) options.push(below.y)
        if (above) above = list.itemAt(0, above.y - 1)
        if (above) options.push(above.y)
      }
      for (var i = 0; i < options.length; i++) {
        list.contentY = options[i]
        var c = JSON.parse(cuts())
        if ((c.top <= 1 || c.topText === "") && (c.bottom <= 1 || c.bottomText === "")) return cuts()
      }
      list.contentY = start
      return cuts()
    }
    function fontSize(size: int): void { widget.item.captureReader.setFontSize(size) }
    // Scrolls to the sung line again once the new layout has settled.
    function settle(): void { widget.item.captureReader.scrollToActive() }
    function panelHeight(percent: int): void {
      widget.item.settings = { panelWidthPercent: 45, panelHeightPercent: percent, hideWhenIdle: true }
    }
    function grab(path: string): string {
      var card = widget.item.capturePopup.captureCard
      if (!card) return "No panel card"
      return card.grabToImage(result => result.saveToFile(path)) ? "ok" : "Capture failed"
    }
    function preparePreview(): void { preview.visible = true }
    function grabPreview(path: string): bool {
      return composition.grabToImage(result => result.saveToFile(path), Qt.size(1280, 800))
    }
  }
}
