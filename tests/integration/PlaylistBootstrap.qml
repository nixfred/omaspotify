import QtQuick
import Quickshell
import "plugin" as Plugin

// After a restart with idle caching on, the session is signed in but nothing has
// asked Spotify whose account it is. Real Service, Settings, authorization and
// transport; only the token and the HTTP wire are synthetic. The panel never opens.
ShellRoot {
  id: test
  Plugin.Service { id: service }
  property var requests: []
  property int phase: 0
  function expect(value, message) { if (!value) throw new Error(message) }
  function sent(path) {
    return requests.filter(function(xhr) { return xhr.url.indexOf(path) >= 0 })
  }
  function profileRequests() {
    return requests.filter(function(xhr) { return /\/v1\/me$/.test(xhr.url) })
  }
  function complete(xhr, status, payload) {
    xhr.status = status
    xhr.responseText = JSON.stringify(payload)
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }
  Timer {
    interval: 20
    running: true
    onTriggered: {
      service.api.xhrFactory = function() {
        var xhr = { readyState: 0, status: 0, responseText: "", url: "", aborted: false,
          onreadystatechange: null, open: function(method, url) { this.url = url },
          send: function() {}, setRequestHeader: function() {},
          abort: function() { this.aborted = true }, getResponseHeader: function() { return "" } }
        test.requests.push(xhr)
        return xhr
      }
      service.auth.switchingIdentity = false
      service.auth.accessToken = "fixture-token"
      service.auth.accessTokenExpiresAt = Date.now() + 3600000
      service.auth.loggedIn = true
      service.playlistCacheBootstrapMs = 300
      service.playlists = [{ id: "warm", type: "playlist", kind: "context", name: "Fixture",
        snapshotId: "v1", ownerId: "reload-account" }]
      service.applySettings({ cachePlaylistsOnIdle: "On" })
      watch.start()
    }
  }
  Timer {
    id: watch
    interval: 50
    repeat: true
    onTriggered: {
      test.expect(!service.uiVisible, "the panel was opened")
      var profile = test.profileRequests()
      if (test.phase === 0 && profile.length === 1) {
        test.expect(service.playlistCacheStatus === "Waiting for your Spotify account",
          "the cache status does not say what it waits for: " + service.playlistCacheStatus)
        test.complete(profile[0], 503, { error: { status: 503, message: "Service unavailable" } })
        test.expect(service.currentUserId === "", "a failed profile answer named an account")
        test.expect(service.lastError === "", "a quiet startup check reported an error")
        test.phase = 1
      } else if (test.phase === 1 && profile.length === 2) {
        test.complete(profile[1], 200, { id: "reload-account", display_name: "Fixture" })
        test.expect(service.currentUserId === "reload-account", "the retried profile was ignored")
        test.phase = 2
      } else if (test.phase === 2 && test.sent("/playlists/warm").length > 0) {
        var warm = test.sent("/playlists/warm")[0]
        test.expect(warm.url.indexOf("fields=snapshot_id") >= 0, "warming did not start with a version check")
        test.expect(test.profileRequests().length === 2, "the profile was asked for again after it arrived")
        stop()
        service.api.cancelAll()
        console.log("PLAYLIST_BOOTSTRAP_PASS")
        Qt.quit()
      }
    }
  }
  Timer {
    interval: 12000
    running: true
    onTriggered: {
      console.log("PLAYLIST_BOOTSTRAP_TIMEOUT at phase " + test.phase + ": "
        + test.requests.map(function(xhr) { return xhr.url }).join(", "))
      Qt.exit(1)
    }
  }
}
