import QtQuick

// Separate transports prevent the shipped app's quota from delaying a
// personal app. No second queue is created until a fallback identity exists.
SpotifyTransport {
  id: root
  fallbackTransport: sharedTransport.item
  onFallbackAuthChanged: cancelForwardedRequests()

  Loader {
    id: sharedTransport
    active: root.fallbackAuth !== null
    sourceComponent: Component {
      SpotifyTransport {
        auth: root.fallbackAuth
        now: root.now
        xhrFactory: root.xhrFactory
        activeTimeoutMs: root.activeTimeoutMs
        slowRequestMs: root.slowRequestMs
      }
    }
  }
}
