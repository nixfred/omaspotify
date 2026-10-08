import QtQuick
import Quickshell
import "plugin" as Plugin

// Real Service/transport dispatch with a held status response. Neither the
// user's keyring nor a real receiver is used by this fixture.
ShellRoot {
  id: test
  Plugin.Service { id: service }
  property var requests: []
  property int stage: 0
  property double probeStarted: 0

  function expect(value, message) { if (!value) throw new Error(message) }
  function song(uri) { return { type: "track", uri: "spotify:track:" + uri } }
  function writes() {
    return requests.filter(function(xhr) { return xhr.method === "PUT" })
  }
  function complete(xhr, status, payload) {
    xhr.status = status
    xhr.responseText = JSON.stringify(payload)
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }
  function reset() {
    service.api.cancelAll()
    service.clearPendingPlayback()
    service.remotePlaybackWaiters = []
    service.remotePlaybackLoading = false
    service.remotePlayback = null
    service.devices = []
    service.selectedDeviceId = ""
    service.selectedDeviceExplicit = false
    service.lastError = ""
    requests = []
  }
  Timer {
    interval: 50
    running: true
    onTriggered: {
      service.api.cancelAll()
      service.api.auth = { loggedIn: true,
        withAccessToken: function(callback) { callback("test-token", "") },
        invalidateAccessToken: function() {} }
      service.api.fallbackAuth = null
      service.api.xhrFactory = function() {
        var xhr = { readyState: 0, status: 0, responseText: "", method: "", url: "",
          body: "", aborted: false, onreadystatechange: null,
          open: function(method, url) { this.method = method; this.url = url },
          send: function(body) { this.body = body || "" },
          setRequestHeader: function() {}, getResponseHeader: function() { return "" },
          abort: function() { this.aborted = true } }
        test.requests.push(xhr)
        return xhr
      }
      reset()
      // A displayed active receiver is already enough to dispatch the click.
      service.remotePlayback = { device: { id: "speaker", active: true, local: false } }
      service.devices = [service.remotePlayback.device]
      service.loadPlaybackState()
      expect(requests.length === 1, "Status request did not start")
      service.playItem(song("first"), null, "", "")
      phase.start()
    }
  }
  Timer {
    id: phase
    interval: 100
    onTriggered: {
      if (stage === 0) {
        expect(writes().length === 1,
          "Known receiver waited behind the unrelated status refresh")
        expect(writes()[0].url.indexOf("device_id=speaker") >= 0,
          "Playback moved off the displayed remote receiver")
        expect(JSON.parse(writes()[0].body).uris[0] === "spotify:track:first",
          "The wrong song was dispatched")
        reset()
        // With no known active receiver, the first refresh still wins the race
        // against automatically starting playback on this computer.
        service.loadPlaybackState()
        service.playItem(song("unknown"), null, "", "")
        expect(writes().length === 0, "Unknown receiver was chosen before the refresh")
        complete(requests[0], 200, { device: { id: "fresh-speaker", name: "Speaker",
          type: "Speaker", is_active: true, is_restricted: false }, is_playing: false })
        expect(writes().length === 1
          && writes()[0].url.indexOf("device_id=fresh-speaker") >= 0,
          "Fresh receiver was not used by the waiting click")
        reset()
        // A known running local receiver can use Connect immediately while
        // its optional socket is unavailable; no fixed five-second wait.
        service.daemon.credentialsAvailable = true
        service.daemon.binaryAvailable = true
        service.daemon.unitAvailable = true
        service.daemon.serviceActive = true
        service.devices = [{ id: "local", local: true, active: true, restricted: false }]
        service.selectedDeviceId = "local"
        service.selectedDeviceExplicit = true
        service.playItem(song("local"), null, "", "")
        stage = 1
        restart()
      } else if (stage === 1) {
        expect(writes().length === 1 && writes()[0].url.indexOf("device_id=local") >= 0,
          "Known local receiver waited for an unavailable socket")
        reset()
        service.daemon.serviceActive = false
        service.daemon.credentialsAvailable = false
        probeStarted = Date.now()
        service.loadPlaybackState()
        service.playItem(song("timeout"), null, "", "")
        stage = 2
        interval = 2400
        restart()
      } else {
        expect(!service.remotePlaybackLoading && !service.pendingPlaybackBody,
          "A stalled receiver refresh kept the click pending")
        expect(requests[0].aborted, "Stalled receiver refresh was not cancelled")
        expect(Date.now() - probeStarted < 3500, "Receiver probe exceeded its short deadline")
        expect(writes().length === 0, "Failed probe sent playback to an unknown receiver")
        expect(service.lastError.length > 0, "Unavailable playback gave no actionable error")
        console.log("PLAYBACK_DISPATCH_PASS")
        Qt.quit()
      }
    }
  }
}
