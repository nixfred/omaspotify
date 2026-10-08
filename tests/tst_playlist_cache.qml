import QtQuick
import QtTest
import ".." as Plugin

TestCase {
  id: test
  name: "PlaylistLibraryCache"
  property double clock: 10000
  property var requests: []

  Component {
    id: component
    Plugin.PlaylistCache {
      owner: "account-a"
      identity: "app-a"
      diskReady: true
      warmingEnabled: true
      idle: true
      now: function() { return test.clock }
      request: function(path, query, callback) {
        var job = { path: path, query: query, callback: callback, aborted: false }
        test.requests.push(job)
        return job
      }
      abort: function(job) { job.aborted = true }
    }
  }
  function init() { clock = 10000; requests = [] }
  function cache(list) {
    return createTemporaryObject(component, test, { playlists: list || [playlist("a")] })
  }
  function playlist(id, version) { return { id: id, type: "playlist", snapshotId: version || "v1" } }
  function track(id) { return { id: id, name: id, uri: "spotify:track:" + id, artists: [] } }
  function snapshot(id, count, next, version) {
    var rows = []
    for (var i = 0; i < count; i++) { var row = track("same"); row.playlistPosition = i; rows.push(row) }
    return { item: playlist(id, version), items: rows, next: next || "" }
  }
  function step(c) { clock += c.spacingMs; c.tick(); return requests[requests.length - 1] }
  function answer(payload, status, error) {
    requests[requests.length - 1].callback(status || 200, payload, error || "")
  }
  function start(c) { c.tick(); answer({ snapshot_id: "v1" }); step(c) }
  function finish(c) {
    start(c)
    answer({ items: [{ track: track("one") }], offset: 0, next: null })
    step(c); answer({ snapshot_id: "v1" })
  }

  function test_firstPagesBeforeDeepPages() {
    var c = cache([playlist("a"), playlist("b")])
    start(c)
    answer({ items: [{ track: track("one") }], next: "/playlists/a/items?offset=1" })
    compare(c.read("a").items.length, 1)
    compare(step(c).path, "/playlists/b")
    answer({ snapshot_id: "v1" })
    compare(step(c).path, "/playlists/b/items")
  }
  function test_completePlaylistNeedsNoTrackRequestsOnReopen() {
    var c = cache(); finish(c)
    compare(c.read("a").items[0].id, "one")
    compare(c.freshness("a"), "fresh")
    var count = requests.length
    step(c)
    compare(requests.length, count)
  }
  function test_staleUnchangedVersionSkipsTracks() {
    var c = cache(); finish(c); clock += c.recheckMs + 1
    compare(step(c).path, "/playlists/a")
    answer({ snapshot_id: "v1" })
    compare(c.freshness("a"), "fresh")
    var count = requests.length; step(c); compare(requests.length, count)
  }
  function test_changedVersionStartsFromFirstPageAndReplacesRows() {
    var c = cache(); c.keep(snapshot("a", 2)); c.playlists = [playlist("a", "v2")]
    c.tick(); answer({ snapshot_id: "v2" })
    compare(step(c).path, "/playlists/a/items")
    compare(c.read("a").items.length, 2, "old rows remain until a replacement arrives")
    answer({ items: [{ track: track("new") }], next: null })
    compare(c.read("a").items[0].id, "new")
    compare(c.read("a").item.snapshotId, "v2")
  }
  function test_restartResumesCheckedCursor() {
    var c = cache(); c.keep(snapshot("a", 2, "/playlists/a/items?offset=2"))
    var raw = c.serialize()
    var restored = cache(); restored.diskRaw = raw; restored.restore()
    compare(restored.read("a").items.length, 2)
    restored.tick(); answer({ snapshot_id: "v1" })
    compare(step(restored).path, "/playlists/a/items?offset=2")
  }
  function test_partialChangedAfterRestartDoesNotAppendOldRows() {
    var c = cache(); c.keep(snapshot("a", 2, "/playlists/a/items?offset=2"))
    c.tick(); answer({ snapshot_id: "v2" })
    compare(step(c).path, "/playlists/a/items")
    answer({ items: [{ track: track("new") }], next: null })
    compare(c.read("a").items.length, 1)
  }
  function test_knownLibraryChangeInvalidatesInSessionContinuation() {
    var c = cache(); start(c)
    answer({ items: [{ track: track("old") }], next: "/playlists/a/items?offset=1" })
    c.playlists = [playlist("a", "v2")]
    compare(step(c).path, "/playlists/a", "changed library version must be checked before appending")
    answer({ snapshot_id: "v2" })
    compare(step(c).path, "/playlists/a/items")
  }
  function test_pauseAbortsAndIgnoresLateResponses() {
    var c = cache(); c.tick(); var job = requests[0]
    c.idle = false
    verify(job.aborted)
    job.callback(200, { snapshot_id: "v1" }, "")
    compare(c.work, null); compare(c.handle, null)
    var count = requests.length; step(c); compare(requests.length, count)
    c.idle = true; compare(step(c).path, "/playlists/a")
  }
  function test_disableAndIdentityChangeCancelOldWork() {
    var c = cache(); c.tick(); c.warmingEnabled = false; verify(requests[0].aborted)
    c.warmingEnabled = true; step(c); var job = requests[1]
    c.identity = "app-b"; verify(job.aborted)
    job.callback(200, { snapshot_id: "v1" }, ""); compare(c.work, null)
  }
  function test_accountScopeAndLogoutForgetRows() {
    var c = cache(); c.keep(snapshot("a", 2)); var raw = c.serialize()
    c.owner = "account-b"; compare(c.read("a"), null)
    c.diskRaw = raw; c.restore(); compare(c.read("a"), null)
    c.owner = "account-a"; compare(c.read("a").items.length, 2)
    c.clear(); compare(c.read("a"), null); compare(c.diskRaw, "")
  }
  function test_longerWarmCopySurvivesShortForegroundPage() {
    var c = cache(); c.keep(snapshot("a", 300)); c.keep(snapshot("a", 50))
    compare(c.read("a").items.length, 300)
  }
  function test_successfulEmptyPlaylistIsRemembered() {
    var c = cache(); start(c); answer({ items: [], next: null })
    step(c); answer({ snapshot_id: "v1" })
    verify(c.read("a")); compare(c.read("a").items.length, 0)
    var count = requests.length; step(c); compare(requests.length, count)
  }
  function test_duplicatesAndUnavailablePositionsRemainCorrect() {
    var c = cache(); start(c)
    answer({ items: [{ track: track("same") }, { track: null }, { track: track("same") }], offset: 7, next: "/playlists/a/items?offset=10" })
    var rows = c.read("a").items
    compare(rows.length, 3); compare(rows[0].id, rows[2].id)
    compare(rows[1].uri, "", "unavailable row retains its original position")
    compare(rows[0].playlistPosition, 7); compare(rows[2].playlistPosition, 9)
  }
  function test_rateLimitStopsWholeWarmerAndPreservesRows() {
    var c = cache(); c.keep(snapshot("a", 2)); clock += c.recheckMs + 1
    c.tick(); answer(null, 429, "rate limited")
    compare(c.read("a").items.length, 2)
    verify(c.suspendedUntil > clock)
    var count = requests.length; step(c); compare(requests.length, count)
  }
  function test_forbiddenPlaylistDoesNotBlockOthers() {
    var c = cache([playlist("a"), playlist("b")]); c.tick(); answer(null, 403, "forbidden")
    compare(step(c).path, "/playlists/b")
    verify(c.retryAt.a >= clock + 3500000)
  }
  function test_oneRequestAtATimeAndSpacing() {
    var c = cache(); c.tick(); c.tick(); compare(requests.length, 1)
    answer({ snapshot_id: "v1" }); c.tick(); compare(requests.length, 1)
    step(c); compare(requests.length, 2)
  }
  function test_editDropsRowsAndLateReadCannotRepopulate() {
    var c = cache(); c.keep(snapshot("a", 2)); clock += c.recheckMs + 1
    c.tick(); var job = requests[0]; c.drop("a"); verify(job.aborted)
    job.callback(200, { snapshot_id: "v1" }, ""); compare(c.read("a"), null)
  }
  function test_versionChangingDuringDownloadDiscardsMixedCopy() {
    var c = cache(); start(c); answer({ items: [{ track: track("one") }], next: null })
    compare(c.freshness("a"), "stale")
    step(c); answer({ snapshot_id: "v2" }); compare(c.read("a"), null)
  }
  function test_budgetStopsWithoutEvicting() {
    var c = cache(); c.maxRows = 3; verify(c.keep(snapshot("a", 3)))
    verify(!c.keep(snapshot("b", 1))); verify(c.budgetFull)
    compare(c.read("a").items.length, 3); c.tick(); compare(requests.length, 0)
    c.drop("a"); verify(!c.budgetFull); verify(c.keep(snapshot("b", 1)))
  }
  function test_entryAndByteBudgets() {
    var c = cache(); c.maxEntries = 1; c.keep(snapshot("a", 1)); verify(!c.keep(snapshot("b", 1)))
    c.clear(); c.maxBytes = 10; verify(!c.keep(snapshot("a", 1)))
  }
  function test_perPlaylistCapPreservesSafeCursor() {
    var c = cache(); c.itemLimit = 2; c.keep(snapshot("a", 5))
    compare(c.read("a").items.length, 2)
    verify(c.read("a").next.indexOf("offset=2") >= 0)
  }
  function test_corruptExpiredAndForeignFilesAreIgnored() {
    var c = cache(); c.diskRaw = "broken"; c.restore(); compare(c.cachedCount, 0)
    c.keep(snapshot("a", 1)); var raw = c.serialize(); clock += c.maxAgeMs + 1
    c.diskRaw = raw; c.restore(); compare(c.read("a"), null)
  }
  function test_missingItemsResponseCannotEraseCache() {
    var c = cache(); c.keep(snapshot("a", 2, "/playlists/a/items?offset=2"))
    c.tick(); answer({ snapshot_id: "v1" }); step(c); answer({})
    compare(c.read("a").items.length, 2); verify(c.retryAt.a > clock)
  }
}
