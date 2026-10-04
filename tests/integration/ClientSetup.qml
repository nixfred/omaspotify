import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: test
  property int saves: 0
  property int authorizations: 0
  QtObject {
    id: mockService
    property var settings: ({ clientId: "" })
    property bool usingPersonalClientId: settings.clientId !== ""
    property var auth: ({ redirectUri: "http://127.0.0.1:8989/login", lastError: "",
      loggedIn: false, loginBusy: false, refreshBusy: false, switchingIdentity: false,
      validClientId: true, beginLogin: function() { test.authorizations++ } })
    function persistSettings(values) { settings = values; test.saves++ }
  }
  FloatingWindow {
    id: window
    width: 1024
    height: 768
    visible: true
    color: "#17141f"
    Plugin.ClientSetupPrompt {
      id: guide
      x: 32; y: 32
      width: Math.min(808, window.width - 64)
      height: implicitHeight
      service: mockService
      onCopyRequested: function(text) { if (text !== mockService.auth.redirectUri) throw new Error("Wrong redirect") }
    }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var result = find(item.children[i], name)
      if (result) return result
    }
    return null
  }
  function expect(value, message) { if (!value) throw new Error(message) }
  property int phase: 0
  Timer {
    id: timer
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      if (phase === 0) {
        guide.clientId = "invalid"
        expect(!guide.saveClient() && test.saves === 0, "Invalid ID was saved")
        expect(!find(guide, "saveClientId").enabled, "Invalid ID enabled Save")
        guide.clientId = "ABCDEF0123456789ABCDEF0123456789"
        find(guide, "saveClientId").clicked()
        expect(mockService.settings.clientId === "abcdef0123456789abcdef0123456789", "Valid ID was not normalized and persisted")
        find(guide, "authorizeClient").clicked()
        expect(test.authorizations === 1, "Authorization was not requested")
        find(guide, "copyRedirect").clicked()
        guide.clientId = ""
        find(guide, "saveClientId").clicked()
        expect(mockService.settings.clientId === "", "Shared app could not be selected")
        mockService.auth = Object.assign({}, mockService.auth, { lastError: "Spotify could not authorize this app. Verify the exact Redirect URI and try again." })
        phase++
        return
      }
      expect(guide.y + guide.height <= window.height - 24, "Setup does not fit without scrolling")
      expect(find(guide, "dismissSetup").y >= 0, "Dismiss control is unavailable")
      guide.grabToImage(function(result) {
        result.saveToFile(phase === 1 ? "/tmp/omaspotify-client-setup-1024.png"
          : "/tmp/omaspotify-client-setup-1280.png")
        if (phase === 1) {
          phase++
          window.width = 1280
          window.height = 800
          timer.start()
        } else {
          console.log("CLIENT_SETUP_PASS")
          Qt.quit()
        }
      })
      stop()
    }
  }
}
