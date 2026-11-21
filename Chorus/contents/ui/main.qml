import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Effects
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.plasma.private.mpris as Mpris
import org.kde.plasma.plasma5support as P5Support
import "../code/lrc.js" as Lrc

PlasmoidItem {
    id: root

    preferredRepresentation: compactRepresentation
    Mpris.Mpris2Model { id: mpris }

    Instantiator {
        id: playerScan
        model: mpris
        delegate: QtObject {
            readonly property int idx: index
            readonly property string matchText:
                (String(model.identity || "") + " " + (String(model.desktopEntry || ""))).toLowerCase()
            readonly property bool matches: root.matchesFilter(matchText)
            function claim() {
                if (matches && !root.playerMatches && mpris.currentIndex !== idx)
                    mpris.currentIndex = idx;
            }
            onMatchesChanged: claim()
            onMatchTextChanged: root.playersRevision++
            Component.onCompleted: { root.playersRevision++; claim(); }
            Component.onDestruction: root.playersRevision++
            readonly property Connections conn: Connections {
                target: root
                function onPlayerMatchesChanged() { if (!root.playerMatches) claim(); }
            }
        }
    }

    property int playersRevision: 0
    function appRunning(token) {
        if (!token) return false;
        var rev = playersRevision;
        for (var i = 0; i < playerScan.count; i++) {
            var o = playerScan.objectAt(i);
            if (o && o.matchText.indexOf(token) !== -1) return true;
        }
        return false;
    }
    function currentPlayerIs(token) {
        if (!token || !player) return false;
        return ((player.identity || "") + " " + (player.desktopEntry || ""))
               .toLowerCase().indexOf(token) !== -1;
    }

    readonly property var player: mpris.currentPlayer
    readonly property var cfgMatchList: {
        var mode = Plasmoid.configuration.appMode;
        if (mode !== "custom") return [];
        var parts = (Plasmoid.configuration.playerMatch || "").toLowerCase().split(",");
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            var t = parts[i].trim();
            if (t !== "") out.push(t);
        }
        return out;
    }
    function matchesFilter(text) {
        if (cfgMatchList.length === 0) return true;
        for (var i = 0; i < cfgMatchList.length; i++)
            if (text.indexOf(cfgMatchList[i]) !== -1) return true;
        return false;
    }
    readonly property bool playerMatches: {
        if (!player) return false;
        return matchesFilter(((player.identity || "") + " " + (player.desktopEntry || "")).toLowerCase());
    }
    readonly property bool isPlaying: playerMatches && player.playbackStatus === Mpris.PlaybackStatus.Playing
    readonly property bool isPaused:  playerMatches && player.playbackStatus === Mpris.PlaybackStatus.Paused
    readonly property bool isActive:  isPlaying || isPaused
    readonly property bool hasTrack:  playerMatches && trackTitle !== ""

    property var optimistic: null
    property var pendingSpotifyTrack: null
    Timer {
        id: optimisticTimeout
        interval: 12000
        repeat: false
        onTriggered: {
            root.optimistic = null;
            root.pendingSpotifyTrack = null;
        }
    }
    Timer {
        id: optSettle
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.optimistic === null) return;
            var want = (root.optimistic.title || "").trim().toLowerCase();
            var have = root.trackTitle.trim().toLowerCase();
            if (root.isPlaying && have !== "" && have === want) root.optimistic = null;
            else restart();
        }
    }

    readonly property string rawTitle:  playerMatches && player.track  ? player.track  : ""
    readonly property string rawArtist: playerMatches && player.artist ? player.artist : ""
    readonly property string rawAlbum:  playerMatches && player.album  ? player.album  : ""
    readonly property url    rawArt:    playerMatches && player.artUrl ? player.artUrl : ""

    property var heldTrack: null
    property string snapTitle: ""
    property string snapArtist: ""
    property string snapAlbum: ""
    property url snapArt: ""
    Timer {
        id: metaHold
        interval: 500
        repeat: false
        onTriggered: {
            root.heldTrack = null;
            root.metaGate();
        }
    }
    onRawTitleChanged:  metaGate()
    onRawArtistChanged: metaGate()
    onRawAlbumChanged: {
        metaGate();
        if (trackTitle !== "" && (lyricsFetchTimer.running || (!haveSynced && !fetching)))
            lyricsFetchTimer.restart();
    }
    onRawArtChanged:    metaGate()
    function metaGate() {
        if (heldTrack !== null) {
            if (rawTitle !== heldTrack.title && rawLengthMs <= 0) return;
            heldTrack = null;
            metaHold.stop();
        } else if (snapTitle !== "" && rawTitle !== "" && rawTitle !== snapTitle
                   && isPlaying && rawLengthMs <= 0 && stickyLengthMs > 0) {
            heldTrack = { title: snapTitle, artist: snapArtist, album: snapAlbum, art: snapArt };
            metaHold.restart();
            console.log("[chorus] metadata without a length arrived mid-track (\"" + rawTitle
                        + "\"), holding \"" + snapTitle + "\" for now");
            return;
        }
        snapTitle = rawTitle;
        snapArtist = rawArtist;
        snapAlbum = rawAlbum;
        snapArt = rawArt;
    }

    readonly property string trackTitle:  heldTrack ? heldTrack.title  : rawTitle
    readonly property string trackArtist: heldTrack ? heldTrack.artist : rawArtist
    readonly property string trackAlbum:  heldTrack ? heldTrack.album  : rawAlbum
    readonly property url    artUrl:      heldTrack ? heldTrack.art    : rawArt
    readonly property string dispTitle:  optimistic ? optimistic.title  : trackTitle
    readonly property string dispArtist: optimistic ? optimistic.artist : trackArtist
    readonly property url    dispArt:    (optimistic && optimistic.art !== "") ? optimistic.art : artUrl
    readonly property double rawLengthMs: playerMatches && player.length ? player.length / 1000 : 0
    property double stickyLengthMs: 0
    readonly property double lengthMs: rawLengthMs > 0 ? rawLengthMs : stickyLengthMs
    onRawLengthMsChanged: {
        if (rawLengthMs > 0) stickyLengthMs = rawLengthMs;
        metaGate();
        safeCall(["updatePosition"]);
        if (trackTitle !== "" && (lyricsFetchTimer.running || (!haveSynced && !fetching)
                || (rawLengthMs > 0 && lastFetchedDurS === 0)
                || (rawLengthMs > 0 && lastFetchedDurS > 0 && Math.abs(Math.round(rawLengthMs / 1000) - lastFetchedDurS) > 2)))
            lyricsFetchTimer.restart();
    }
    readonly property double playRate:    (playerMatches && player.rate && player.rate > 0) ? player.rate : 1.0
    readonly property bool winVisible: Window.visibility !== Window.Hidden && Window.visibility !== 0

    property double posMs: 0
    property double posStamp: 0
    readonly property int lyricsOffsetMs: {
        var v = Number(Plasmoid.configuration.lyricsOffsetMs);
        return isNaN(v) ? 0 : v;
    }

    function rawNowMs() {
        return isPlaying ? posMs + (Date.now() - posStamp) * playRate : posMs;
    }
    function nowMs() { return rawNowMs() + lyricsOffsetMs; }

    property double lastReported: -1
    property double seekStamp: 0
    property double backProbeVal: -1
    property double backProbeAt: 0
    property int badReports: 0
    readonly property bool trustPos: badReports < 3
    Timer {
        id: posRecheck
        interval: 900
        repeat: false
        onTriggered: root.safeCall(["updatePosition"])
    }
    function startCalibration() {
        lastReported = -1;
        calibTimer.ticks = 0;
    }
    Timer {
        id: calibTimer
        interval: 150
        repeat: true
        property int ticks: 999
        running: root.isPlaying && root.winVisible && root.trustPos && ticks < 14
        onTriggered: {
            ticks++;
            root.safeCall(["updatePosition"]);
        }
    }

    Connections {
        target: root.player
        enabled: root.player !== null
        function onPositionChanged() {
            if (!root.trustPos) return;
            var reported = root.player.position / 1000;
            var predicted = root.rawNowMs();
            var diff = reported - predicted;
            if (root.seekStamp > 0) {
                var since = Date.now() - root.seekStamp;
                if (since < 2500) {
                    if (Math.abs(diff) > 1000) {
                        posRecheck.restart();
                        return;
                    }
                }
                root.seekStamp = 0;
            }
            if (root.isPlaying && calibTimer.ticks < 15 && Math.abs(diff) < 2000) {
                if (root.lastReported >= 0 && reported > root.lastReported
                        && reported - root.lastReported < 2000) {
                    root.posMs = reported;
                    root.posStamp = Date.now();
                    root.uiPosMs = root.nowMs();
                    calibTimer.ticks = 999;
                    root.lastReported = reported;
                    root.resync();
                    return;
                }
                if (root.lastReported < 0 && Math.abs(diff) >= 120 && reported >= 0
                        && !(reported < 2000 && predicted > 3000)) {
                    root.posMs = reported;
                    root.posStamp = Date.now();
                    root.uiPosMs = root.nowMs();
                    root.resync();
                }
                root.lastReported = reported;
                return;
            }
            root.lastReported = reported;
            if (root.isPlaying && Math.abs(diff) < 120) {
                return;
            }
            if (root.isPlaying && diff < -2000 && reported < 2000 && predicted > 3000) {
                if (root.backProbeVal >= 0 && Date.now() - root.backProbeAt > 600) {
                    var waited = (Date.now() - root.backProbeAt) * root.playRate;
                    var moved = reported - root.backProbeVal;
                    root.backProbeVal = -1;
                    if (moved < waited * 0.5) {
                        root.badReports++;
                        console.log("[chorus] player reports a stuck position near 0 ("
                                    + Math.round(reported) + "ms while playing "
                                    + Math.round(predicted) + "ms), keeping the local clock"
                                    + (root.trustPos ? "" : "; ignoring its position reports for this track"));
                        return;
                    }
                } else {
                    root.backProbeVal = reported;
                    root.backProbeAt = Date.now();
                    posRecheck.restart();
                    return;
                }
            } else {
                root.backProbeVal = -1;
            }
            root.badReports = 0;
            root.posMs = reported;
            root.posStamp = Date.now();
            root.uiPosMs = root.nowMs();
            root.resync();
            if (root.isPlaying) root.startCalibration();
        }
    }

    property var lines: []
    readonly property bool haveSynced: lines.length > 0
    property int lineIdx: -1
    property double curStart: 0
    property double curEnd: 0
    property double uiPosMs: 0
    property var cache: ({})
    property var cacheKeys: []
    property bool fetching: false
    property string spotifyTrackId: ""
    property int fetchGen: 0
    property int lastFetchedDurS: -1
    property string lastFetchedProvider: ""
    property string memMxmToken: ""
    readonly property string mxmUa: "Musixmatch/2024.06.01 (Android; 14)"
    readonly property string mxmCookieFile: "/tmp/chorus-mxm-cookies.txt"

    readonly property string lyricsProviderMode: Plasmoid.configuration.lyricsProvider || "auto"
    onLyricsProviderModeChanged: {
        if (lastFetchedProvider !== "" && lastFetchedProvider !== lyricsProviderMode && trackTitle !== "") {
            cache = ({});
            cacheKeys = [];
            lyricsFetchTimer.restart();
        }
    }
    readonly property string customMxmToken: (Plasmoid.configuration.musixmatchUserToken || "").trim()
    onCustomMxmTokenChanged: {
        if (lastFetchedProvider !== "" && lyricsProviderMode !== "lrclib" && trackTitle !== "") {
            cache = ({});
            cacheKeys = [];
            lyricsFetchTimer.restart();
        }
    }

    signal lyricsResynced()

    Timer {
        id: lyricsFetchTimer
        interval: 75
        repeat: false
        onTriggered: root.fetchLyrics()
    }

    readonly property string songKey: trackTitle + "\u0001" + trackArtist
    onSongKeyChanged: {
        fetchGen++;
        fetching = false;
        spotifyTrackId = "";
        lastFetchedDurS = -1;
        badReports = 0;
        backProbeVal = -1;
        stickyLengthMs = 0;
        if (trackTitle !== "") {
            if (pendingSpotifyTrack && pendingSpotifyTrack.title === trackTitle.trim().toLowerCase())
                spotifyTrackId = pendingSpotifyTrack.id;
            else
                pendingSpotifyTrack = null;
            optimistic = null;
            optimisticTimeout.stop();
        }
        lines = [];
        lineIdx = -1;
        if (trackTitle !== "") {
            posMs = 0;
            posStamp = Date.now();
            uiPosMs = 0;
            seekStamp = 0;
            lyricsFetchTimer.restart();
            startCalibration();
            safeCall(["updatePosition"]);
        } else {
            lyricsFetchTimer.stop();
            posMs = 0;
            uiPosMs = 0;
        }
    }

    function shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function encQ(s) {
        return encodeURIComponent(String(s || "")).replace(/'/g, "%27");
    }

    function httpGet(url, cb) {
        var xhr = new XMLHttpRequest();
        var done = false;
        function finish(ok, body) {
            if (done)
                return;
            done = true;
            cb(ok, body);
        }
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE)
                finish(xhr.status === 200, xhr.responseText);
        };
        xhr.timeout = 10000;
        xhr.ontimeout = function () { finish(false, ""); };
        xhr.open("GET", url);
        if (url.indexOf("lrclib.net") !== -1)
            xhr.setRequestHeader("Lrclib-Client", "Chorus/1.0 (Plasma widget)");
        xhr.send();
    }

    function curlGet(url, ua, cookieFile, cb) {
        var cmd = "curl -sL --max-time 8";
        if (ua && ua !== "") cmd += " -A " + shQuote(ua);
        if (cookieFile && cookieFile !== "")
            cmd += " -b " + shQuote(cookieFile) + " -c " + shQuote(cookieFile);
        cmd += " " + shQuote(url) + " 2>/dev/null";
        runCmdWatch(cmd, function (out) {
            if (out && out.trim() !== "") {
                cb(out);
                return;
            }
            httpGet(url, function (ok, body) {
                cb(ok ? (body || "") : "");
            });
        });
    }

    function rememberCache(key, val) {
        if (cache[key] === undefined) {
            cacheKeys.push(key);
            if (cacheKeys.length > 80) {
                var old = cacheKeys.shift();
                delete cache[old];
            }
        }
        cache[key] = val;
    }

    function ensureMxmToken(forceRefresh, cb) {
        var custom = (Plasmoid.configuration.musixmatchUserToken || "").trim();
        if (Lrc.isValidMxmToken(custom)) {
            cb(custom);
            return;
        }
        if (forceRefresh) {
            memMxmToken = "";
            Plasmoid.configuration.musixmatchAutoToken = "";
        } else {
            var cachedTok = (Plasmoid.configuration.musixmatchAutoToken || memMxmToken || "").trim();
            if (Lrc.isValidMxmToken(cachedTok)) {
                cb(cachedTok);
                return;
            }
        }
        var tokUrl = "https://apic.musixmatch.com/ws/1.1/token.get?app_id=android-player-v1.0&format=json";
        curlGet(tokUrl, mxmUa, mxmCookieFile, function (resp) {
            var tok = Lrc.parseMxmToken(resp);
            if (Lrc.isValidMxmToken(tok)) {
                root.memMxmToken = tok;
                Plasmoid.configuration.musixmatchAutoToken = tok;
                cb(tok);
            } else {
                cb("");
            }
        });
    }

    function fetchFromMusixmatch(key, gen, title, artist, album, durS, spId, retried, cb) {
        ensureMxmToken(retried, function (tok) {
            if (root.fetchGen !== gen || root.songKey !== key) return;
            if (!Lrc.isValidMxmToken(tok)) {
                cb(null);
                return;
            }
            var url = "https://apic.musixmatch.com/ws/1.1/macro.subtitles.get"
                    + "?format=json"
                    + "&namespace=lyrics_richsynched"
                    + "&subtitle_format=lrc"
                    + "&app_id=android-player-v1.0"
                    + "&optional_calls=track.richsync"
                    + "&q_track=" + encQ(title)
                    + "&q_artist=" + encQ(artist);
            if (album !== "") url += "&q_album=" + encQ(album);
            if (durS > 0) url += "&q_duration=" + durS + "&f_subtitle_length=" + durS + "&f_subtitle_length_max_deviation=15";
            if (spId !== "") url += "&track_spotify_id=" + encQ(spId);
            url += "&usertoken=" + encQ(tok);

            curlGet(url, root.mxmUa, root.mxmCookieFile, function (resp) {
                if (root.fetchGen !== gen || root.songKey !== key) return;
                var res = Lrc.parseMxmMacro(resp, title, durS);
                var hasCustom = Lrc.isValidMxmToken((Plasmoid.configuration.musixmatchUserToken || "").trim());
                if ((res.status === 401 || res.status === 402 || res.hint === "renew" || res.decoy)
                        && !retried && !hasCustom) {
                    root.fetchFromMusixmatch(key, gen, title, artist, album, durS, spId, true, cb);
                    return;
                }
                if (res.lrc) {
                    cb(res.lrc);
                    return;
                }
                var cTitle = Lrc.cleanTrackTitle(title);
                var pArtist = Lrc.primaryArtist(artist);
                var sUrl = "https://apic.musixmatch.com/ws/1.1/track.search"
                         + "?format=json"
                         + "&app_id=android-player-v1.0"
                         + "&f_has_subtitle=1"
                         + "&page_size=10"
                         + "&q_track=" + encQ(cTitle !== "" ? cTitle : title)
                         + "&q_artist=" + encQ(pArtist !== "" ? pArtist : artist)
                         + "&usertoken=" + encQ(tok);
                curlGet(sUrl, root.mxmUa, root.mxmCookieFile, function (resp2) {
                    if (root.fetchGen !== gen || root.songKey !== key) return;
                    var bestTrack = Lrc.pickBestMxmTrack(resp2, durS);
                    if (!bestTrack || !bestTrack.commontrack_id) {
                        cb(null);
                        return;
                    }
                    var subUrl = "https://apic.musixmatch.com/ws/1.1/track.subtitle.get"
                               + "?format=json"
                               + "&app_id=android-player-v1.0"
                               + "&subtitle_format=lrc"
                               + "&commontrack_id=" + encQ(bestTrack.commontrack_id)
                               + "&usertoken=" + encQ(tok);
                    curlGet(subUrl, root.mxmUa, root.mxmCookieFile, function (resp3) {
                        if (root.fetchGen !== gen || root.songKey !== key) return;
                        cb(Lrc.parseMxmSubtitle(resp3));
                    });
                });
            });
        });
    }

    function fetchFromLrclib(key, gen, title, artist, album, durS, cb) {
        var url = "https://lrclib.net/api/get?track_name=" + encQ(title)
                + "&artist_name=" + encQ(artist);
        if (album !== "") url += "&album_name=" + encQ(album);
        if (durS > 0) url += "&duration=" + durS;

        httpGet(url, function (ok, resp) {
            if (root.fetchGen !== gen || root.songKey !== key) return;
            var synced = null;
            if (ok) {
                try {
                    var obj = JSON.parse(resp);
                    if (obj && obj.syncedLyrics && Lrc.parse(obj.syncedLyrics).length > 0) {
                        var oDur = Number(obj.duration || 0);
                        if (durS <= 0 || oDur <= 0 || Math.abs(oDur - durS) <= 15)
                            synced = obj.syncedLyrics;
                    }
                } catch (e) {}
            }
            if (synced) {
                cb(synced);
                return;
            }
            var searchUrl = "https://lrclib.net/api/search?track_name=" + encQ(title)
                          + "&artist_name=" + encQ(artist);
            root.httpGet(searchUrl, function (ok2, resp2) {
                if (root.fetchGen !== gen || root.songKey !== key) return;
                var s2 = ok2 ? Lrc.pickBestLrclibSearch(resp2, title, artist, album, durS) : null;
                if (s2) {
                    cb(s2);
                    return;
                }
                var cTitle = Lrc.cleanTrackTitle(title);
                var pArtist = Lrc.primaryArtist(artist);
                if (cTitle === title && pArtist === artist) {
                    cb(null);
                    return;
                }
                var searchUrl2 = "https://lrclib.net/api/search?track_name=" + encQ(cTitle || title)
                               + "&artist_name=" + encQ(pArtist || artist);
                root.httpGet(searchUrl2, function (ok3, resp3) {
                    if (root.fetchGen !== gen || root.songKey !== key) return;
                    var s3 = ok3 ? Lrc.pickBestLrclibSearch(resp3, cTitle || title, pArtist || artist, album, durS) : null;
                    cb(s3);
                });
            });
        });
    }

    function fetchSpotifyTrackId(key, gen, cb) {
        if (spotifyTrackId !== "") {
            cb(spotifyTrackId);
            return;
        }
        if (!currentPlayerIs("spotify")) {
            cb("");
            return;
        }
        runCmdWatch("gdbus call --session --dest org.mpris.MediaPlayer2.spotify --object-path /org/mpris/MediaPlayer2 --method org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player Metadata 2>/dev/null",
            function (out) {
                if (root.fetchGen !== gen || root.songKey !== key) return;
                var id = Lrc.extractSpotifyTrackId(out);
                if (id !== "") root.spotifyTrackId = id;
                cb(id);
            });
    }

    function fetchLyrics() {
        var key = songKey;
        var title = trackTitle;
        var artist = trackArtist;
        var album = trackAlbum;
        if (title === "") {
            fetching = false;
            return;
        }
        pendingSpotifyTrack = null;
        var durS = lengthMs > 0 ? Math.round(lengthMs / 1000) : 0;
        lastFetchedDurS = durS;
        var provider = lyricsProviderMode;
        if (provider !== "auto" && provider !== "musixmatch" && provider !== "lrclib")
            provider = "auto";
        lastFetchedProvider = provider;

        var cKey = key + "\u0001" + durS;
        if (cache[cKey]) {
            fetching = false;
            applyLyrics(cache[cKey]);
            return;
        }

        var gen = ++fetchGen;
        fetching = true;

        function finish(lrc) {
            if (root.fetchGen !== gen || root.songKey !== key) return;
            root.fetching = false;
            if (lrc) root.rememberCache(cKey, lrc);
            root.applyLyrics(lrc);
        }

        if (provider === "lrclib") {
            fetchFromLrclib(key, gen, title, artist, album, durS, function (lrc1) {
                if (root.fetchGen !== gen || root.songKey !== key) return;
                if (lrc1) {
                    finish(lrc1);
                    return;
                }
                fetchSpotifyTrackId(key, gen, function (spId) {
                    if (root.fetchGen !== gen || root.songKey !== key) return;
                    fetchFromMusixmatch(key, gen, title, artist, album, durS, spId, false, finish);
                });
            });
        } else {
            fetchSpotifyTrackId(key, gen, function (spId) {
                if (root.fetchGen !== gen || root.songKey !== key) return;
                fetchFromMusixmatch(key, gen, title, artist, album, durS, spId, false, function (lrc1) {
                    if (root.fetchGen !== gen || root.songKey !== key) return;
                    if (lrc1) {
                        finish(lrc1);
                        return;
                    }
                    fetchFromLrclib(key, gen, title, artist, album, durS, finish);
                });
            });
        }
    }

    function applyLyrics(lrc) {
        lines = lrc ? Lrc.parse(lrc) : [];
        resync();
        safeCall(["updatePosition"]);
        if (isPlaying) startCalibration();
    }

    function resync() {
        uiPosMs = nowMs();
        if (!haveSynced) {
            lineIdx = -1;
            lineTimer.stop();
            lyricsResynced();
            return;
        }
        var t = nowMs();
        var idx = Lrc.indexFor(lines, t);
        curStart = idx >= 0 ? lines[idx].t : 0;
        curEnd = (idx + 1 < lines.length) ? lines[idx + 1].t
                                          : Math.max(curStart + 5000, lengthMs);
        if (curEnd <= curStart) curEnd = curStart + 1000;
        lineIdx = idx;
        lineTimer.stop();
        if (isPlaying && winVisible && idx + 1 < lines.length) {
            lineTimer.interval = Math.max(30, (lines[idx + 1].t - t) / playRate);
            lineTimer.start();
        }
        lyricsResynced();
    }

    Timer {
        id: lineTimer
        repeat: false
        onTriggered: root.resync()
    }

    Timer {
        id: driftTimer
        interval: 1500
        repeat: true
        running: root.isPlaying && root.winVisible && root.trustPos
        onTriggered: root.safeCall(["updatePosition"])
    }

    onWinVisibleChanged: {
        if (winVisible && isActive) {
            safeCall(["updatePosition"]);
            resync();
        } else {
            lineTimer.stop();
        }
    }
    onIsPlayingChanged: {
        if (!isPlaying) {
            posMs = posMs + (Date.now() - posStamp) * playRate;
        }
        posStamp = Date.now();
        safeCall(["updatePosition"]);
        resync();
    }

    function safeCall(names, arg) {
        if (!player) return false;
        for (var i = 0; i < names.length; i++) {
            var n = names[i];
            try {
                if (typeof player[n] === "function") {
                    arg === undefined ? player[n]() : player[n](arg);
                    return true;
                }
            } catch (e) {}
        }
        return false;
    }
    function doPlayPause() { safeCall(["PlayPause", "playPause"]); }
    function doNext()      { safeCall(["Next", "next"]); }
    function doPrev()      { safeCall(["Previous", "previous"]); }
    function doRaise() {
        safeCall(["Raise", "raise"]);
        if (pearIsCurrent || (pear !== null && !player)) pear.launchApp();
    }
    property bool volumeWorks: true
    property double volProbeTarget: -1
    property var volBroken: ({})
    readonly property bool canSetVolume: playerMatches && player.volume !== undefined && volumeWorks
    function volKeyFor(p) {
        if (!p) return "";
        return String(p.identity || "") + "|" + String(p.desktopEntry || "");
    }
    onPlayerChanged: {
        volProbe.stop();
        volProbeTarget = -1;
        volumeWorks = volBroken[volKeyFor(player)] !== true;
        badReports = 0;
        backProbeVal = -1;
        heldTrack = null;
        metaHold.stop();
        stickyLengthMs = 0;
        pendingSeekUs = -1;
        seekWrite.stop();
        metaGate();
    }
    Timer {
        id: volProbe
        interval: 900
        repeat: false
        onTriggered: {
            if (!root.player || root.volProbeTarget < 0) return;
            var cur = root.player.volume;
            root.volumeWorks = cur !== undefined && Math.abs(cur - root.volProbeTarget) < 0.02;
            root.volProbeTarget = -1;
            if (!root.volumeWorks) {
                root.volBroken[root.volKeyFor(root.player)] = true;
                console.log("[chorus] " + (root.player.identity || "player")
                            + " ignores volume writes, disabling volume control for it");
            }
        }
    }

    function setVol01(v) {
        if (!player || !volumeWorks) return;
        v = Math.max(0, Math.min(1, v));
        volProbeTarget = v;
        volProbe.restart();
        try {
            player.volume = v;
        } catch (e) {
            volProbe.stop();
            volProbeTarget = -1;
            volumeWorks = false;
            volBroken[volKeyFor(player)] = true;
        }
    }
    function changeVol(deltaPct) {
        if (!canSetVolume) return;
        var curPct = Math.round((player.volume || 0) * 100);
        var snapped = Math.round(curPct / 5) * 5;
        setVol01(Math.max(0, Math.min(100, snapped + deltaPct)) / 100);
    }
    property double pendingSeekUs: -1
    Timer {
        id: seekWrite
        interval: 100
        repeat: false
        onTriggered: {
            var us = root.pendingSeekUs;
            root.pendingSeekUs = -1;
            if (us < 0 || !root.player) return;
            var ok = true;
            try { root.player.position = us; } catch (e) { ok = false; }
            if (!ok) root.safeCall(["Seek", "seek"], us - Math.round(root.rawNowMs() * 1000));
        }
    }
    function seekToMs(ms) {
        if (!player || !player.canSeek) return;
        var target = Math.max(0, lengthMs > 0 ? Math.min(ms, lengthMs) : ms);
        pendingSeekUs = Math.round(target * 1000);
        seekWrite.restart();
        seekStamp = Date.now();
        posMs = target;
        posStamp = Date.now();
        uiPosMs = nowMs();
        resync();
        if (isPlaying) startCalibration();
    }

    readonly property string searchMode: {
        var m = Plasmoid.configuration.searchMode;
        if (m === "pear" || m === "spotify" || m === "none" || m === "auto") return m;
        var legacy = Plasmoid.configuration.appMode;
        return (legacy === "pear" || legacy === "spotify") ? legacy : "none";
    }
    property string autoLastProvider: "none"
    readonly property string searchProvider: {
        if (searchMode !== "auto") return searchMode;
        var spotifyUsable = (Plasmoid.configuration.spotifyClientId || "").trim() !== ""
                         && (Plasmoid.configuration.spotifyClientSecret || "").trim() !== "";
        if (spotifyUsable && currentPlayerIs("spotify")) return "spotify";
        if (currentPlayerIs("youtube")) return "pear";
        if (player && isActive) return "none";
        if (spotifyUsable && appRunning("spotify")) return "spotify";
        if (appRunning("youtube")) return "pear";
        return autoLastProvider;
    }
    onSearchProviderChanged: {
        if (searchMode === "auto"
                && (searchProvider === "pear" || searchProvider === "spotify"))
            autoLastProvider = searchProvider;
    }

    readonly property string searchAppToken:
        searchProvider === "pear" ? "youtube" : searchProvider === "spotify" ? "spotify" : ""
    readonly property bool searchAppRunning: appRunning(searchAppToken)
    readonly property string searchAppName:
        searchProvider === "pear" ? i18n("YouTube Music") : searchProvider === "spotify" ? i18n("Spotify") : ""
    readonly property var searchApi: pear !== null ? pear : spotifyApi
    readonly property bool showAppButton: searchApi !== null && !(searchProvider === "pear"
        ? Plasmoid.configuration.pearHideAppButton
        : Plasmoid.configuration.spotifyHideAppButton)

    readonly property bool pearMode: searchProvider === "pear"
    Loader {
        id: pearLoader
        active: root.pearMode
        source: "pear/PearApi.qml"
    }
    readonly property var pear: pearLoader.item
    readonly property bool pearIsCurrent: pear !== null && playerMatches
                                          && currentPlayerIs("youtube")
    readonly property bool spotifyMode: searchProvider === "spotify"
    Loader {
        id: spotifyApiLoader
        active: root.spotifyMode
        source: "spotify/SpotifyApi.qml"
    }

    readonly property var spotifyApi: spotifyApiLoader.item

    function showOptimistic(o) {
        optimistic = o;
        optimisticTimeout.restart();
        pendingSpotifyTrack = (o && o.id)
            ? { id: String(o.id), title: String(o.title || "").trim().toLowerCase() }
            : null;
    }
    function settleOptimistic() { optSettle.restart(); }
    function runCmd(sh) { exec.connectSource(sh); }
    property int cmdSeq: 0
    property var cmdCallbacks: ({})
    function runCmdWatch(sh, cb) {
        var key = sh + " # " + (++cmdSeq);
        cmdCallbacks[key] = cb;
        exec.connectSource(key);
    }

    readonly property bool shuffleOn: pearIsCurrent ? pear.shuffleOn : false
    readonly property string repeatMode: pearIsCurrent ? pear.repeatMode : "NONE"
    function doShuffle() {
        if (pearIsCurrent) pear.doShuffle();
        else mprisShuffle();
    }

    function doLoop() {
        if (pearIsCurrent) pear.doLoop();
        else mprisLoop();
    }

    function mprisShuffle() {
        if (!player) return;
        try {
            player.shuffle = (player.shuffle === Mpris.ShuffleStatus.On)
                           ? Mpris.ShuffleStatus.Off : Mpris.ShuffleStatus.On;
        } catch (e) {}
    }

    function mprisLoop() {
        if (!player) return;
        var cur = player.loopStatus;
        var next = cur === Mpris.LoopStatus.Playlist ? Mpris.LoopStatus.Track
                 : cur === Mpris.LoopStatus.Track ? Mpris.LoopStatus.None
                 : Mpris.LoopStatus.Playlist;
        try { player.loopStatus = next; } catch (e) {}
    }
    readonly property bool canShuffle: pearIsCurrent
        || (playerMatches && player.shuffle !== Mpris.ShuffleStatus.Unknown)
    readonly property bool canLoop: pearIsCurrent
        || (playerMatches && player.loopStatus !== Mpris.LoopStatus.Unknown)

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (sourceName, data) {
            disconnectSource(sourceName);
            var cb = root.cmdCallbacks[sourceName];
            if (cb) {
                delete root.cmdCallbacks[sourceName];
                cb(data["stdout"] || "");
            }
        }
    }

    property string lastAppliedMode: ""
    function applyPanelMode(idle) {
        if (!Plasmoid.configuration.managePanel) return;
        var mode = idle ? Plasmoid.configuration.idleMode : Plasmoid.configuration.activeMode;
        if (["autohide", "dodgewindows", "windowsgobelow", "normal"].indexOf(mode) === -1) return;
        if (mode === lastAppliedMode || mode === "") return;
        lastAppliedMode = mode;
        var script = 'panels().forEach(function(p){var ws=p.widgets();for(var i=0;i<ws.length;i++){if(ws[i].type=="' + Plasmoid.metaData.pluginId + '"){p.hiding="' + mode + '";}}});';
        exec.connectSource("gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript '" + script + "'");
    }

    Timer {
        id: idleDebounce
        interval: 4000
        repeat: false
        onTriggered: root.applyPanelMode(true)
    }
    onIsActiveChanged: {
        if (isActive) {
            idleDebounce.stop();
            applyPanelMode(false);
        } else {
            idleDebounce.restart();
        }
    }
    Component.onCompleted: {
        if (isActive) applyPanelMode(false);
        else idleDebounce.restart();
    }

    Plasmoid.status: isActive ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    Plasmoid.backgroundHints: PlasmaCore.Types.ShadowBackground | PlasmaCore.Types.ConfigurableBackground
    toolTipMainText: ""
    toolTipSubText: ""
    toolTipTextFormat: Text.PlainText
    hideOnWindowDeactivate: true

    readonly property var fontSources: {
        if (!Plasmoid.configuration.useCustomFont) return [];
        var out = [];
        var all = [String(Plasmoid.configuration.fontPath || "")]
            .concat(Plasmoid.configuration.fontFallbacks || []);
        for (var i = 0; i < all.length; i++) {
            var p = String(all[i] || "").trim();
            if (p !== "" && out.indexOf(p) < 0) out.push(p);
        }
        return out;
    }

    Instantiator {
        id: fontLoaders
        model: root.fontSources
        delegate: FontLoader {
            source: modelData.indexOf("file:") === 0 ? modelData : "file://" + modelData
            onStatusChanged: root.syncFontFamilies()
        }
        onObjectAdded: root.syncFontFamilies()
        onObjectRemoved: root.syncFontFamilies()
    }

    property var loadedFamilies: []
    function syncFontFamilies() {
        var out = [];
        for (var i = 0; i < fontLoaders.count; i++) {
            var l = fontLoaders.objectAt(i);
            if (l && l.status === FontLoader.Ready && l.name !== "" && out.indexOf(l.name) < 0)
                out.push(l.name);
        }
        loadedFamilies = out;
    }

    readonly property string cfgFont: loadedFamilies.length > 0
        ? loadedFamilies[0]
        : Kirigami.Theme.defaultFont.family
    readonly property string cfgFontCss: {
        if (loadedFamilies.length < 2) return "";
        var out = [];
        var all = loadedFamilies.concat([Kirigami.Theme.defaultFont.family]);
        for (var i = 0; i < all.length; i++) {
            var f = String(all[i]).replace(/["'\\<>;{}]/g, "").trim();
            if (f !== "") out.push("'" + f + "'");
        }
        return out.join(", ");
    }
    readonly property color cActive: Plasmoid.configuration.activeColor
    readonly property color cInactive: Qt.alpha(cActive, 0.55)

    compactRepresentation: Item {
        id: bar

        property bool activeSticky: false
        function hideExpandedLine() {
            var p = bar.parent;
            while (p) {
                if (p.expandedFeedback !== undefined && p.expandedFeedback !== null) {
                    var fb = p.expandedFeedback;
                    fb.visible = false;
                    fb.opacity = 0;
                    fb.imagePath = "";
                    break;
                }
                p = p.parent;
            }
        }
        onParentChanged: hideExpandedLine()
        Component.onCompleted: {
            activeSticky = root.isActive;
            hideExpandedLine();
        }
        Timer {
            id: idleDelay
            interval: 2500
            repeat: false
            onTriggered: bar.activeSticky = false
        }
        Connections {
            target: root
            function onExpandedChanged() { bar.hideExpandedLine(); }
            function onIsActiveChanged() {
                if (root.isActive) {
                    idleDelay.stop();
                    bar.activeSticky = true;
                } else if (bar.activeSticky) {
                    idleDelay.restart();
                }
            }
        }
        readonly property bool shown: activeSticky || !Plasmoid.configuration.hideWhenIdle
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property real thick: vertical ? width : height
        readonly property real screenLen: vertical ? Screen.height : Screen.width
        readonly property real pad: Kirigami.Units.smallSpacing
        readonly property real coverSize: Math.round(thick * 0.80)
        readonly property real minTotalW: screenLen * Plasmoid.configuration.minFrac
        readonly property real lyricsMaxW: Math.max(80, screenLen * Plasmoid.configuration.maxFrac
                                                    - coverSize - buttonsRow.width - 8 * pad)
        readonly property int lyricPx: Math.max(10, Math.round(thick * 0.46 * Plasmoid.configuration.fontScale))

        readonly property real liveLen: shown ? Math.max(row.implicitWidth, minTotalW) : 0
        property real frozenLen: 0
        property real frozenViewportW: Number.POSITIVE_INFINITY
        readonly property bool hold: root.expanded || barHover.hovered
        readonly property real contentLen: hold ? Math.max(frozenLen, liveLen) : liveLen
        function captureFrozen() {
            var fixedW = row.implicitWidth - viewport.Layout.preferredWidth;
            var uncappedVw = Math.min(curText.implicitWidth + 2, lyricsMaxW);
            frozenLen = shown ? Math.max(fixedW + uncappedVw, minTotalW) : 0;
            frozenViewportW = Math.max(0, frozenLen - fixedW);
        }
        onHoldChanged: {
            if (hold) {
                captureFrozen();
            } else {
                frozenLen = 0;
                frozenViewportW = Number.POSITIVE_INFINITY;
            }
        }
        onShownChanged: if (hold) captureFrozen()
        HoverHandler { id: barHover }
        Layout.preferredWidth: vertical ? -1 : contentLen
        Layout.minimumWidth: vertical ? 0 : contentLen
        Layout.maximumWidth: vertical ? Number.POSITIVE_INFINITY : contentLen
        Layout.preferredHeight: vertical ? contentLen : -1
        Layout.minimumHeight: vertical ? contentLen : 0
        Layout.maximumHeight: vertical ? contentLen : Number.POSITIVE_INFINITY
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
            onWheel: function (wheel) {
                if (!root.canSetVolume) return;
                root.changeVol(wheel.angleDelta.y > 0 ? 5 : -5);
                wheel.accepted = true;
            }
        }

        readonly property bool titleMode: root.optimistic !== null || !root.isPlaying || !root.haveSynced
                                          || root.lineIdx < 0 || root.lineIdx >= root.lines.length
        readonly property string displayText: {
            if (root.dispTitle === "") return i18n("Nothing playing");
            if (titleMode)
                return Lrc.normalize(root.dispTitle) + (root.dispArtist ? "  -  " + Lrc.normalize(root.dispArtist) : "");
            var t = root.lines[root.lineIdx].text;
            return t.length ? t : "♪";
        }

        onDisplayTextChanged: {
            lineSlide(displayText);
            marquee.reset();
        }
        function lineSlide(newText) {
            slideAnim.stop();
            var animate = shownOnce && newText !== "" && bar.shown && root.winVisible
                          && !titleMode && root.isPlaying;
            prevText.text = curText.text;
            curText.text = Lrc.fontSpan(newText, root.cfgFontCss);
            shownOnce = true;
            if (animate && prevText.text !== "") {
                prevText.opacity = 1;
                prevText.y = curText.yBase;
                curText.opacity = 0;
                curText.y = curText.yBase + bar.thick * 0.55;
                curText.color = root.cInactive;
                slideAnim.start();
            } else {
                prevText.opacity = 0;
                curText.opacity = 1;
                curText.y = Qt.binding(function () { return curText.yBase; });
                curText.color = Qt.binding(function () { return root.cActive; });
            }
        }
        property bool shownOnce: false
        Connections {
            target: root
            function onCfgFontCssChanged() {
                slideAnim.stop();
                prevText.text = "";
                prevText.opacity = 0;
                curText.opacity = 1;
                curText.text = Lrc.fontSpan(bar.displayText, root.cfgFontCss);
            }
        }
        onTitleModeChanged: if (titleMode) { slideAnim.stop(); curText.opacity = 1; curText.color = Qt.binding(function () { return root.cActive; }); curText.y = Qt.binding(function () { return curText.yBase; }); prevText.opacity = 0; }

        RowLayout {
            id: row
            width: bar.vertical ? bar.height : bar.width
            height: bar.vertical ? bar.width : bar.height
            anchors.centerIn: parent
            rotation: bar.vertical
                      ? (Plasmoid.location === PlasmaCore.Types.LeftEdge ? -90 : 90)
                      : 0
            spacing: bar.pad

            Item {
                id: coverBox
                visible: Plasmoid.configuration.showCover
                Layout.preferredWidth: bar.coverSize
                Layout.minimumWidth: bar.coverSize
                Layout.preferredHeight: bar.coverSize
                Layout.alignment: Qt.AlignVCenter

                CoverImage {
                    id: coverImg
                    anchors.fill: parent
                    src: root.dispArt
                    px: 128
                    radius: Math.max(3, bar.coverSize * 0.14)
                    visible: root.dispArt != "" && !coverImg.failed
                }
                Kirigami.Icon {
                    anchors.fill: parent
                    anchors.margins: 3
                    source: "media-album-cover"
                    color: root.cActive
                    visible: root.dispArt == "" || coverImg.failed
                    opacity: 0.6
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: bar.thick * 0.55
                Layout.alignment: Qt.AlignVCenter
                color: root.cActive
                opacity: 0.25
            }

            Item { Layout.fillWidth: true; Layout.preferredWidth: bar.pad }

            Item {
                id: viewport
                opacity: root.isActive || root.hasTrack ? 1.0 : 0.65
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredHeight: bar.thick
                Layout.preferredWidth: Math.min(curText.implicitWidth + 2, bar.lyricsMaxW, bar.frozenViewportW)
                clip: true

                Item {
                    id: content
                    height: parent.height
                    width: curText.implicitWidth

                    Text {
                        textFormat: root.cfgFontCss !== "" ? Text.RichText : Text.PlainText
                        id: prevText
                        readonly property real yBase: (content.height - height) / 2
                        y: yBase
                        opacity: 0
                        color: root.cActive
                        font.family: root.cfgFont
                        font.pixelSize: bar.lyricPx
                        font.weight: Font.DemiBold
                    }

                    Text {
                        textFormat: root.cfgFontCss !== "" ? Text.RichText : Text.PlainText
                        id: curText
                        readonly property real yBase: (content.height - height) / 2
                        y: yBase
                        text: Lrc.fontSpan(bar.displayText, root.cfgFontCss)
                        color: root.cActive
                        font.family: root.cfgFont
                        font.pixelSize: bar.lyricPx
                        font.weight: Font.DemiBold
                    }

                    ParallelAnimation {
                        id: slideAnim
                        NumberAnimation {
                            target: prevText; property: "y"
                            to: prevText.yBase - bar.thick * 0.55
                            duration: 380; easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: prevText; property: "opacity"
                            to: 0; duration: 300; easing.type: Easing.OutQuad
                        }
                        NumberAnimation {
                            target: curText; property: "y"
                            to: curText.yBase
                            duration: 380; easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: curText; property: "opacity"
                            to: 1; duration: 260; easing.type: Easing.OutQuad
                        }
                        ColorAnimation {
                            target: curText; property: "color"
                            to: root.cActive
                            duration: 420; easing.type: Easing.OutQuad
                        }
                    }

                    SequentialAnimation {
                        id: marqueeAnim
                        loops: Animation.Infinite
                        PauseAnimation { duration: 2000 }
                        NumberAnimation {
                            target: content; property: "x"
                            to: Math.min(0, viewport.width - content.width)
                            duration: Math.max(1000, (content.width - viewport.width) * 35)
                        }
                        PauseAnimation { duration: 2000 }
                        NumberAnimation { target: content; property: "x"; to: 0; duration: 600 }
                    }
                    function marqueeCheck() {
                        marqueeAnim.stop();
                        content.x = 0;
                        if (Plasmoid.configuration.marquee && root.winVisible && bar.shown
                                && (root.isPlaying || root.expanded)
                                && content.width > viewport.width + 1)
                            marqueeAnim.start();
                    }
                }
                QtObject {
                    id: marquee
                    function reset() { content.marqueeCheck(); }
                }
                onWidthChanged: content.marqueeCheck()
                Connections {
                    target: root
                    function onWinVisibleChanged() { content.marqueeCheck(); }
                    function onIsPlayingChanged() { content.marqueeCheck(); }
                    function onExpandedChanged() { content.marqueeCheck(); }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredWidth: bar.pad }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: bar.thick * 0.55
                Layout.alignment: Qt.AlignVCenter
                color: root.cActive
                opacity: 0.25
            }

            RowLayout {
                id: buttonsRow
                spacing: 0
                Layout.alignment: Qt.AlignVCenter
                Layout.minimumWidth: implicitWidth

                SkipButton {
                    forward: false
                    size: bar.thick * 0.9
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== "" && root.player.canGoPrevious
                    onClicked: root.doPrev()
                }
                PlayButton {
                    playing: root.isPlaying
                    size: bar.thick * 0.9
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== ""
                    onClicked: root.doPlayPause()
                }
                SkipButton {
                    forward: true
                    size: bar.thick * 0.9
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== "" && root.player.canGoNext
                    onClicked: root.doNext()
                }
            }
        }
    }

    fullRepresentation: Item {
        id: popup
        Layout.preferredWidth: Kirigami.Units.gridUnit * 17
        Layout.preferredHeight: mainCol.implicitHeight + Kirigami.Units.gridUnit * 2
        Layout.minimumWidth: Kirigami.Units.gridUnit * 15
        Layout.minimumHeight: Layout.preferredHeight
        Layout.maximumHeight: Layout.preferredHeight

        Timer {
            interval: 500
            repeat: true
            running: root.expanded && root.isPlaying
            onTriggered: {
                root.uiPosMs = root.nowMs();
                if (!root.haveSynced) root.safeCall(["updatePosition"]);
            }
        }

        function fmt(ms) {
            var s = Math.max(0, Math.round(ms / 1000));
            var m = Math.floor(s / 60);
            s = s % 60;
            return m + ":" + (s < 10 ? "0" : "") + s;
        }

        ColumnLayout {
            id: mainCol
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            spacing: Kirigami.Units.smallSpacing * 2

            // search box
            Loader {
                Layout.fillWidth: true
                active: root.pear !== null
                visible: active
                sourceComponent: SearchBox {
                    api: root.pear
                    placeholder: i18n("Search YouTube Music")
                }
            }
            Loader {
                Layout.fillWidth: true
                active: root.spotifyMode
                visible: active
                sourceComponent: SearchBox {
                    api: root.spotifyApi
                    placeholder: i18n("Search Spotify")
                }
            }

            // big cover
            Item {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Kirigami.Units.gridUnit * 11
                Layout.preferredHeight: Kirigami.Units.gridUnit * 11

                CoverImage {
                    id: bigCover
                    anchors.fill: parent
                    src: root.dispArt
                    px: 512
                    radius: 12
                    visible: root.dispArt != "" && !bigCover.failed
                }
                Kirigami.Icon {
                    anchors.fill: parent
                    source: "media-album-cover"
                    color: root.cActive
                    visible: root.dispArt == "" || bigCover.failed
                    opacity: 0.5
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.doRaise()
                    onWheel: function (wheel) {
                        if (!root.canSetVolume) return;
                        root.changeVol(wheel.angleDelta.y > 0 ? 5 : -5);
                        if (root.canSetVolume) volOverlay.show();
                        wheel.accepted = true;
                    }
                }
                Rectangle {
                    id: volOverlay
                    anchors.fill: parent
                    radius: 12
                    color: Qt.rgba(0.15, 0.15, 0.15, 0.72)
                    opacity: 0
                    function show() { opacity = 1; volHide.restart(); }
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    Text {
                        textFormat: Text.PlainText
                        id: volLabel
                        anchors.centerIn: parent
                        text: root.playerMatches && root.player.volume !== undefined
                              ? Math.round(root.player.volume * 100) + "%" : ""
                        color: root.cActive
                        font.family: root.cfgFont
                        font.pixelSize: Kirigami.Units.gridUnit * 2.4
                        font.weight: Font.DemiBold
                    }
                    Timer {
                        id: volHide
                        interval: 900
                        onTriggered: volOverlay.opacity = 0
                    }
                }
            }

            MarqueeText {
                Layout.fillWidth: true
                text: root.dispTitle !== "" ? Lrc.normalize(root.dispTitle) : i18n("Nothing playing")
                font.family: root.cfgFont
                fontCss: root.cfgFontCss
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                font.bold: true
                color: root.cActive
                scrolling: Plasmoid.configuration.marquee && root.expanded && root.winVisible
            }
            MarqueeText {
                Layout.fillWidth: true
                visible: root.isActive || root.optimistic !== null
                text: root.dispArtist !== "" ? Lrc.normalize(root.dispArtist) : " "
                color: root.cActive
                textOpacity: 0.7
                font.family: root.cfgFont
                fontCss: root.cfgFontCss
                scrolling: Plasmoid.configuration.marquee && root.expanded && root.winVisible
            }

            MarqueeText {
                Layout.fillWidth: true
                visible: root.isActive
                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                readonly property bool showLyric: root.haveSynced && root.lineIdx >= 0
                                                  && root.lineIdx < root.lines.length && root.isPlaying
                text: showLyric ? (root.lines[root.lineIdx].text || "♪")
                    : (root.isActive && !root.haveSynced && !root.fetching && !lyricsFetchTimer.running ? i18n("No synced lyrics found") : " ")
                font.family: root.cfgFont
                fontCss: root.cfgFontCss
                font.italic: showLyric
                font.pixelSize: showLyric ? Kirigami.Theme.defaultFont.pixelSize : Kirigami.Theme.smallFont.pixelSize
                color: root.cActive
                textOpacity: showLyric ? 0.9 : 0.5
                scrolling: Plasmoid.configuration.marquee && root.expanded && root.winVisible
            }

            // song progress bar
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                TextMetrics {
                    id: timeMetrics
                    font.family: root.cfgFont
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    text: popup.fmt(Math.max(root.lengthMs, root.uiPosMs)).replace(/[0-9]/g, "0")
                }

                PC3.Label {
                    textFormat: Text.PlainText
                    text: popup.fmt(root.isActive ? (seekBar.dragging ? seekBar.dragTargetMs : root.uiPosMs) : 0)
                    color: root.cActive
                    font.family: root.cfgFont
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    opacity: 0.7
                    horizontalAlignment: Text.AlignLeft
                    Layout.preferredWidth: Math.ceil(timeMetrics.width)
                    Layout.minimumWidth: Layout.preferredWidth
                }
                Item {
                    id: seekBar
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit
                    property bool dragging: false
                    property real dragRatio: 0
                    property real dragLenMs: 0
                    readonly property real dragTargetMs: dragRatio * (dragLenMs > 0 ? dragLenMs : root.lengthMs)
                    readonly property real ratio: !root.isActive || root.lengthMs <= 0 ? 0
                        : Math.max(0, Math.min(1, dragging ? dragRatio : root.uiPosMs / root.lengthMs))

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Qt.alpha(root.cInactive, 0.45)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: seekBar.ratio * parent.width
                        height: 4
                        radius: 2
                        color: root.cActive
                    }
                    Rectangle {
                        visible: root.isActive
                        anchors.verticalCenter: parent.verticalCenter
                        x: seekBar.ratio * (parent.width - width)
                        width: 12
                        height: 12
                        radius: 6
                        color: root.cActive
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.isActive && root.playerMatches && root.player.canSeek
                                 && root.lengthMs > 0
                        onPressed: function (mouse) {
                            seekBar.dragging = true;
                            seekBar.dragLenMs = root.lengthMs;
                            seekBar.dragRatio = Math.max(0, Math.min(1, mouse.x / width));
                        }
                        onPositionChanged: function (mouse) {
                            if (seekBar.dragging)
                                seekBar.dragRatio = Math.max(0, Math.min(1, mouse.x / width));
                        }
                        onReleased: {
                            var target = seekBar.dragTargetMs;
                            seekBar.dragging = false;
                            if (seekBar.dragLenMs <= 0 && root.lengthMs <= 0) return;
                            root.seekToMs(target);
                            root.uiPosMs = target;
                        }
                    }
                }
                PC3.Label {
                    textFormat: Text.PlainText
                    text: popup.fmt(root.isActive ? root.lengthMs : 0)
                    color: root.cActive
                    font.family: root.cfgFont
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    opacity: 0.7
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Math.ceil(timeMetrics.width)
                    Layout.minimumWidth: Layout.preferredWidth
                }
            }

            // control buttons
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Kirigami.Units.largeSpacing

                GlyphButton {
                    glyph: "shuffle"
                    size: Kirigami.Units.iconSizes.medium
                    glyphColor: root.cActive
                    active: root.shuffleOn
                        || (root.playerMatches && root.player.shuffle === Mpris.ShuffleStatus.On)
                    enabled: root.hasTrack && root.canShuffle
                    onClicked: root.doShuffle()
                }
                SkipButton {
                    forward: false
                    size: Kirigami.Units.iconSizes.medium
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== "" && root.player.canGoPrevious
                    onClicked: root.doPrev()
                }
                PlayButton {
                    playing: root.isPlaying
                    size: Kirigami.Units.iconSizes.medium
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== ""
                    onClicked: root.doPlayPause()
                }
                SkipButton {
                    forward: true
                    size: Kirigami.Units.iconSizes.medium
                    glyphColor: root.cActive
                    enabled: root.playerMatches && root.trackTitle !== "" && root.player.canGoNext
                    onClicked: root.doNext()
                }
                GlyphButton {
                    readonly property bool loopTrack: root.repeatMode === "ONE"
                        || (root.playerMatches && root.player.loopStatus === Mpris.LoopStatus.Track)
                    readonly property bool loopAny: root.repeatMode !== "NONE"
                        || (root.playerMatches
                            && (root.player.loopStatus === Mpris.LoopStatus.Playlist
                                || root.player.loopStatus === Mpris.LoopStatus.Track))
                    glyph: loopTrack ? "repeatOne" : "repeat"
                    size: Kirigami.Units.iconSizes.medium
                    glyphColor: root.cActive
                    active: loopAny
                    enabled: root.hasTrack && root.canLoop
                    onClicked: root.doLoop()
                }
            }

            // volume slider
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                Layout.rightMargin: Kirigami.Units.gridUnit * 2
                visible: Plasmoid.configuration.showVolumeBar && root.canSetVolume
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    readonly property real v: root.playerMatches && root.player.volume !== undefined ? root.player.volume : 0
                    source: v <= 0.001 ? "audio-volume-muted"
                          : v < 0.34 ? "audio-volume-low"
                          : v < 0.67 ? "audio-volume-medium" : "audio-volume-high"
                    color: root.cActive
                    opacity: 0.75
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                Item {
                    id: volBar
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 0.7
                    readonly property real ratio: root.playerMatches && root.player.volume !== undefined
                        ? Math.max(0, Math.min(1, root.player.volume)) : 0

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 3
                        radius: 1.5
                        color: Qt.alpha(root.cInactive, 0.4)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: volBar.ratio * parent.width
                        height: 3
                        radius: 1.5
                        color: Qt.alpha(root.cActive, 0.85)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        x: volBar.ratio * (parent.width - width)
                        width: 8
                        height: 8
                        radius: 4
                        color: root.cActive
                    }
                    MouseArea {
                        anchors.fill: parent
                        onPressed: function (mouse) { root.setVol01(mouse.x / width); }
                        onPositionChanged: function (mouse) { if (pressed) root.setVol01(mouse.x / width); }
                        onWheel: function (wheel) {
                            root.changeVol(wheel.angleDelta.y > 0 ? 5 : -5);
                            wheel.accepted = true;
                        }
                    }
                }
                PC3.Label {
                    textFormat: Text.PlainText
                    text: (root.playerMatches && root.player.volume !== undefined
                           ? Math.round(root.player.volume * 100) : 0) + "%"
                    color: root.cActive
                    font.family: root.cfgFont
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    opacity: 0.6
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
                }
            }

            // start stop buttons
            Loader {
                Layout.alignment: Qt.AlignHCenter
                active: root.showAppButton
                visible: active
                source: "AppButton.qml"
            }
        }
    }
}
