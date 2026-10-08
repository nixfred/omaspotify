import QtQuick
import Quickshell
import "plugin" as Plugin

// Real Service/transport queues and observable HTTP requests; only auth and
// the network are fake. Personal quota exhaustion must not block a foreign
// playlist which the already-authorized catalog app can read.
ShellRoot {
  id: test
  Plugin.Service { id: service }
  property var requests: []
  property int phase: 0
  property var sharedIdentity: ({ loggedIn: true,
    withAccessToken: function(cb) { cb("catalog-token", "") },
    invalidateAccessToken: function() {} })
  function expect(ok, message) { if (!ok) throw new Error(message) }
  function wire(app) {
    return function() {
      var xhr = { readyState: 0, status: 0, responseText: "", url: "", app: app,
        headers: {}, aborted: false, method: "",
        open: function(method, url) { this.method = method; this.url = url },
        send: function() {}, abort: function() { this.aborted = true },
        setRequestHeader: function(k, v) { this.headers[k] = v },
        getResponseHeader: function() { return "63000" } }
      requests.push(xhr)
      return xhr
    }
  }
  function complete(xhr, status, data) {
    xhr.status = status
    xhr.responseText = JSON.stringify(data)
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }
  function last() { return requests[requests.length - 1] }
  function expectApp(app, path) {
    expect(last().app === app && last().url.indexOf(path) >= 0,
      "Wrong app for " + path + ": " + last().app)
    expect(last().headers.Authorization === "Bearer " + (app === "catalog" ? "catalog-token" : "personal-token"),
      "Wrong authorization identity")
  }
  function row(id) {
    return { track: { id: id, name: id, uri: "spotify:track:" + id, artists: [] } }
  }
  Timer {
    interval: 30
    repeat: true
    running: true
    onTriggered: {
      if (phase++ === 0) {
        service.settings = { clientId: "11111111111111111111111111111111" }
        service.api.cancelAll()
        service.api.auth = { loggedIn: true,
          withAccessToken: function(cb) { cb("personal-token", "") },
          invalidateAccessToken: function() {} }
        service.api.fallbackAuth = sharedIdentity
        service.api.xhrFactory = wire("personal")
        service.currentUserId = "me"
        service.playlists = [
          { type: "playlist", id: "foreign", ownerId: "other", snapshotId: "v1" },
          { type: "playlist", id: "own", ownerId: "me" },
          { type: "playlist", id: "collab", ownerId: "other", collaborative: true },
          { type: "playlist", id: "unknown" } ]
        return
      }
      stop()
      expect(!!service.api.fallbackTransport, "Catalog transport missing")
      service.api.fallbackTransport.xhrFactory = wire("catalog")
      service.api.fallbackTransport.lastBackgroundStartedAt = 0
      service.api.fallbackTransport.lastInteractiveStartedAt = 0
      service.openPlaylist(service.playlists[0])
      expectApp("catalog", "/playlists/foreign/items")
      expect(requests.length === 1, "Foreign playlist spent personal quota first")
      complete(last(), 200, { items: [row("first")], offset: 0,
        next: "https://api.spotify.com/v1/playlists/foreign/items?offset=1&limit=50" })
      expect(service.playlistItems.length === 1 && !service.playlistItemsError,
        "Catalog rows did not reach the playlist")
      service.loadMorePlaylistItems()
      expectApp("catalog", "offset=1")
      complete(last(), 200, { items: [row("second")], offset: 1, next: null })
      expect(service.playlistItems.length === 2, "Catalog continuation lost rows")
      service.keepPlaylistPage()
      var count = requests.length
      service.openPlaylist(service.playlists[0])
      expect(service.playlistItems.length === 2 && requests.length === count,
        "Reopening downloaded the cached songs again")
      var quota = { error: { status: 429, reason: "QUOTA_EXCEEDED", message: "Too many requests" } }
      service.openPlaylist(service.playlists[1])
      expectApp("personal", "/playlists/own/items")
      complete(last(), 429, quota)
      expect(service.playlistItemsEmptyMessage.indexOf("developer quota") >= 0,
        "Quota reason was replaced by generic retry advice")
      count = requests.length
      expect(!service.playlistItemsLoading && !service.pendingPlaybackBody,
        "Quota failure left loading or started playback")
      service.openPlaylist(service.playlists[2])
      expectApp("personal", "/playlists/collab/items")
      complete(last(), 200, { items: [], next: null })
      service.openPlaylist(service.playlists[3])
      expectApp("personal", "/playlists/unknown/items")
      complete(last(), 200, { items: [], next: null })
      service.currentUserId = ""
      service.openPlaylist({ type: "playlist", id: "no-profile", ownerId: "other" })
      expectApp("personal", "/playlists/no-profile/items")
      complete(last(), 200, { items: [], next: null })
      service.currentUserId = "me"
      sharedIdentity.loggedIn = false
      service.openPlaylist({ type: "playlist", id: "no-catalog-login", ownerId: "other" })
      expectApp("personal", "/playlists/no-catalog-login/items")
      complete(last(), 429, quota)
      expect(service.playlistItemsEmptyMessage.indexOf("developer quota") >= 0,
        "Unavailable catalog login hid the personal refusal")
      service.pageRequest("GET", "/me/playlists", null, function() {}, false)
      expectApp("personal", "/me/playlists")
      complete(last(), 429, quota)
      service.pageRequest("POST", "/playlists/foreign/items", null, function() {}, false)
      expectApp("personal", "/playlists/foreign/items")
      complete(last(), 200, {})
      service.api.cancelAll()
      console.log("PLAYLIST_CATALOG_PASS")
      Qt.quit()
    }
  }
}
