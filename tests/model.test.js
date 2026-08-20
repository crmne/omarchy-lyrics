const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

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

test("durations read as times, and the source line says what was found", () => {
  assert.equal(Model.formatTime(536), "8:56")
  assert.equal(Model.formatTime(9), "0:09")
  assert.equal(Model.formatTime(0), "0:00")
  assert.equal(Model.sourceLine({ synced: "x", plain: "y", duration: 536 }), "lrclib.net · synced · 8:56")
  assert.equal(Model.sourceLine({ synced: "", plain: "y", duration: 200 }), "lrclib.net · plain · 3:20")
  assert.equal(Model.sourceLine(null), "")
})
