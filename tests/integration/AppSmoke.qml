import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Service { id: spotifyService }
  Plugin.Panel { id: panel; service: spotifyService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }
  Timer {
    interval: 20
    running: true
    onTriggered: {
      spotifyService.applySettings({ deviceName: "Desk" })
      spotifyService.applySettings({})
      if (spotifyService.deviceName !== "Desk")
        throw new Error("A blank settings push reset saved settings")
      spotifyService.libraryCacheReady = false
      spotifyService.applyLibraryCacheFile(JSON.stringify({ version: 1, playlists: [
        { id: "r", uri: "spotify:playlist:r", ownerId: "spotify" },
        { id: "m", uri: "spotify:playlist:m", ownerId: "jeremy" }] }))
      if (spotifyService.spotifyPlaylists.length !== 1)
        throw new Error("Spotify's playlists from last time were not kept aside")
      spotifyService.playDays = ({ "2026-09-14": 3 })
      spotifyService.libraryCacheFetchedAt = Date.now()
      spotifyService.auth.loggedOut()
      if (!spotifyService.playDays["2026-09-14"])
        throw new Error("A changed client id erased the listening record")
      if (spotifyService.libraryCacheFresh)
        throw new Error("A changed client id kept an emptied library as fresh")
      if (spotifyService.spotifyPlaylists.length)
        throw new Error("The next account would inherit Spotify's playlists")
      spotifyService.libraryCacheReady = true
      spotifyService.forgetPersonalRecord()
      if (spotifyService.libraryCacheFresh)
        throw new Error("An emptied library was kept as fresh")
      spotifyService.auth.customClientId = "invalid"
      spotifyService.search("smoke-test", "track")
      if (spotifyService.searchLoading || !spotifyService.searchError)
        throw new Error("Search service did not return the authorization error")
      if (!panel.primaryNavigationItems().some(function(item) { return item.id === "search" }))
        throw new Error("Search navigation is missing")
      spotifyService.clearSearch()
      if (spotifyService.searchQuery !== "") throw new Error("Search state did not clear")
      spotifyService.api.cancelAll()
      spotifyService.api.rateLimitedUntil = Date.now() + 60000
      var cachedRefresh = spotifyService.pageRequest("GET", "/me/albums", null,
        function() {}, true)
      if (!cachedRefresh.job || cachedRefresh.job.priority !== "background")
        throw new Error("A cached page bypassed background pacing")
      spotifyService.api.cancelAll()
      spotifyService.api.rateLimitedUntil = 0
      spotifyService.api.backgroundSuspendedUntil = 0
      spotifyService.api.lastBackgroundStartedAt = 0
      spotifyService.api.lastInteractiveStartedAt = 0
      spotifyService.lastError = ""
      spotifyService.savedAlbums = [{ id: "cached-album" }]
      var crawled = 0
      spotifyService.loadLibraryCollection("albums", false,
        function() { crawled++ }, undefined, true)
      if (spotifyService.savedAlbumsLoading || spotifyService.lastError)
        throw new Error("A failed optional refresh hid the visible action status")
      if (crawled || spotifyService.savedAlbums[0].id !== "cached-album")
        throw new Error("A failed crawl replaced cached data or continued paging")
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
