const test = require("node:test")
const assert = require("node:assert/strict")
const Artwork = require("../Artwork.js")

// Album art goes through bin/artwork, which caps the download, before Qt's
// Image sees it. These cover what the shell side decides on its own.

test("only covers on disk and over https are worth asking about", () => {
  assert.equal(Artwork.allowedUrl("https://i.scdn.co/image/abc", false), "https://i.scdn.co/image/abc")
  assert.equal(Artwork.allowedUrl("file:///tmp/cover.png", false), "file:///tmp/cover.png")
  for (const url of ["http://example.com/a.png", "ftp://example.com/a.png",
    "data:image/png;base64,AAAA", "", null, "https://example.com/" + "a".repeat(Artwork.MAX_URL_CHARS)])
    assert.equal(Artwork.allowedUrl(url, false), "", String(url))
})

test("the cover URL travels in the environment, never on the command line", () => {
  const url = "https://example.com/cover.png?track=secret"
  const run = Artwork.invocation({ python: "/usr/bin/python3", helper: "/plugin/bin/artwork", url, request: 4 })
  assert.equal(run.environment[Artwork.ENV], url)
  assert.equal(run.environment[Artwork.REQUEST_ENV], "4")
  assert.ok(run.command.every(part => !part.includes("secret")))
  assert.deepEqual(run.command.slice(3), ["artwork", "/usr/bin/python3", "/plugin/bin/artwork"])
  // One deadline for the run, and the output cut off just past the limit.
  assert.match(run.command[2], /^\/usr\/bin\/timeout -k 2 \d+ /)
  assert.ok(run.command[2].includes("/usr/bin/head -c " + (Artwork.MAX_OUTPUT_BYTES + 1)))
})

test("only a local file answering the current request is loaded", () => {
  const ok = JSON.stringify({ ok: true, request: "4", source: "file:///home/me/.cache/x" })
  assert.equal(Artwork.sourceFromOutput(ok, 4), "file:///home/me/.cache/x")
  assert.equal(Artwork.requestOf(ok), "4")
  // An answer for the previous track.
  assert.equal(Artwork.sourceFromOutput(ok, 5), "")
  // Never anything that would reach the network.
  assert.equal(Artwork.sourceFromOutput(JSON.stringify({ ok: true, request: "4", source: "https://example.com/a.png" }), 4), "")
  assert.equal(Artwork.sourceFromOutput(JSON.stringify({ ok: false, request: "4", code: "too_large" }), 4), "")
  assert.equal(Artwork.sourceFromOutput("", 4), "")
  assert.equal(Artwork.sourceFromOutput("not json", 4), "")
  assert.equal(Artwork.sourceFromOutput(ok + " ".repeat(Artwork.MAX_OUTPUT_BYTES), 4), "")
})
