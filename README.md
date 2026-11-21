# Chorus (Custom)

Forked from [Netherizzium/Chorus](https://github.com/Netherizzium/Chorus).

## Added Features

- **Custom Plasmoid ID (`net.netherizzium.chorus-custom`)**: Installs as **Chorus (Custom)** so KDE Store updates do not overwrite custom changes.
- **Musixmatch (Spotify Lyrics Provider) Integration**:
  - Fetches time-synced lyrics (LRC and richsync fallback) directly from Musixmatch using an automatically minted and cached user token.
  - Matches exact Spotify songs using the 22-character Spotify Track ID (`track_spotify_id`) from MPRIS metadata or in-widget Spotify playback, with fallback to Musixmatch `track.search` + `track.subtitle.get` and LRCLIB.
- **Improved MPRIS Metadata & LRCLIB Matching**:
  - Debounces MPRIS track-change signals (`75ms`) and resets cached track length on track switches so title, artist, album, and duration settle before fetching lyrics.
  - Scores LRCLIB search candidates by duration and album similarity to prevent matching wrong-duration versions (radio edits, extended mixes, live versions).
- **Tighter Playback Clock Synchronization**:
  - Starts position calibration immediately when playback begins and re-calibrates as soon as lyrics load.
  - Corrects initial playback offsets `>= 120ms` on the first MPRIS position report and lowers the ongoing drift deadband from `750ms` to `120ms` (`1500ms` drift check interval).
- **Lyrics Source Configuration** (*Music App* settings):
  - Added a **Lyrics source** selector (`Automatic (Spotify / Musixmatch, then LRCLIB)`, `Musixmatch (Spotify provider)`, or `LRCLIB`) and an optional custom Musixmatch token field.
- **Cleaner Panel Expansion**:
  - Removed the Plasma panel active-tab highlight line above the bar widget when opening the Chorus popup window.
- **Popup Album Cover Glow & Elevation**:
  - Added an ambient blurred album-art glow, soft drop shadow, subtle glass rim border, and gentle hover lift on the popup cover art.
