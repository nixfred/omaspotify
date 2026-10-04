import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Api.js" as Api

ShellRoot {
  id: test
  Plugin.Service { id: service }
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
      var names = ["unchanged", "changed", "unknown", "failed"]
      var cache = { version: Api.QUERY_CACHE_VERSION, order: [], entries: {} }
      var entries = []
      for (var i = 0; i < names.length; i++) {
        var key = Api.queryCacheKey(["playlist", names[i]])
        cache.order.push(key)
        cache.entries[key] = { updatedAt: Date.now() - 600000, data: {
          item: { id: names[i], snapshotId: "v1" },
          items: [{ id: "old-" + names[i], uri: "spotify:track:old-" + names[i] }], next: "" } }
        entries.push({ id: names[i], name: names[i], uri: "spotify:playlist:" + names[i],
          snapshotId: "v1" })
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
      service.api.cancelAll()
      console.log("PLAYLIST_VERSIONS_PASS")
      Qt.quit()
    }
  }
}
