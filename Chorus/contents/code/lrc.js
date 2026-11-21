// LRC parsing + binary search helpers
.pragma library

// normalize typographic punctuation in CJK fonts. (basically i was testing the plugin with a zcool font and it had some weird artifacts and this was the fix to that, if youre not using a cjk font then dw bout it :v:)
function normalize(s) {
    if (!s) return s;
    return s
        .replace(/[\u2018\u2019\u02BC\u00B4\u0060]/g, "'")   // ‘ ’ ʼ ´ ` -> '
        .replace(/[\u201C\u201D\u201E]/g, '"')               // “ ” „ -> "
        .replace(/\u2026/g, "...")                            // … -> ...
        .replace(/[\u2013\u2014]/g, "-")                      // – — -> -
        .replace(/\u00A0/g, " ")                              // nbsp -> space
        .replace(/\u3000/g, " ");                             // fullwidth space
}

function parse(lrcText) {
    var lines = [];
    if (!lrcText) return lines;
    var re = /\[(\d+):(\d+(?:\.\d+)?)\]/g;
    var raw = lrcText.split(/\r?\n/);
    for (var i = 0; i < raw.length; i++) {
        var line = raw[i];
        var m, times = [], lastIdx = 0;
        re.lastIndex = 0;
        while ((m = re.exec(line)) !== null) {
            times.push((parseInt(m[1], 10) * 60 + parseFloat(m[2])) * 1000);
            lastIdx = re.lastIndex;
        }
        if (times.length === 0) continue;
        var text = normalize(line.slice(lastIdx).trim());
        for (var j = 0; j < times.length; j++)
            lines.push({ t: times[j], text: text });
    }
    lines.sort(function (a, b) { return a.t - b.t; });
    return lines;
}

function indexFor(lines, ms) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
        var mid = (lo + hi) >> 1;
        if (lines[mid].t <= ms) { ans = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return ans;
}

function escapeHtml(s) {
    return String(s)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function fontSpan(s, css) {
    if (!css || css === "") return s;
    return '<span style="font-family: ' + css + '; white-space: pre">'
           + escapeHtml(s) + '</span>';
}

function cleanTrackTitle(title) {
    if (!title) return "";
    var s = String(title).trim();
    s = s.replace(/\s*[\(\[]\s*(?:feat\.?|ft\.?|with|remaster(?:ed)?|live|acoustic|radio\s+edit|single\s+version|album\s+version|original\s+mix|deluxe|bonus\s+track|mono|stereo|\d{4}\s+remaster(?:ed)?)[^\)\]]*[\)\]]/gi, "");
    s = s.replace(/\s+-\s+(?:remaster(?:ed)?(?:\s+\d{4})?|\d{4}\s+remaster(?:ed)?|radio\s+edit|single\s+version|album\s+version|original\s+mix|acoustic(?:\s+version)?|live(?:\s+at\s+.*)?|mono|stereo|deluxe(?:\s+edition)?|feat\.?\s+.*|ft\.?\s+.*)$/i, "");
    s = s.replace(/\s{2,}/g, " ").trim();
    return s;
}

function primaryArtist(artist) {
    if (!artist) return "";
    var parts = String(artist).split(",");
    var first = (parts[0] || "").trim();
    return first !== "" ? first : String(artist).trim();
}

function extractSpotifyTrackId(metadataOutput) {
    if (!metadataOutput) return "";
    var m = /(?:\/com\/spotify\/track\/|spotify:track:|open\.spotify\.com\/track\/)([A-Za-z0-9]{22})/.exec(String(metadataOutput));
    return m ? m[1] : "";
}

function isValidMxmToken(t) {
    if (typeof t !== "string") return false;
    var s = t.trim();
    if (s === "" || s === "UpgradeOnly") return false;
    if (/^[0]+$/.test(s)) return false;
    return true;
}

function parseMxmToken(respText) {
    if (!respText) return "";
    try {
        var d = JSON.parse(respText);
        var tok = d && d.message && d.message.body && d.message.body.user_token;
        return isValidMxmToken(tok) ? tok.trim() : "";
    } catch (e) {
        return "";
    }
}

function pad2(n) {
    return n < 10 ? "0" + n : String(n);
}

function richsyncToLrc(richsyncBody) {
    if (!richsyncBody) return null;
    var arr = richsyncBody;
    if (typeof arr === "string") {
        try { arr = JSON.parse(arr); } catch (e) { return null; }
    }
    if (!Array.isArray(arr) || arr.length === 0) return null;
    var out = [];
    for (var i = 0; i < arr.length; i++) {
        var item = arr[i];
        if (!item || typeof item.ts !== "number") continue;
        var text = "";
        if (typeof item.x === "string") {
            text = item.x;
        } else if (Array.isArray(item.l)) {
            for (var j = 0; j < item.l.length; j++) {
                if (item.l[j] && typeof item.l[j].c === "string")
                    text += item.l[j].c;
            }
        }
        var csTotal = Math.max(0, Math.round(item.ts * 100));
        var mins = Math.floor(csTotal / 6000);
        var secs = Math.floor((csTotal % 6000) / 100);
        var cs = csTotal % 100;
        out.push("[" + pad2(mins) + ":" + pad2(secs) + "." + pad2(cs) + "] " + text.trim());
    }
    return out.length > 0 ? out.join("\n") : null;
}

function parseMxmMacro(respText, expectedTitle, durS) {
    var out = { status: 0, hint: "", lrc: null, decoy: false };
    if (!respText) return out;
    var d;
    try { d = JSON.parse(respText); } catch (e) { return out; }
    var msg = d && d.message;
    if (!msg) return out;
    if (msg.header) {
        out.status = Number(msg.header.status_code || 0);
        out.hint = String(msg.header.hint || "");
    }
    var calls = msg.body && msg.body.macro_calls;
    if (!calls) return out;

    var subCall = calls["track.subtitles.get"];
    var subHeader = subCall && subCall.message && subCall.message.header;
    if (subHeader) {
        var sc = Number(subHeader.status_code || 0);
        if (sc === 401 || sc === 402 || sc === 403) out.status = sc;
        if (subHeader.hint && out.hint === "") out.hint = String(subHeader.hint);
    }

    var matcherCall = calls["matcher.track.get"];
    var matchedTrack = matcherCall && matcherCall.message && matcherCall.message.body && matcherCall.message.body.track;
    if (matchedTrack) {
        var mName = String(matchedTrack.track_name || "");
        var expLower = String(expectedTitle || "").toLowerCase();
        if (mName.toUpperCase() === "NOKIA" && expLower.indexOf("nokia") === -1) {
            out.decoy = true;
            return out;
        }
        var mLen = Number(matchedTrack.track_length || 0);
        if (durS > 0 && mLen > 0 && Math.abs(mLen - durS) > 25) {
            return out;
        }
    }

    var subList = subCall && subCall.message && subCall.message.body && subCall.message.body.subtitle_list;
    if (Array.isArray(subList)) {
        for (var i = 0; i < subList.length; i++) {
            var sub = subList[i] && subList[i].subtitle;
            var body = sub && sub.subtitle_body;
            if (typeof body === "string" && body.trim() !== "" && parse(body).length > 0) {
                out.lrc = body;
                return out;
            }
        }
    }

    var richCall = calls["track.richsync.get"];
    var richObj = richCall && richCall.message && richCall.message.body && richCall.message.body.richsync;
    if (richObj && richObj.richsync_body) {
        var converted = richsyncToLrc(richObj.richsync_body);
        if (converted && parse(converted).length > 0) {
            out.lrc = converted;
            return out;
        }
    }
    return out;
}

function pickBestMxmTrack(respText, durS) {
    if (!respText) return null;
    var d;
    try { d = JSON.parse(respText); } catch (e) { return null; }
    var list = d && d.message && d.message.body && d.message.body.track_list;
    if (!Array.isArray(list) || list.length === 0) return null;

    var best = null;
    var bestDiff = 1e9;
    for (var i = 0; i < list.length; i++) {
        var t = (list[i] && list[i].track) ? list[i].track : list[i];
        if (!t || !t.commontrack_id) continue;
        if (!(t.has_subtitles === 1 || t.has_subtitles === true || t.has_richsync === 1 || t.has_richsync === true))
            continue;
        var len = Number(t.track_length || 0);
        if (durS > 0 && len > 0) {
            var diff = Math.abs(len - durS);
            if (diff > 20) continue;
            if (diff < bestDiff) {
                bestDiff = diff;
                best = t;
            }
        } else if (best === null) {
            best = t;
        }
    }
    return best;
}

function parseMxmSubtitle(respText) {
    if (!respText) return null;
    try {
        var d = JSON.parse(respText);
        var body = d && d.message && d.message.body && d.message.body.subtitle && d.message.body.subtitle.subtitle_body;
        if (typeof body === "string" && body.trim() !== "" && parse(body).length > 0)
            return body;
    } catch (e) {}
    return null;
}

function pickBestLrclibSearch(respText, expectedTitle, expectedArtist, expectedAlbum, durS) {
    if (!respText) return null;
    var arr;
    try { arr = JSON.parse(respText); } catch (e) { return null; }
    if (!Array.isArray(arr) || arr.length === 0) return null;

    var expTitle = String(expectedTitle || "").trim().toLowerCase();
    var expArtist = String(expectedArtist || "").trim().toLowerCase();
    var expAlbum = String(expectedAlbum || "").trim().toLowerCase();

    var hasCloseMatch = false;
    if (durS > 0) {
        for (var k = 0; k < arr.length; k++) {
            var it = arr[k];
            if (!it || !it.syncedLyrics || parse(it.syncedLyrics).length === 0) continue;
            var dSec = Number(it.duration || 0);
            if (dSec <= 0 || Math.abs(dSec - durS) <= 20) {
                hasCloseMatch = true;
                break;
            }
        }
    }

    var bestLyrics = null;
    var bestScore = -1e9;
    for (var i = 0; i < arr.length; i++) {
        var item = arr[i];
        if (!item || !item.syncedLyrics || parse(item.syncedLyrics).length === 0) continue;
        var itemDur = Number(item.duration || 0);
        if (durS > 0 && itemDur > 0 && Math.abs(itemDur - durS) > 20 && hasCloseMatch)
            continue;

        var score = 0;
        if (durS > 0 && itemDur > 0) {
            var diff = Math.abs(itemDur - durS);
            if (diff <= 3) score += 120 - diff * 5;
            else if (diff <= 10) score += 60 - diff * 3;
            else if (diff <= 20) score += 20 - diff;
            else score -= 100 + diff;
        }
        var tName = String(item.trackName || item.name || "").trim().toLowerCase();
        var aName = String(item.artistName || "").trim().toLowerCase();
        var alName = String(item.albumName || "").trim().toLowerCase();
        if (expTitle !== "" && tName === expTitle) score += 25;
        if (expArtist !== "" && aName === expArtist) score += 20;
        if (expAlbum !== "" && alName !== "" && (alName === expAlbum || alName.indexOf(expAlbum) !== -1 || expAlbum.indexOf(alName) !== -1))
            score += 30;

        if (score > bestScore) {
            bestScore = score;
            bestLyrics = item.syncedLyrics;
        }
    }
    return bestLyrics;
}
