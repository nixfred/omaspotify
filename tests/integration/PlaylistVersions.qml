import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Api.js" as Api

ShellRoot {
  id: test
  Plugin.Service { id: service }
  Plugin.Panel { id: panel; service: service; width: 1280; height: 800 }
  property var requests: []
  function complete(xhr, status, payload) {
    xhr.status = status
    xhr.responseText = JSON.stringify(payload)
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }
  function expect(value, message) { if (!value) throw new Error(message) }
  // Reopen the way the sidebar does, with the library's own copy.
  function library(id) {
    for (var i = 0; i < service.playlists.length; i++)
      if (service.playlists[i].id === id) return service.playlists[i]
    return null
  }
  function pump() {
    service.api.lastBackgroundStartedAt = 0
    service.api.lastInteractiveStartedAt = 0
    service.api.pumpRequests()
  }
  function last() { return requests[requests.length - 1] }
  function rows(id) {
    return { items: [{ track: { id: id, name: id, uri: "spotify:track:" + id,
      artists: [] } }], next: null }
  }
  function page(id, offset, count, next) {
    var items = []
    for (var i = 0; i < count; i++)
      items.push({ track: { id: id, name: id, uri: "spotify:track:" + id, artists: [] } })
    return { items: items, offset: offset, next: next || null }
  }
  function keptRows(id, count) {
    var items = []
    for (var i = 0; i < count; i++)
      items.push({ id: id, uri: "spotify:track:" + id, playlistPosition: i })
    return items
  }
  function requestsFor(id) {
    return requests.filter(function(xhr) { return xhr.url.indexOf("/playlists/" + id) >= 0 })
  }
  Timer {
    interval: 20
    running: true
    onTriggered: {
      stop()
      service.api.cancelAll()
      service.api.auth = { loggedIn: true,
        withAccessToken: function(callback) { callback("test-token", "") },
        invalidateAccessToken: function() {} }
      service.api.fallbackAuth = null
      service.api.xhrFactory = function() {
        var xhr = { readyState: 0, status: 0, responseText: "", url: "", aborted: false,
          onreadystatechange: null,
          open: function(method, url) { this.url = url },
          send: function() {}, setRequestHeader: function() {},
          abort: function() { this.aborted = true },
          getResponseHeader: function() { return "30" } }
        test.requests.push(xhr)
        return xhr
      }
      var names = ["unchanged", "changed", "unknown", "failed", "deep", "large"]
      var cache = { version: Api.QUERY_CACHE_VERSION, order: [], entries: {} }
      var entries = []
      for (var i = 0; i < names.length; i++) {
        var key = Api.queryCacheKey(["playlist", names[i]])
        cache.order.push(key)
        var data = {
          item: { type: "playlist", id: names[i], snapshotId: "v1" },
          items: [{ id: "old-" + names[i], uri: "spotify:track:old-" + names[i] }], next: "" }
        if (names[i] === "deep") {
          data.items = keptRows("old-deep", 100)
          data.next = "https://api.spotify.com/v1/playlists/deep/items?offset=100&limit=50"
        } else if (names[i] === "large") {
          // What a capped playlist page leaves on disk.
          data = Api.cappedPageSnapshot({ item: data.item,
            items: keptRows("repeat", 250), next: "" }, 200)
        }
        cache.entries[key] = { updatedAt: Date.now() - 600000, data: data }
        entries.push({ type: "playlist", id: names[i], name: names[i],
          uri: "spotify:playlist:" + names[i], snapshotId: "v1" })
      }
      service.playlists = entries
      service.queryCacheReady = false
      service.applyQueryCacheFile(JSON.stringify(cache))

      // Unchanged: one metadata check, no track download, then fresh.
      service.openPlaylist(library("unchanged"))
      expect(service.playlistItems[0].id === "old-unchanged", "Cache was not drawn immediately")
      expect(!service.playlistItemsLoading, "Version check blocked cached rows")
      expect(requests.length === 1 && requests[0].url.indexOf("fields=snapshot_id") >= 0,
        "Stale cache did not use the metadata endpoint")
      complete(requests[0], 200, { snapshot_id: "v1" })
      service.openPlaylist(library("unchanged"))
      pump()
      expect(requests.length === 1, "Unchanged version downloaded tracks again")

      // Changed: the new version reaches the library copy, so the sidebar
      // reopen trusts the rows it just fetched.
      service.openPlaylist(library("changed"))
      pump()
      expect(requests.length === 2 && last().url.indexOf("fields=snapshot_id") >= 0,
        "Changed playlist was not checked")
      complete(last(), 200, { snapshot_id: "v2" })
      pump()
      expect(requests.length === 3 && last().url.indexOf("/items") >= 0,
        "A changed version kept the old rows")
      complete(last(), 200, rows("new-changed"))
      expect(service.playlistItems[0].id === "new-changed", "Changed rows were not replaced")
      expect(library("changed").snapshotId === "v2", "The library kept the old version")
      expect(library("unchanged").snapshotId === "v1", "Another playlist's version changed")
      service.keepPlaylistPage()
      service.openPlaylist(library("changed"))
      pump()
      expect(requests.length === 3, "Reopening from the sidebar downloaded tracks again")
      expect(service.playlistItems[0].id === "new-changed", "Reopening lost the new rows")

      // A known newer library version bypasses even a fresh cache.
      service.playlists = service.playlists.map(function(item) {
        if (item.id !== "unchanged") return item
        var copy = Object.assign({}, item)
        copy.snapshotId = "v3"
        return copy
      })
      service.openPlaylist(library("unchanged"))
      pump()
      expect(requests.length === 4 && last().url.indexOf("/items") >= 0,
        "A known changed version was treated as fresh")
      complete(last(), 200, rows("new-unchanged"))

      // Unknown: no version in the reply means the rows are fetched.
      service.openPlaylist(library("unknown"))
      pump()
      complete(last(), 200, {})
      pump()
      expect(requests.length === 6 && last().url.indexOf("/items") >= 0,
        "An unknown version was trusted")
      complete(last(), 200, rows("new-unknown"))
      expect(service.playlistItems[0].id === "new-unknown", "Unknown version rows were not replaced")
      expect(library("unknown").snapshotId === "v1", "An unknown version was written to the library")

      // Failed: the visible cache stays and is checked again next visit.
      service.openPlaylist(library("failed"))
      pump()
      complete(last(), 500, { error: { status: 500, message: "Server error" } })
      pump()
      expect(requests.length === 7, "A failed check downloaded tracks")
      expect(service.playlistItems[0].id === "old-failed", "A failed check dropped cached rows")
      expect(!service.playlistItemsLoading, "A failed check left Loading on")
      service.openPlaylist(library("failed"))
      pump()
      expect(requests.length === 8 && last().url.indexOf("fields=snapshot_id") >= 0,
        "A failed check was treated as fresh")

      // Changed while the panel restores a deeper position: the new version
      // is fetched from the top, not appended onto the old rows.
      panel.currentTab = "playlists"
      panel.restoredPlaylistId = "deep"
      panel.restoredPlaylistItemCount = 150
      service.openPlaylist(library("deep"), 150)
      pump()
      var deep = requestsFor("deep")
      expect(deep.length === 1 && deep[0].url.indexOf("fields=snapshot_id") >= 0,
        "Deep playlist was not checked")
      complete(deep[0], 200, { snapshot_id: "v2" })
      pump()
      deep = requestsFor("deep")
      expect(deep.length === 2 && deep[1].url.indexOf("offset=100") < 0
        && deep[1].url.indexOf("/items") >= 0, "The restore paged on from stale rows")
      expect(library("deep").snapshotId === "v2", "The deep library entry kept the old version")
      complete(deep[1], 200, page("new-deep", 0, 50,
        "https://api.spotify.com/v1/playlists/deep/items?offset=50&limit=50"))
      pump()
      complete(requestsFor("deep")[2], 200, page("new-deep", 50, 50,
        "https://api.spotify.com/v1/playlists/deep/items?offset=100&limit=50"))
      pump()
      deep = requestsFor("deep")
      expect(deep.length === 4 && deep[3].url.indexOf("offset=100") >= 0,
        "The remembered depth was not restored")
      complete(deep[3], 200, page("new-deep", 100, 50))
      expect(service.playlistItems.length === 150, "The remembered depth was lost")
      expect(service.playlistItems.every(function(row) { return row.id === "new-deep" }),
        "Old and new versions were mixed")
      panel.restoredPlaylistId = ""
      panel.currentTab = "home"

      // Capped: a kept 200-row page still pages on from its last position.
      service.openPlaylist(library("large"))
      pump()
      var large = requestsFor("large")
      complete(large[0], 200, { snapshot_id: "v1" })
      expect(requestsFor("large").length === 1, "An unchanged capped playlist downloaded tracks")
      expect(service.playlistItems.length === 200, "The capped rows were not drawn")
      expect(service.playlistItemsNext.indexOf("offset=200") >= 0,
        "An unchanged capped playlist lost Load More")
      service.loadMorePlaylistItems()
      large = requestsFor("large")
      expect(large.length === 2 && large[1].url.indexOf("offset=200") >= 0,
        "Load More did not resume after the kept rows")
      complete(large[1], 200, page("repeat", 200, 50))
      expect(service.playlistItems.length === 250
        && service.playlistItems[249].playlistPosition === 249,
        "Load More misplaced the remaining rows")
      service.openPlaylist(library("large"), 250)
      pump()
      large = requestsFor("large")
      expect(large.length === 3 && large[2].url.indexOf("offset=200") >= 0,
        "A deeper remembered position was not restored from the capped cache")
      complete(large[2], 200, page("repeat", 200, 50))
      expect(service.playlistItems.length === 250, "The deeper position was not reached")

      service.api.cancelAll()
      console.log("PLAYLIST_VERSIONS_PASS")
      Qt.quit()
    }
  }
}
