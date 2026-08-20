import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Model.js" as Model

// Watches MPRIS and keeps the lyrics for the current track loaded, along with
// which line the song is on. Lives in the service plugin so the lookup happens
// once per song no matter how many monitors show the bar widget.
Item {
  id: root

  // Raised by IPC so a keybind can drive the panel the widget owns.
  signal toggleRequested()
  signal openRequested()
  signal closeRequested()

  // Mirrored back by the widget so `status` reports whether the panel is up.
  property bool panelOpen: false

  // Seconds to shift the timing by, for uploads that run early or late.
  property real offset: 0

  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/lrclib"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }
  // Called explicitly rather than through the shebang: the shell inherits a
  // PATH where `python3` may be a version manager's shim.
  readonly property string python: "/usr/bin/python3"

  // --- what is playing -----------------------------------------------------

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var activePlayer: chooseActivePlayer()
  readonly property bool hasMedia: activePlayer !== null && title !== ""
  readonly property string title: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer ? String(activePlayer.trackAlbum || "") : ""
  readonly property string artUrl: activePlayer ? String(activePlayer.trackArtUrl || "") : ""
  readonly property bool playing: !!(activePlayer && activePlayer.isPlaying)
  readonly property string trackKey: hasMedia ? artist + " " + title : ""
  readonly property string nowPlaying: {
    if (!hasMedia) return ""
    return artist ? artist + " — " + title : title
  }

  function isProxy(player) {
    if (!player) return false
    var dbus = String(player.dbusName || "").toLowerCase()
    return dbus.indexOf("playerctld") !== -1
      || String(player.desktopEntry || "").toLowerCase() === "playerctld"
  }

  function isCandidate(player) {
    return !!(player && player.playbackState !== MprisPlaybackState.Stopped && player.trackTitle)
  }

  function chooseActivePlayer() {
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!isCandidate(player)) continue
      if (player.isPlaying && !isProxy(player)) return player
      if (!fallback) fallback = player
    }
    return fallback
  }

  // --- where the song is ---------------------------------------------------

  readonly property bool positionAvailable: !!(activePlayer && activePlayer.positionSupported)
  readonly property real trackLength: {
    if (!activePlayer || !activePlayer.lengthSupported) return 0
    return Number(activePlayer.length || 0)
  }
  readonly property real position: activePlayer ? Number(activePlayer.position || 0) : 0

  // Quickshell computes `position` on read but does not push updates, so the
  // change signal has to be raised for bindings to re-read it. Half a second is
  // enough for a lyric line and costs a property read.
  Timer {
    running: root.playing && root.positionAvailable
    interval: 500
    repeat: true
    onTriggered: root.activePlayer.positionChanged()
  }

  // --- lyrics --------------------------------------------------------------

  // idle | searching | ready | empty | error
  property string lookupState: "idle"
  property var record: null
  property string errorText: ""

  readonly property var syncedLines: record && record.synced ? Model.parseSynced(record.synced) : []
  readonly property var plainLines: record && record.plain ? Model.plainLines(record.plain) : []
  readonly property bool hasSynced: syncedLines.length > 0
  readonly property bool hasLyrics: hasSynced || plainLines.length > 0
  readonly property bool instrumental: !!(record && record.instrumental)
  readonly property int activeIndex: hasSynced ? Model.activeLine(syncedLines, position + offset) : -1
  readonly property string currentLine: {
    if (activeIndex < 0 || activeIndex >= syncedLines.length) return ""
    return String(syncedLines[activeIndex].text || "")
  }

  // A track change bumps the serial so results for the previous song are
  // dropped rather than flashing up against the wrong track.
  property int serial: 0
  property int getSerial: -1
  property int searchSerial: -1
  property bool bypassCache: false

  onTrackKeyChanged: {
    serial++
    record = null
    errorText = ""
    debounce.stop()
    if (!hasMedia) {
      lookupState = "idle"
      return
    }
    lookupState = "searching"
    debounce.restart()
  }

  // Skipping through a playlist should cost one lookup, not one per track.
  Timer {
    id: debounce
    interval: 700
    onTriggered: root.startLookup()
  }

  function startLookup() {
    if (!hasMedia) {
      lookupState = "idle"
      return
    }
    serial++
    errorText = ""
    lookupState = "searching"
    getSerial = serial
    getProc.running = false
    getProc.command = helperCommand([
      "get",
      "--artist", Model.cleanArtist(artist),
      "--title", Model.cleanTitle(title),
      "--album", album,
      "--duration", String(Math.round(trackLength))
    ])
    Qt.callLater(function () { getProc.running = true })
  }

  function refresh() {
    if (!hasMedia) return
    bypassCache = true
    startLookup()
  }

  function helperCommand(args) {
    var command = [python, helperPath]
    if (bypassCache) command.push("--no-cache")
    return command.concat(args)
  }

  function runSearch() {
    searchSerial = serial
    searchProc.running = false
    searchProc.command = helperCommand([
      "search",
      "--artist", Model.cleanArtist(artist),
      "--title", Model.cleanTitle(title)
    ])
    Qt.callLater(function () { searchProc.running = true })
  }

  function parsePayload(raw) {
    var text = String(raw || "").trim()
    if (!text) return null
    try {
      return JSON.parse(text)
    } catch (error) {
      return null
    }
  }

  function fail(message) {
    errorText = String(message || "Something went wrong")
    lookupState = "error"
  }

  function adopt(candidate) {
    bypassCache = false
    record = candidate
    // "Ready" has to mean there are words to show. LRCLIB also files tracks it
    // knows are instrumental, with no lines at all; treating those as ready
    // rendered an empty panel instead of saying so.
    lookupState = candidate && (candidate.synced || candidate.plain) ? "ready" : "empty"
  }

  function handleGet(raw) {
    if (getSerial !== serial) return
    var payload = parsePayload(raw)
    if (!payload) {
      fail("Could not run the lyrics fetcher. Is " + python + " present?")
      return
    }
    if (!payload.ok) {
      fail(payload.error)
      return
    }
    // An exact match is the best answer there is; otherwise widen to a search.
    if (payload.result) adopt(payload.result)
    else runSearch()
  }

  function handleSearch(raw) {
    if (searchSerial !== serial) return
    var payload = parsePayload(raw)
    if (!payload) {
      fail("Could not run the lyrics fetcher. Is " + python + " present?")
      return
    }
    if (!payload.ok) {
      fail(payload.error)
      return
    }
    var best = Model.pickCandidate(payload.results, artist, title, trackLength)
    if (best) adopt(best)
    else {
      bypassCache = false
      record = null
      lookupState = "empty"
    }
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleGet(text)
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSearch(text)
    }
  }

  // --- seeking -------------------------------------------------------------

  // Clicking a line jumps the player to it, which is the whole point of having
  // timestamps in the first place.
  function seekTo(seconds) {
    if (!activePlayer || !activePlayer.canSeek) return false
    activePlayer.position = Math.max(0, Number(seconds) - offset)
    return true
  }

  function statusObject() {
    return {
      playing: hasMedia,
      artist: artist,
      title: title,
      state: lookupState,
      panelOpen: panelOpen,
      synced: hasSynced,
      lines: hasSynced ? syncedLines.length : plainLines.length,
      position: Math.round(position * 10) / 10,
      length: Math.round(trackLength),
      activeIndex: activeIndex,
      instrumental: instrumental,
      error: errorText
    }
  }

  IpcHandler {
    target: "crmne.lyrics"

    function status(): string {
      return JSON.stringify(root.statusObject())
    }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function toggle(): string {
      root.toggleRequested()
      return "ok"
    }

    function show(): string {
      root.openRequested()
      return "ok"
    }

    function hide(): string {
      root.closeRequested()
      return "ok"
    }
  }
}
