# Luka

Native macOS 26+ live captions, transcription and translation, powered by Soniox (`stt-rt-v5`).

## Setup

1. Create an API key at [console.soniox.com](https://console.soniox.com). Soniox bills per audio hour; see [soniox.com/pricing](https://soniox.com/pricing).
2. Open Luka and paste the key into the first window (or Settings › General). It is stored AES-GCM encrypted in `~/Library/Application Support/Luka/`, never sent anywhere but Soniox.
3. Press ⌃⌥N. macOS asks once for **System Audio Recording** (and **Microphone** if you pick it).

Luka talks to Soniox directly over WebSocket; there is no server in between.

## Install

| From | Steps |
|---|---|
| Source | `./scripts/build-app.sh --install` → `~/Applications/Luka.app` (Xcode 26, macOS 26+) |
| A release zip | Unzip and move `Luka.app` to Applications. Builds are ad-hoc signed, not notarized: open it once, then System Settings › Privacy & Security › **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Luka.app`. |

## Build

```sh
./scripts/build-app.sh            # → build/Luka.app
./scripts/build-app.sh --install  # → ~/Applications/Luka.app
./scripts/build-app.sh --zip      # → build/Luka-<version>.zip for a release
swift test                        # replays recorded Soniox streams
```

## Windows

| Window | Behavior |
|---|---|
| Captions | Borderless glass strip, non-activating, floats over full-screen apps. 1–6 lines, rolls up line by line, speaker name gutter. Hover for controls; when locked (click-through), hovering shows an Unlock pill. |
| Transcript | Sidebar of sessions by day (+ = new), editable title, turns grouped by speaker, Continue / Finish, edit mode, copy all, export, delete. |

Caption sizing: drag sides for width, top/bottom edge snaps to whole lines, bottom edge stays put when lines/size change, drops near screen center snap to center.

## Shortcuts

| From any app | |
|---|---|
| ⌃⌥N | New transcription (starts immediately) |
| ⌃⌥R | Start / Pause |
| ⌃⌥C | Show / hide captions |
| ⌃⌥T | Show / hide transcript |
| ⌃⌥L | Lock / unlock captions |

| In Luka | |
|---|---|
| ⌘R / ⌘. / ⌘N | Start-pause / Finish / New session |
| ⌘E | Name whoever is speaking |
| ⌘1 / ⌘2 | Captions / Transcript |
| ⌘+ ⌘− · ⌘↑ ⌘↓ | Text size · Caption lines |
| ⌥⌘O · ⌥⌘T | Show original · Keep captions on top |
| ⇧⌘C · ⌘S | Copy transcript · Export |

## Notes

| Topic | Fact |
|---|---|
| Audio | Mac audio via Core Audio process tap (System Audio Recording permission only), mic via AVAudioEngine, or both mixed; 16 kHz s16le, 100 ms chunks |
| Stream | One Soniox stream per session (limit 300 min); pause = finalize + keepalive, closes after 10 min idle; reconnects ×5 with recent text as context |
| Sessions | `~/Library/Application Support/Luka/Sessions/<uuid>.json`, autosaved every 5 s and on finish/quit; empty sessions are never written |
| Speakers | Labels are per stream (`epoch:label`); rename/recolor/merge apply to all past and future lines |
| Background | Menu bar app; Settings › Open at login, Show in Dock |
| UI language | English / 한국어 / 简体中文, switches live (`Support/Strings.swift`) |
| API key | AES-GCM file in `Application Support/Luka/credentials`, key = HKDF(hardware UUID, per-install salt); no Keychain; `SONIOX_API_KEY` env var as fallback |
| Debug flags | `--feed file.pcm` (16 kHz mono s16le, no permissions), `--autostart`, `--transcript`, `--snapshot dir` |

## License

MIT — see [LICENSE](LICENSE).
