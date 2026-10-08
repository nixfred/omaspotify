import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: test
  Plugin.Service { id: service }
  Plugin.Panel { id: panel; service: service; width: 1024; height: 768 }
  property var requests: []
  property double clock: Date.now()
  function expect(value, message) { if (!value) throw new Error(message) }
  function playlistRequests() { return requests.filter(function(x) { return x.url.indexOf("/playlists/warm") >= 0 }) }
  function last() { var rows = playlistRequests(); return rows[rows.length - 1] }
  function complete(status, payload) {
    var xhr = last()
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
      complete(200, { snapshot_id: "v1" })
      expect(service.playlistItems.length === 50 && !service.playlistItemsLoading, "unchanged keeps songs")
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
