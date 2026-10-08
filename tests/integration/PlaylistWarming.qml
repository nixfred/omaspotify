import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Api.js" as Api

ShellRoot {
  id: test
  Plugin.Service { id: service }
  Plugin.Panel { id: panel; service: service; width: 1024; height: 768 }
  property var requests: []
  property double clock: Date.now()
  property int songFileWrites: 0
  Connections {
    target: service.playlistCache
    function onChanged() { test.songFileWrites++ }
  }
  function expect(value, message) { if (!value) throw new Error(message) }
  function playlistRequests() { return requests.filter(function(x) { return x.url.indexOf("/playlists/warm") >= 0 }) }
  function last() { var rows = playlistRequests(); return rows[rows.length - 1] }
  function lastFor(id) {
    var rows = requests.filter(function(x) { return x.url.indexOf("/playlists/" + id) >= 0 })
    return rows[rows.length - 1]
  }
  function complete(status, payload, xhr) {
    xhr = xhr || last()
    xhr.status = status
    xhr.responseText = JSON.stringify(payload)
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }
  function step() {
    clock += 4000
    service.api.lastBackgroundStartedAt = 0
    service.api.lastInteractiveStartedAt = 0
    service.api.pumpRequests()
    service.playlistCache.tick()
  }
  Timer {
    id: finishTimer
    interval: 150
    onTriggered: {
      expect(panel.shortcutsBlocked, "cache popup owns keyboard focus")
      expect(panel.dismissTransientPopup(), "Escape can dismiss cache controls")
      console.log("PLAYLIST_WARMING_PASS")
      Qt.quit()
    }
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      stop()
      service.api.cancelAll()
      service.api.auth = { loggedIn: true,
        withAccessToken: function(callback) { callback("test-token", "") },
        invalidateAccessToken: function() {} }
      service.api.fallbackAuth = null
      service.api.now = function() { return test.clock }
      service.api.xhrFactory = function() {
        var xhr = { readyState: 0, status: 0, responseText: "", url: "", aborted: false,
          onreadystatechange: null, open: function(method, url) { this.url = url },
          send: function() {}, setRequestHeader: function() {},
          abort: function() { this.aborted = true }, getResponseHeader: function() { return "300" } }
        test.requests.push(xhr)
        return xhr
      }
      service.auth.loggedIn = true
      service.currentUserId = "warming-account"
      service.playlistCache.diskReady = true
      service.playlistCache.clear()
      service.playlistCache.now = function() { return test.clock }
      service.playlists = [{ id: "warm", type: "playlist", kind: "context", name: "Fixture", snapshotId: "v1" }]
      service.applySettings({ cachePlaylistsOnIdle: "On" })
      expect(service.cachePlaylistsOnIdle, "real Settings enable warming")
      service.playlistCache.tick()
      expect(last().url.indexOf("/playlists/warm?") >= 0, "warm metadata sent")
      complete(200, { snapshot_id: "v1" }); step()
      expect(last().url.indexOf("/playlists/warm/items") >= 0, "warm rows sent")
      var rows = []
      for (var i = 0; i < 50; i++) rows.push({ track: { id: "row" + i, name: "Track", uri: "spotify:track:row" + i, artists: [] } })
      complete(200, { items: rows, offset: 0, next: null }); step()
      complete(200, { snapshot_id: "v1" })
      var count = playlistRequests().length
      service.setUiVisible("test", true)
      service.openPlaylist(service.playlists[0])
      expect(service.playlistItems.length === 50, "warmed songs draw immediately")
      expect(!service.playlistItemsLoading, "cache avoids loading screen")
      expect(playlistRequests().length === count, "fresh opening sends no Spotify read")
      service.openDetail(service.playlists[0])
      expect(service.detailItems.length === 50 && !service.detailLoading, "detail shares warmed rows")
      // A stale copy stays readable, and unchanged metadata costs one request.
      clock += 301000
      service.api.cancelAll()
      service.openPlaylist(service.playlists[0]); step()
      expect(service.playlistItems.length === 50, "stale rows remain visible")
      var writes = songFileWrites
      complete(200, { snapshot_id: "v1" })
      expect(service.playlistItems.length === 50 && !service.playlistItemsLoading, "unchanged keeps songs")
      expect(songFileWrites === writes, "a confirmed version rewrote the whole song file")
      expect(service.playlistCache.freshness("warm") === "fresh", "a confirmed version stayed stale")
      // Spotify hides the songs of a playlist you only follow: that is a message,
      // not an empty list to keep and show without it next time.
      var followed = { id: "followed", type: "playlist", kind: "context", name: "Followed",
        snapshotId: "f1", ownerId: "someone-else" }
      service.openDetail(followed); step()
      complete(200, { id: "followed", type: "playlist", name: "Followed", snapshot_id: "f1",
        owner: { id: "someone-else" } }, lastFor("followed"))
      expect(service.detailMessage === Api.playlistItemsHiddenMessage(), "hidden songs are explained")
      service.keepDetailPage()
      expect(!service.playlistCache.read("followed"), "hidden songs were cached as an empty list")
      var asked = requests.length
      service.openDetail(followed); step()
      expect(requests.length === asked + 1 && service.detailLoading, "a hidden list was drawn from the cache")
      complete(200, { id: "followed", type: "playlist", name: "Followed", snapshot_id: "f1",
        owner: { id: "someone-else" } }, lastFor("followed"))
      expect(service.detailMessage === Api.playlistItemsHiddenMessage(), "reopening lost the explanation")
      // Off adds nothing from opened pages; songs already saved stay readable.
      service.applySettings({ cachePlaylistsOnIdle: "Off" })
      var other = { id: "other", type: "playlist", kind: "context", name: "Other",
        snapshotId: "o1", ownerId: "warming-account" }
      service.openPlaylist(other); step()
      complete(200, { items: rows.slice(0, 5), offset: 0, next: null }, lastFor("other"))
      expect(service.playlistItems.length === 5, "opened playlist loads while Off")
      service.keepPlaylistPage()
      expect(!service.playlistCache.read("other"), "Off still filled the library cache")
      service.openPlaylist(service.playlists[0])
      expect(service.playlistItems.length === 50, "Off stopped reading saved songs")
      expect(service.playlistCacheStatus.indexOf("Idle caching off") === 0, "Off status")
      service.applySettings({ cachePlaylistsOnIdle: "On" })
      service.setUiVisible("test", false)
      service.api.cancelAll()
      service.forgetCachedPlaylist(service.playlists[0])
      step()
      var pending = last()
      service.setUiVisible("test", true)
      expect(pending.aborted, "foreground opening aborts the warmer")
      panel.opened = true
      Qt.callLater(function() { panel.openPlaylistCache(); finishTimer.start() })
    }
  }
}
