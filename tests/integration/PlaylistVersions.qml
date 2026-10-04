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
      var key = Api.queryCacheKey(["playlist", "versioned"])
      var cache = { version: Api.QUERY_CACHE_VERSION, order: [key], entries: {} }
      cache.entries[key] = { updatedAt: Date.now() - 600000, data: {
        item: { id: "versioned", snapshotId: "v1" },
        items: [{ id: "old-row", uri: "spotify:track:old-row" }], next: "" } }
      service.queryCacheReady = false
      service.applyQueryCacheFile(JSON.stringify(cache))
      service.openPlaylist({ id: "versioned", snapshotId: "v1" })
      expect(service.playlistItems[0].id === "old-row", "Cache was not drawn immediately")
      expect(!service.playlistItemsLoading, "Version check blocked cached rows")
      expect(requests.length === 1 && requests[0].url.indexOf("fields=snapshot_id") >= 0,
        "Stale cache did not use the metadata endpoint")
      complete(requests[0], 200, { snapshot_id: "v1" })
      service.openPlaylist({ id: "versioned", snapshotId: "v1" })
      expect(requests.length === 1, "Unchanged version downloaded tracks again")
      service.openPlaylist({ id: "versioned", snapshotId: "v2" })
      // A known new version invalidates even a recently checked cache.
      service.api.lastBackgroundStartedAt = 0
      service.api.pumpRequests()
      expect(requests.length === 2 && requests[1].url.indexOf("/items") >= 0,
        "A changed version was treated as fresh")
      complete(requests[1], 200, { items: [{ track: { id: "new-row", name: "New",
        uri: "spotify:track:new-row", artists: [] } }], next: null })
      expect(service.playlistItems[0].id === "new-row", "Changed rows were not replaced")
      service.keepPlaylistPage()
      service.openPlaylist({ id: "versioned", snapshotId: "v2" })
      expect(requests.length === 2, "Changed cache did not retain its new version")
      service.api.cancelAll()
      console.log("PLAYLIST_VERSIONS_PASS")
      Qt.quit()
    }
  }
}
