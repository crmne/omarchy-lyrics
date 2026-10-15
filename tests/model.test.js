const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")
const fs = require("node:fs")
const path = require("node:path")

// Placeholder text throughout; the parsing rules care about timestamps and
// structure, not about what the words are.
const LRC = [
  "[ar:Some Artist]",
  "[ti:Some Song]",
  "[length:03:21]",
  "[00:12.50]first line",
  "[00:15.00]",
  "[00:18.25]second line",
  "[01:05.00][02:10.00]repeated line",
  "[03:00]no fraction",
].join("\n")

test("LRC timestamps parse into ordered lines and metadata tags are dropped", () => {
  const lines = Model.parseSynced(LRC)
  assert.deepEqual(lines.map(l => l.time), [12.5, 15, 18.25, 65, 130, 180])
  assert.deepEqual(lines.map(l => l.text), [
    "first line", "", "second line", "repeated line", "repeated line", "no fraction"
  ])
})

test("a line repeated at several timestamps appears at each of them", () => {
  const lines = Model.parseSynced("[01:05.00][02:10.00]repeated line")
  assert.equal(lines.length, 2)
  assert.deepEqual(lines.map(l => l.time), [65, 130])
  assert.equal(lines[0].text, lines[1].text)
})

test("an instrumental gap keeps its timestamp with empty text", () => {
  const lines = Model.parseSynced("[00:15.00]")
  assert.deepEqual(lines, [{ time: 15, text: "" }])
})

test("something that looks like a timestamp mid-line is left in the text", () => {
  const lines = Model.parseSynced("[00:12.50]meet me at [00:30.00] sharp")
  assert.equal(lines.length, 1)
  assert.equal(lines[0].text, "meet me at [00:30.00] sharp")
})

test("lyrics with no timestamps at all parse to nothing", () => {
  assert.deepEqual(Model.parseSynced("just words\nmore words"), [])
  assert.deepEqual(Model.parseSynced(""), [])
  assert.deepEqual(Model.parseSynced(null), [])
})

test("the active line follows the clock and is -1 before the first one", () => {
  const lines = Model.parseSynced(LRC)
  assert.equal(Model.activeLine(lines, 0), -1, "before the singing starts")
  assert.equal(Model.activeLine(lines, 12.4), -1)
  assert.equal(Model.activeLine(lines, 12.5), 0, "exactly on the boundary")
  assert.equal(Model.activeLine(lines, 17), 1)
  assert.equal(Model.activeLine(lines, 18.25), 2)
  assert.equal(Model.activeLine(lines, 9999), lines.length - 1, "after the last line")
  assert.equal(Model.activeLine([], 42), -1)
  assert.equal(Model.activeLine(null, 42), -1)
})

test("track length decides between uploads sharing a title", () => {
  // LRCLIB really does return these for one search: same title, different
  // recordings, only one of which is playing.
  const results = [
    { artist: "Tool", track: "Sober", duration: 571, synced: "x", plain: "" },
    { artist: "Tool", track: "Sober", duration: 307, synced: "x", plain: "" },
    { artist: "Tool", track: "Sober", duration: 273, synced: "x", plain: "" },
  ]
  assert.equal(Model.pickCandidate(results, "Tool", "Sober", 306).duration, 307)
  assert.equal(Model.pickCandidate(results, "Tool", "Sober", 275).duration, 273)
})

test("a recording of a very different length is refused rather than shown", () => {
  const results = [{ artist: "Tool", track: "Sober", duration: 571, synced: "x", plain: "" }]
  assert.equal(Model.pickCandidate(results, "Tool", "Sober", 306), null)
  // With no duration to compare, it is better to show something.
  assert.ok(Model.pickCandidate(results, "Tool", "Sober", 0))
})

test("synced lyrics win a tie against plain ones", () => {
  const plain = { artist: "A", track: "T", duration: 200, synced: "", plain: "words" }
  const synced = { artist: "A", track: "T", duration: 200, synced: "[00:01.00]words", plain: "words" }
  assert.equal(Model.pickCandidate([plain, synced], "A", "T", 200), synced)
})

test("the wrong song is never shown just because the artist matches", () => {
  const other = { artist: "Tool", track: "A Different Song", duration: 306, synced: "x", plain: "" }
  assert.equal(Model.pickCandidate([other], "Tool", "Sober", 306), null)
  assert.equal(Model.pickCandidate([], "Tool", "Sober", 306), null)
  assert.equal(Model.pickCandidate(null, "Tool", "Sober", 306), null)
})

test("artist and title are tidied the way the databases file them", () => {
  // LRCLIB stores some artists with a semicolon-joined alias.
  assert.equal(Model.cleanArtist("TOOL;Tool"), "TOOL")
  assert.equal(Model.cleanArtist("Band feat. Guest"), "Band")
  assert.equal(Model.cleanTitle("Song - 2011 Remaster"), "Song")
  assert.equal(Model.cleanTitle("Song (feat. Someone)"), "Song")
  assert.ok(Model.looseMatch("Forty Six & 2", "Forty Six And 2"))
  assert.ok(Model.looseMatch("Café", "Cafe"))
})

test("progress through the track is a fraction, clamped at both ends", () => {
  assert.equal(Model.progressFraction(0, 200), 0)
  assert.equal(Model.progressFraction(100, 200), 0.5)
  assert.equal(Model.progressFraction(200, 200), 1)
  // Players report a position past the end for a moment when a track ends.
  assert.equal(Model.progressFraction(250, 200), 1)
  assert.equal(Model.progressFraction(-5, 200), 0)
  // Nothing to divide by yet.
  assert.equal(Model.progressFraction(30, 0), 0)
})

test("durations read as times", () => {
  assert.equal(Model.formatTime(536), "8:56")
  assert.equal(Model.formatTime(9), "0:09")
  assert.equal(Model.formatTime(0), "0:00")
})

test("text handed to shell-drawn components cannot look like markup", () => {
  // The bar tooltip and the dropdown labels are rendered by the shell, whose
  // Text elements use QML's markup-sniffing default. Angle brackets are what
  // makes Qt switch a string to rich text, so they must not survive.
  assert.equal(Model.safeDisplayText('<img src="https://evil.example/x">'),
    'img src="https://evil.example/x"')
  assert.equal(Model.safeDisplayText("<b>bold</b>"), "bbold/b")
  assert.ok(!Model.safeDisplayText("a <tag> b").includes("<"))
  assert.ok(!Model.safeDisplayText("a <tag> b").includes(">"))

  // Ordinary text, including newlines the tooltip relies on, is left alone.
  assert.equal(Model.safeDisplayText("Artist \u2014 Song\nSecond line"),
    "Artist \u2014 Song\nSecond line")
  assert.equal(Model.safeDisplayText("Me & You"), "Me & You")
  assert.equal(Model.safeDisplayText(""), "")
  assert.equal(Model.safeDisplayText(null), "")
  assert.equal(Model.safeDisplayText(undefined), "")
})

test("joiners that carry meaning survive normalisation", () => {
  // A zero-width joiner holds an emoji sequence together, and a non-joiner
  // separates letters in Persian and Indic scripts. Stripping either changes
  // the title rather than tidying it.
  const family = "\u{1F468}\u200d\u{1F469}\u200d\u{1F467} Song"
  assert.equal(Model.cleanTitle(family), family)
  const persian = "\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645"
  assert.equal(Model.cleanTitle(persian), persian)
  assert.equal(Model.cleanArtist(persian), persian)
})

test("invisible characters a player prefixes onto a title are dropped", () => {
  // Browsers reporting a video prefix an invisible separator, which matches
  // nothing in a lyrics database and only pollutes the query.
  assert.equal(Model.cleanTitle("\u2063Some Video Title"), "Some Video Title")
  assert.equal(Model.cleanTitle("\u200bSong\ufeff"), "Song")
  assert.equal(Model.cleanTitle("\u2060Song\u2062"), "Song")
  assert.equal(Model.cleanArtist("\u2063Band"), "Band")
  // Ordinary titles are untouched.
  assert.equal(Model.cleanTitle("Song"), "Song")
})

test("helper output past the collection cap is refused rather than parsed", () => {
  const payload = Model.parseHelperOutput("x".repeat(101), 100)
  assert.equal(payload.ok, false)
  assert.match(payload.error, /more than any lyrics need/)
})

test("helper output is parsed, with search results trimmed to the few worth ranking", () => {
  const results = Array.from({ length: 50 }, (_, id) => ({ id }))
  const payload = Model.parseHelperOutput(JSON.stringify({ ok: true, results }) + "\n", 1 << 20)
  assert.equal(payload.ok, true)
  assert.equal(payload.results.length, 20)
  assert.equal(Model.parseHelperOutput("", 100), null)
  assert.equal(Model.parseHelperOutput("not json", 100), null)
  assert.equal(Model.parseHelperOutput("42", 100), null)
})

test("the track playing never reaches the helper's command line", () => {
  // Arguments are readable by every user on the machine; the environment only
  // by its owner. Invented names, so a match can only mean a leak.
  const track = { artist: "Invented Artist", title: "Made Up Song", album: "Imaginary Album", duration: 241.4 }
  const options = { python: "/usr/bin/python3", helperPath: "/x/bin/lrclib", maxOutputBytes: 100 }
  for (const kind of ["get", "search"]) {
    const request = Model.helperRequest(kind, track, options)
    const argv = request.command.join("\0")
    for (const value of ["Invented", "Made Up", "Imaginary", "241"])
      assert.ok(!argv.includes(value), kind + " argv carries " + value)
    assert.equal(request.command.at(-1), kind)
    assert.equal(request.environment.LRCLIB_ARTIST, "Invented Artist")
    assert.equal(request.environment.LRCLIB_TITLE, "Made Up Song")
  }
  const get = Model.helperRequest("get", track, options)
  assert.equal(get.environment.LRCLIB_ALBUM, "Imaginary Album")
  assert.equal(get.environment.LRCLIB_DURATION, "241")
  assert.ok(Model.helperRequest("get", track, { ...options, bypassCache: true }).command.includes("--no-cache"))
})

test("the helper runs under a deadline and an output cap, with fixed shell text", () => {
  const request = Model.helperRequest("get", { artist: "$(touch x)", title: "`id`" },
    { python: "/usr/bin/python3", helperPath: "/x/bin/lrclib", maxOutputBytes: 100 })
  assert.deepEqual(request.command.slice(0, 3), ["/usr/bin/sh", "-c",
    "/usr/bin/timeout -k 2 " + Model.HELPER_KILL_SECONDS + " \"$@\" | /usr/bin/head -c 101"])
  assert.ok(Model.HELPER_KILL_SECONDS > Model.HELPER_DEADLINE_SECONDS)
  assert.equal(request.environment.LRCLIB_DEADLINE, String(Model.HELPER_DEADLINE_SECONDS))
  assert.equal(request.environment.LRCLIB_ARTIST, "$(touch x)")
})

test("the service builds every helper command through helperRequest", () => {
  const service = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
  assert.ok(!/--(artist|title|album|duration)/.test(service))
  assert.ok(!/\.command\s*=\s*\[/.test(service), "a hand-built command bypasses helperRequest")
  assert.equal((service.match(/\.environment = request\.environment/g) || []).length, 2)
})

test("no QML in the plugin uses an editable Qt text input", () => {
  // Every editable Qt text input reads the clipboard on each change, even
  // while hidden, so the plugin has none.
  const root = path.join(__dirname, "..")
  const files = fs.readdirSync(root, { recursive: true })
    .filter(f => f.endsWith(".qml") && !f.split(path.sep).includes("node_modules"))
  assert.ok(files.length >= 3)
  for (const file of files) {
    const source = fs.readFileSync(path.join(root, file), "utf8")
    assert.ok(!/\b(TextInput|TextField|TextEdit|TextArea|NumberField|SpinBox)\s*\{/.test(source), file)
  }
})
