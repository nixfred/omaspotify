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
      spotifyService.api.backgroundSuspendedUntil = Date.now() + 60000
      spotifyService.selectedPlaylist = { id: "smoke-list" }
      spotifyService.playlistItems = [{ id: "cached-row" }]
      spotifyService.playlistItemsNext = ""
      spotifyService.playlistItemsLoading = false
      spotifyService.loadPlaylistItems(false)
      var check = spotifyService.api.requestQueue[0]
      if (!spotifyService.playlistItemsLoading || !check
          || check.priority !== "background" || !check.deadlineAt)
        throw new Error("A cached playlist check was not paced and bounded")
      spotifyService.playlistItemsNext = "https://api.spotify.com/v1/playlists/smoke-list/items?offset=50&limit=50"
      spotifyService.loadMorePlaylistItems()
      if (spotifyService.api.requestQueue.length || spotifyService.playlistItemsLoading)
        throw new Error("Load More waited behind a paused cached check")
      if (spotifyService.playlistItems.length !== 1
          || spotifyService.playlistItems[0].id !== "cached-row")
        throw new Error("Load More dropped the cached rows")
      spotifyService.api.backgroundSuspendedUntil = 0
      spotifyService.api.lastBackgroundStartedAt = 0
      spotifyService.api.lastInteractiveStartedAt = 0
      spotifyService.lastError = ""
      spotifyService.savedAlbums = [{ id: "cached-album" }]
      spotifyService.fillSidebarCollection("albums")
      if (spotifyService.savedAlbumsLoading || spotifyService.lastError)
        throw new Error("A failed optional refresh hid the visible action status")
      if (spotifyService.savedAlbums.length !== 1
          || spotifyService.savedAlbums[0].id !== "cached-album")
        throw new Error("A failed crawl replaced cached data")
      if (!spotifyService.libraryCrawlIncomplete)
        throw new Error("A failed crawl was treated as complete")
      spotifyService.libraryCrawlIncomplete = false
      spotifyService.api.lastBackgroundStartedAt = 0
      spotifyService.savedAlbums = [{ id: "first-page" }]
      spotifyService.savedAlbumsNext = "https://api.spotify.com/v1/me/albums?offset=50&limit=50"
      spotifyService.requestCollectionOffsets("albums",
        spotifyService.libraryCollectionSpec("albums"), [50], 0,
        [{ id: "cached-album" }, { id: "cached-second" }])
      offsetCrawlCheck.start()
    }
  }
  Timer {
    id: offsetCrawlCheck
    interval: 100
    repeat: true
    property int ticks: 0
    onTriggered: {
      if (!spotifyService.libraryCrawlIncomplete) {
        if (++ticks > 80) throw new Error("A failing offset crawl never gave up")
        return
      }
      stop()
      if (spotifyService.api.timedJobs.length || spotifyService.lastError)
        throw new Error("A failed offset crawl left work queued or replaced the action status")
      var ids = spotifyService.savedAlbums.map(function(item) { return item.id })
      if (ids.join(",") !== "first-page,cached-album,cached-second")
        throw new Error("A failed offset crawl dropped cached rows: " + ids.join(","))
      if (!spotifyService.savedAlbumsNext)
        throw new Error("A failed offset crawl was marked complete")
      spotifyService.libraryCrawlIncomplete = false
      spotifyService.requestCollectionOffsets("playlists",
        spotifyService.libraryCollectionSpec("playlists"), [], 0, [])
      freshnessCheck.start()
    }
  }
  Timer {
    id: freshnessCheck
    interval: 100
    repeat: true
    property int ticks: 0
    property bool failed: false
    onTriggered: {
      if (++ticks > 60) throw new Error("The library cache never settled")
      if (!failed) {
        if (!spotifyService.libraryCacheFresh) return
        spotifyService.api.lastBackgroundStartedAt = 0
        spotifyService.api.lastInteractiveStartedAt = 0
        spotifyService.followedArtists = [{ id: "cached-artist" }]
        spotifyService.fillSidebarCollection("artists")
        if (spotifyService.libraryCacheFresh)
          throw new Error("A late crawl failure left the library marked fresh")
        failed = true
        ticks = 0
        return
      }
      if (ticks < 15) return
      stop()
      if (spotifyService.libraryCacheFresh || spotifyService.libraryCacheFetchedAt !== 0)
        throw new Error("A late crawl failure was saved as fresh")
      if (spotifyService.followedArtists.length !== 1)
        throw new Error("A late crawl failure dropped cached artists")
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
