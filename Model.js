// Pure helpers for the lyrics widget: turning MPRIS metadata into a usable
// query, choosing between LRCLIB candidates, parsing LRC timestamps, and
// working out which line the song is on.
//
// Kept free of QML types so `node --test tests/model.test.js` can exercise the
// parsing and matching rules directly.

// Junk MPRIS metadata carries that a lyrics database does not.
var BRACKETED_NOISE = /\s*[([][^)\]]*\b(remaster(ed)?|remix|live|acoustic|version|edit|mix|mono|stereo|deluxe|bonus|expanded|explicit|anniversary|feat\.?|featuring|with)\b[^)\]]*[)\]]/gi
var TRAILING_NOISE = /\s+-\s+.*\b(remaster(ed)?|radio edit|single version|album version|live|mono|stereo|re-?recorded|\d{4}\s+version)\b.*$/i
var FEATURING = /\s+[-(]?\s*\b(feat|ft|featuring)\b\.?\s+.*$/i

function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/['’`]/g, "")
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function cleanTitle(title) {
  var cleaned = String(title || "")
    .replace(BRACKETED_NOISE, "")
    .replace(TRAILING_NOISE, "")
    .replace(FEATURING, "")
    .trim()
  return cleaned || String(title || "").trim()
}

// Players report collaborations in ways a database does not file them, and
// LRCLIB itself sometimes stores "TOOL;Tool" for a single artist.
function cleanArtist(artist) {
  var cleaned = String(artist || "").replace(FEATURING, "").split(";")[0].trim()
  return cleaned || String(artist || "").trim()
}

function looseMatch(left, right) {
  var a = normalize(left)
  var b = normalize(right)
  if (!a || !b) return false
  return a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1
}

// LRCLIB holds several uploads of the same title -- different masters, live
// takes, whole different songs -- so the track length is the strongest signal
// available. A couple of seconds' drift is normal; a minute means it is not the
// recording being played.
function scoreCandidate(candidate, artist, title, duration) {
  if (!candidate) return -1
  if (!looseMatch(candidate.track, cleanTitle(title))) return -1
  var score = 0
  if (looseMatch(candidate.artist, cleanArtist(artist))) score += 1000
  if (duration > 0 && candidate.duration > 0) {
    var drift = Math.abs(Number(candidate.duration) - Number(duration))
    if (drift > 30) return -1
    score += (30 - drift) * 10
  }
  // Timestamps are the point of the plugin, so a synced upload wins a tie.
  if (candidate.synced) score += 200
  else if (candidate.plain) score += 50
  return score
}

function pickCandidate(results, artist, title, duration) {
  var best = null
  var bestScore = -1
  var list = results || []
  for (var i = 0; i < list.length; i++) {
    var score = scoreCandidate(list[i], artist, title, duration)
    if (score > bestScore) {
      best = list[i]
      bestScore = score
    }
  }
  return bestScore < 0 ? null : best
}

// --- LRC ------------------------------------------------------------------

// `[mm:ss.cc]` with optional hundredths, and a line may carry several stamps
// when the same words repeat. Metadata tags such as [ar:] or [length:] do not
// match the digits and are skipped.
var TIMESTAMP = /\[(\d+):(\d+)(?:[.:](\d+))?\]/g

function parseSynced(text) {
  var source = String(text || "").replace(/\r\n/g, "\n").split("\n")
  var lines = []
  for (var i = 0; i < source.length; i++) {
    var raw = source[i]
    var times = []
    var cursor = 0
    var match
    TIMESTAMP.lastIndex = 0
    while ((match = TIMESTAMP.exec(raw)) !== null) {
      // Only stamps at the head of the line count; anything later is lyrics.
      if (match.index !== cursor) break
      cursor = TIMESTAMP.lastIndex
      var fraction = match[3] ? Number("0." + match[3]) : 0
      times.push(Number(match[1]) * 60 + Number(match[2]) + fraction)
    }
    if (!times.length) continue
    var body = raw.slice(cursor).trim()
    for (var t = 0; t < times.length; t++) {
      lines.push({ time: times[t], text: body })
    }
  }
  lines.sort(function (a, b) { return a.time - b.time })
  return lines
}

function plainLines(text) {
  return String(text || "").replace(/\r\n/g, "\n").split("\n")
}

// Index of the line the song is on, or -1 before the first one starts. Binary
// search because this runs on a timer while the track plays.
function activeLine(lines, position) {
  var list = lines || []
  var at = Number(position) || 0
  var low = 0
  var high = list.length - 1
  var found = -1
  while (low <= high) {
    var mid = (low + high) >> 1
    if (list[mid].time <= at) {
      found = mid
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  return found
}

// How far through the track we are, 0 to 1. Plain lyrics carry no timestamps,
// so this is the only way to guess which part of the words is being sung.
function progressFraction(position, length) {
  var total = Number(length) || 0
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (Number(position) || 0) / total))
}

// Text handed to shell components this plugin does not own, such as the bar
// tooltip and dropdown labels. Those render with QML's default, which sniffs a
// string for markup, so remote text reaching them could still load a resource
// even though every Text in this plugin's own panel is pinned to PlainText.
// Angle brackets are what makes Qt treat a string as rich text, so they go.
function safeDisplayText(value) {
  return String(value === null || value === undefined ? "" : value).replace(/[<>]/g, "")
}

function formatTime(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var minutes = Math.floor(total / 60)
  var rest = total % 60
  return minutes + ":" + (rest < 10 ? "0" : "") + rest
}

if (typeof module !== "undefined") {
  module.exports = {
    normalize: normalize,
    cleanTitle: cleanTitle,
    cleanArtist: cleanArtist,
    looseMatch: looseMatch,
    scoreCandidate: scoreCandidate,
    pickCandidate: pickCandidate,
    parseSynced: parseSynced,
    plainLines: plainLines,
    activeLine: activeLine,
    progressFraction: progressFraction,
    safeDisplayText: safeDisplayText,
    formatTime: formatTime
  }
}
