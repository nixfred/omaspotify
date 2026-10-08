import QtQuick

import "Api.js" as Api

// A library-sized cache, separate from the small recently-opened-page cache.
// The service supplies transport and disk I/O; tests use the same scheduler
// with a fake clock/wire. Only one request is owned at a time.
Item {
  id: root
  visible: false
  property string owner: ""
  property string identity: ""
  property bool warmingEnabled: false
  property bool idle: false
  property bool diskReady: false
  property string diskRaw: ""
  property var playlists: []
  property var entries: ({})
  property var validated: ({})
  property var retryAt: ({})
  property var sizes: ({})
  property var request: null
  property var abort: null
  property var now: function() { return Date.now() }
  property var handle: null
  property var work: null
  property int serial: 0
  property int cursor: 0
  property int maxEntries: 512
  property int maxRows: 50000
  property int maxBytes: 33554432
  property int itemLimit: 10000
  property int staleMs: 300000
  property int recheckMs: 3600000
  property int maxAgeMs: 604800000
  property int spacingMs: 3000
  property double nextAt: 0
  property double suspendedUntil: 0
  property bool budgetFull: false
  property string lastResult: ""
  readonly property bool canRun: warmingEnabled && idle && diskReady && owner !== ""
  readonly property int cachedCount: Object.keys(entries).length
  readonly property int completeCount: {
    var keys = Object.keys(entries)
    var total = 0
    for (var i = 0; i < keys.length; i++)
      if (!entries[keys[i]].data.next && entries[keys[i]].data.verified !== false) total++
    return total
  }
  readonly property string progress: completeCount + "/" + playlists.length
    + " lists complete · " + cachedCount + " available locally"
  readonly property string status: !warmingEnabled ? "Idle caching off"
    : budgetFull ? "Cache budget reached · opened playlists still load normally"
    : suspendedUntil > now() ? "Caching paused after Spotify refused a request"
    : !idle ? progress + " · resumes when the panel closes"
    : handle ? progress + " · downloading quietly"
    : progress + " · checking for changes"
  signal changed()
  signal versionChecked(string playlistId, string snapshotId)

  onCanRunChanged: if (!canRun) pause()
  onIdentityChanged: { pause(); suspendedUntil = 0; retryAt = ({}) }
  onOwnerChanged: { pause(); restore() }
  onDiskReadyChanged: if (diskReady) restore()

  Timer {
    interval: 1000
    running: root.canRun
    repeat: true
    onTriggered: root.tick()
  }

  function pause() {
    serial++
    if (handle && typeof abort === "function") abort(handle)
    handle = null
    work = null
    validated = ({})
  }

  function read(id) {
    var entry = entries[String(id || "")]
    return entry && Api.timestampIsFresh(entry.updatedAt, now(), maxAgeMs)
      ? entry.data : null
  }

  function freshness(id) {
    var entry = entries[String(id || "")]
    if (entry && entry.data.verified === false) return "stale"
    return Api.queryCacheState(entry, now(), staleMs)
  }

  function keep(data, checkedAt) {
    if (!owner || !diskReady || !data || !data.item || !data.item.id
        || !Array.isArray(data.items)) return false
    var id = String(data.item.id)
    var capped = Api.cappedPageSnapshot(data, itemLimit)
    var existing = read(id)
    // Opening a warmed page must not truncate its full copy back to 50 rows.
    if (existing && existing.item.snapshotId && existing.item.snapshotId === capped.item.snapshotId
        && existing.items.length > capped.items.length) capped = existing
    var entry = { updatedAt: checkedAt === undefined ? now() : checkedAt, data: capped }
    var bytes = JSON.stringify(entry).length * 2
    var rows = capped.items.length
    var totalBytes = bytes
    var totalRows = rows
    var keys = Object.keys(entries)
    for (var i = 0; i < keys.length; i++) {
      if (keys[i] === id) continue
      totalBytes += Number(sizes[keys[i]]) || 0
      totalRows += entries[keys[i]].data.items.length
    }
    if ((!entries[id] && keys.length >= maxEntries) || totalBytes > maxBytes || totalRows > maxRows) {
      budgetFull = true
      return false
    }
    var next = Api.shallowCopy(entries)
    next[id] = entry
    entries = next
    sizes[id] = bytes
    changed()
    return true
  }

  function drop(id) {
    var key = String(id || "")
    // Edits cancel any in-flight read, including metadata/final verification.
    pause()
    var next = Api.shallowCopy(entries)
    delete next[key]
    delete sizes[key]
    delete retryAt[key]
    entries = next
    budgetFull = false
    changed()
  }

  function clear() {
    pause()
    entries = ({})
    sizes = ({})
    retryAt = ({})
    diskRaw = ""
    budgetFull = false
    suspendedUntil = 0
    changed()
  }

  function serialize() {
    diskRaw = JSON.stringify({ version: 1, owner: owner, entries: entries })
    return diskRaw
  }

  function restore() {
    entries = ({})
    sizes = ({})
    retryAt = ({})
    budgetFull = false
    if (!owner || !diskReady || diskRaw.length * 2 > maxBytes + 4096) return
    var record = Api.parseJson(diskRaw, ({}))
    if (!record || record.version !== 1 || record.owner !== owner) return
    var stored = record.entries || ({})
    var keys = Object.keys(stored)
    for (var i = 0; i < keys.length; i++) {
      var entry = stored[keys[i]]
      if (!entry || !Api.timestampIsFresh(entry.updatedAt, now(), maxAgeMs)
          || !entry.data || !entry.data.item || String(entry.data.item.id) !== keys[i]
          || !Array.isArray(entry.data.items)) continue
      keep(entry.data, entry.updatedAt)
    }
  }

  // Breadth first: all first pages before any deep paging, then round robin.
  // Full pages are compared with snapshot_id at most once an hour (foreground freshness remains five minutes).
  function candidate() {
    var list = playlists || []
    for (var phase = 0; phase < 2; phase++) {
      for (var j = 0; j < list.length; j++) {
        var index = (cursor + j) % list.length
        var item = list[index]
        if (!item || !item.id || (retryAt[item.id] || 0) > now()) continue
        var kept = read(item.id)
        if (phase === 0 && kept) continue
        if (phase === 1 && kept && !kept.next && kept.verified !== false
            && Api.timestampIsFresh(entries[item.id].updatedAt, now(), recheckMs)
            && (!item.snapshotId || item.snapshotId === kept.item.snapshotId)) continue
        if (kept && kept.items.length >= itemLimit && kept.next) continue
        cursor = (index + 1) % list.length
        return item
      }
    }
    return null
  }

  function send(path, query, callback) {
    var expected = serial
    var completed = false
    var returned = request(path, query, function(statusCode, payload, error) {
      completed = true
      if (expected !== root.serial) return
      root.handle = null
      root.nextAt = root.now() + root.spacingMs
      if (error) {
        root.lastResult = "Cache request refused or failed (HTTP " + statusCode + ")"
        var id = root.work && root.work.item.id
        if (id) root.retryAt[id] = root.now() + (statusCode === 403 || statusCode === 404 ? 3600000 : 300000)
        if (statusCode === 429) root.suspendedUntil = root.now() + 300000
        root.work = null
        return
      }
      root.lastResult = ""
      callback(payload)
    })
    if (!completed) handle = returned
  }

  function tick() {
    if (!canRun || handle || budgetFull || now() < nextAt || now() < suspendedUntil
        || typeof request !== "function") return
    if (!work) {
      var item = candidate()
      if (!item) return
      var kept = read(item.id)
      work = { item: item, kept: kept, stage: "metadata" }
      if (kept && kept.next && validated[item.id] === kept.item.snapshotId
          && (!item.snapshotId || item.snapshotId === kept.item.snapshotId))
        work.stage = "items"
    }
    var id = String(work.item.id)
    if (work.stage === "items") {
      var existing = work.kept
      var path = existing ? existing.next : "/playlists/" + encodeURIComponent(id) + "/items"
      send(path, existing ? null : { limit: 50 }, function(payload) {
        if (!payload || !Array.isArray(payload.items)) {
          root.retryAt[id] = root.now() + 300000
          root.work = null
          return
        }
        var offset = Number(payload && payload.offset) || 0
        var page = Api.normalizePage(payload, function(value) {
          var position = offset++
          var track = Api.normalizeTrack(value, 96)
          if (track) track.playlistPosition = position
          return track
        })
        var data = { item: root.work.item,
          items: (root.work.kept ? root.work.kept.items : []).concat(page.items), next: page.next,
          verified: false }
        // A broken cursor must not spin forever or duplicate an entire page.
        if (root.work.kept && page.next && page.next === root.work.kept.next) {
          root.retryAt[id] = root.now() + 3600000
          root.work = null
          return
        }
        root.keep(data)
        if (!page.next) root.work = { item: data.item, kept: data, stage: "verify" }
        else root.work = null
      })
    } else {
      var verifying = work.stage === "verify"
      send("/playlists/" + encodeURIComponent(id), { fields: "snapshot_id" }, function(payload) {
        var version = String(payload && payload.snapshot_id || "")
        var kept = root.work.kept
        if (!version) {
          root.retryAt[id] = root.now() + 300000
          root.work = null
          return
        }
        root.versionChecked(id, version)
        if (verifying) {
          if (version === root.work.item.snapshotId) {
            kept.verified = true
            root.keep(kept)
          }
          else root.drop(id)
          root.work = null
          return
        }
        root.validated[id] = version
        var current = Api.shallowCopy(root.work.item)
        current.snapshotId = version
        if (kept && version === kept.item.snapshotId && !kept.next) {
          kept.verified = true
          root.keep(kept)
          root.work = null
        } else root.work = { item: current, kept: kept && version === kept.item.snapshotId ? kept : null, stage: "items" }
      })
    }
  }
}
