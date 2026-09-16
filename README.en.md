# PalmTV — A Cross-Platform Live TV Player

> **Desktop edition** (C# / WPF / WebView2) + **HarmonyOS edition** (ArkTS / native AVPlayer)
>
> An engineering project that turns the whole chain of *channel list → stream resolution → local relay → playback*
> into a clean, long-running, uninterrupted player. It never opens the upstream website, and the two editions share
> the same stream-orchestration approach while using **completely different playback internals**.

---

## Disclaimer

- This project is for **technical research and client-architecture study** only. Users must comply with the laws of
  their jurisdiction and with the upstream platform's terms of service. It must not be used for infringing
  redistribution, commercial resale, or bypassing paid content.
- This repository contains **no copyrighted media**, and it does **not** ship every component required to build and
  run (see "5. What is not included").
- All icons in this repository are **hand-drawn placeholders** and are unrelated to any broadcaster.

---

## 1. The two editions

|  | **Desktop** — `desktop/` | **HarmonyOS** — `harmony/` |
|---|---|---|
| Platform | Windows 10/11 (x64) | HarmonyOS NEXT |
| UI | C# / WPF | ArkTS / ArkUI |
| Playback core | Web player (`hls.js`) inside WebView2 | **Native AVPlayer** + `XComponent(SURFACE)` |
| Media processing | JavaScript inside the page | **Native N-API module** (`libcmg_napi.so`) |
| Local relay | Go reverse proxy on `127.0.0.1:18888` | ArkTS local HTTP service on `127.0.0.1:18899` |
| Request signing | `desktop/PlayerService.cs` | `harmony/.../common/NativeSigner.ets` |
| Status | Works (bring your own components, see §5) | Works (same) |

**Shared capabilities**

- **55 live channels** built in (including 4K / 8K slots), channel grid with groups
- **EPG**: scrolling "now / next" in the status bar, full-day list in a popup
- **Gestures**: left half adjusts brightness, right half adjusts volume
- **Playback state machine**: first-play watchdog, error self-healing (re-resolve / rebuild player), zero rebuild in background
- **System media card** with title and artwork (native `AVSession` on HarmonyOS)
- **Audio focus**: interruption handling for calls / other apps; focus released when backgrounded
- **Foreground/background policy**: no downloading or processing in background, resume on demand, stale-session recovery
- Keep-screen-on, mute/volume persistence, fullscreen and lock controls, prefetch on channel switch

---

## 2. Architecture

Both editions follow one idea: **the player only ever sees data it can play directly.**

```
       Upstream playlist (contains a one-shot token)
              │
              ├─(1) client resolves the channel → stream (auth → sign → sessionToken → playback URL)
              ▼
       ┌───────────────────────────────────────────────┐
       │  Player (web player / native AVPlayer)         │
       │        ▲                                       │
       │        │ clear segments                          │
       │  ┌─────┴─────────────────────────────────────┐ │
       └─►│ Local relay service (127.0.0.1)             │ │
          │  /local.m3u8 : fetch playlist, rewrite segs │ │
          │  /local-seg  : download → process → return  │ │
          └───────────────────┬───────────────────────┘ │
                              ▼                         │
                    Media module (not in this repo) ◄────┘
```

- **Desktop**: in-page web player plus a Go reverse proxy that serves the player page same-origin, forwards media
  requests, and backs the EPG / stream-resolution endpoints.
- **HarmonyOS**: native AVPlayer plus an ArkTS local service. Media processing happens in native code and is
  serialized on a worker thread, so the JS thread is never blocked.

---

## 3. Layout

```
PalmTV/
├─ desktop/                      Desktop edition (C# / WPF / WebView2)
│  ├─ PalmTV.Desktop.csproj      Self-contained single-file publish (win-x64)
│  ├─ App.xaml(.cs)
│  ├─ MainWindow.xaml(.cs)       Window / channel list / fullscreen / context menu / EPG
│  ├─ PlayerService.cs           Stream orchestration and request signing
│  ├─ publish.ps1                Publish script
│  └─ TV.png / tv-icon.ico       Hand-drawn placeholder icons
│
├─ proxy/                        Go local service (used by the desktop edition)
│  ├─ go.mod / go.sum
│  ├─ build.ps1                  Validate injected JS → go build → replace binary
│  └─ verify_inject.cjs          JS syntax check for the injected script
│
├─ harmony/                      HarmonyOS edition (ArkTS / native AVPlayer)
│  ├─ AppScope/                  App-level config and icons
│  ├─ build-profile.json5        Signing and product config
│  ├─ README.md                  HarmonyOS build notes
│  └─ entry/
│     ├─ build-profile.json5     externalNativeOptions
│     ├─ oh-package.json5        Local dependency: libcmg_napi.so
│     └─ src/main/
│        ├─ module.json5         Ability / permissions / background modes
│        ├─ ets/                 Player page, stream resolution, sessions, audio focus, local service
│        ├─ cpp/types/           TS declarations for the native module
│        └─ resources/           Strings / colors / placeholder icons
│
├─ README.md / README.en.md
└─ LICENSE
```

---

## 4. Build

### Desktop

**Requirements**: .NET 10 SDK, Go 1.2x, Node.js, WebView2 Runtime (end user)

```powershell
# 1) local service (always go through build.ps1 — it validates the injected JS first)
cd proxy; .\build.ps1

# 2) client
cd ..\desktop; dotnet build -c Debug

# 3) release (self-contained single file)
dotnet publish -c Release
```

> `dotnet build` is incremental and does **not** copy `player.html` (timestamp-based `PreserveNewest`);
> copy it manually after editing. `dotnet publish` is unaffected.
>
> Output directory: `desktop/bin/<Configuration>/net10.0-windows/win-x64/`.

### HarmonyOS

Open `harmony/` in DevEco Studio — see [`harmony/README.md`](./harmony/README.md).

1. Project Structure → Signing Configs → enable **Automatically generate signature**.
   Automatic signing only writes the `signingConfigs` array and does **not** add `products[*].signingConfig`
   (already added in this project).
2. Sync and Refresh Project → Build Hap(s); verify the artifact is `entry-default-signed.hap`.

---

## 5. What is not included

This repository is the **application shell**: it is readable and useful as a client-architecture reference, but it
**cannot be built or run as-is**. You need to supply the following:

| Component | Location | Notes |
|---|---|---|
| Desktop player page | `desktop/player.html` | Page-side media-request rewriting, playback control, injection |
| Desktop ticket generation | `desktop/gen_yspticket.cjs` | Plus `desktop/legacy/` (historical implementation) |
| Desktop local service | `proxy/main.go` | Go proxy and hosting logic |
| HarmonyOS native build script | `harmony/entry/src/main/cpp/CMakeLists.txt` | Produces `libcmg_napi.so` |
| HarmonyOS native kernel | — | Must implement every API declared in `index.d.ts` |
| HarmonyOS runtime assets | `harmony/entry/src/main/resources/rawfile/` | Files loaded at runtime |
| HarmonyOS signing | `harmony/.../common/ProxySigner.ets` | Request signing |
| HarmonyOS parameter generation | `harmony/.../common/ckey_core.ts` | See the placeholder note in `TvConfig.ets` |
| App identity config | `harmony/.../common/TvConfig.ets` | Repository ships **placeholder values** |

> All missing files are listed in `.gitignore`; they exist locally for development and are simply not distributed.

---

## 6. Diagnostics

| Edition | Logs |
|---|---|
| Desktop | `player-debug.log` (page `postMessage`) and `proxy.log` (Go process) in the run directory |
| HarmonyOS | hilog; filter by tag in the DevEco Log window |

Suggested order: verify the local service is listening → verify the player received a playlist → only then inspect
the media module's statistics.

---

## 7. Contributing

1. After changing anything in `proxy/`, run `proxy/build.ps1` (it validates the JS).
   A bare `go build` skips validation; a syntax error breaks the whole page script and looks like
   "player failed to initialize".
2. When changing cached deployment artifacts on the HarmonyOS side, remember to bump the deploy version.
3. Before committing, make sure you did not add any component listed in §5.

## 8. License

See [LICENSE](./LICENSE).
