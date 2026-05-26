# MenuBarSpotify

A tiny macOS menu-bar Spotify player.

## Motivation

I listen to songs, but Spotify is bloated.

This is enough:

- search songs
- browse playlists
- play through a menu-bar player
- seek, pause, skip, and resume
- show recent tracks in Search
- show lyrics when I want to jam

On my machine, this uses about **8x less RAM** than the full Spotify app. What more do I need?

## How It Works

The app uses Spotify's Web API for search, playlists, playback commands, and recently played tracks. Playback is handled by Spotify's Web Playback SDK inside a hidden `WKWebView`, so Spotify.app does not need to be open.

Lyrics come from LRCLIB and are cached in memory.

## Setup

Create `.config` in the project root:

```env
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SPOTIFY_REDIRECT_URI=spotify-menubar://callback
```

Add this redirect URI to your Spotify Developer Dashboard:

```text
spotify-menubar://callback
```

Run:

```bash
./script/build_and_run.sh
```

The app runs as a menu-bar-only macOS app.

## Resource Usage

A quick local snapshot (using RSS from `ps`, not a full Instruments benchmark) while `MenuBarSpotify` was playing and `Spotify.app` was open but idle:


| App                | Processes | RSS Memory | CPU                             |
| ------------------ | --------- | ---------- | ------------------------------- |
| **MenuBarSpotify** | 1         | ~129 MB    | ~1.4% - 5.6% (song was playing) |
| **Spotify.app**    | 7         | ~1.02 GB   | ~0.0% - 2.0%                    |


- **Memory Ratio**: ~7.9x less RAM (about **8x**).
- **Process Breakdown**: Spotify spawns 7 helper processes (main app, renderer, GPU, network, storage, crashpad, media/CDM). `MenuBarSpotify` runs entirely in a single process.
- **CPU**: `MenuBarSpotify` handles actual playback, so its CPU is slightly higher during active playing compared to an idle Spotify desktop app.

## Notes

- Spotify Premium is required for Web Playback SDK playback.
- The app stores local prototype tokens in `.config`.
- For a real distributable app, move token storage to Keychain and use PKCE.

