# PalmTV — A Cross-Platform Live TV Player

> **Desktop edition** (C# / WPF; **native LibVLC since v1.1.8**) + **HarmonyOS edition** (ArkTS / native AVPlayer)
>
> An engineering project that turns the whole chain of *channel list → stream resolution → local relay → playback*
> into a clean, long-running, uninterrupted player. The two editions share
> the same stream-orchestration approach while using **completely different playback internals**.

---

## 📦 Download (Windows x64 desktop build — unzip and run)

The latest runnable build is on the **Releases** page: <https://github.com/RickyOnes/PalmTV/releases/latest>

| Item | Value |
|---|---|
| Version | **v1.1.8** (2026-09-30) |
| Asset | `PalmTV-v1.1.8-win-x64.zip` |
| Size | 95.1 MB (99,757,878 bytes) |
| SHA-256 | `85EDBDCA5C29FB7AD3C84CF0F6FBE522B09136DDC671C77A2F93CF1BFF3F7934` |
| Requirements | Windows 10 / 11 x64; **no WebView2 Runtime needed** (VLC is bundled) |
| How to run | Unzip anywhere → double-click `WinPalmTV.exe` |

First-run notes:

- **The first launch takes a little longer** (a few seconds): the first run initialises the runtime and unpacks the
  bundled assets (channel logos, etc.) into a local cache. Later launches are fast; upgrading the app or unzipping
  it into a new folder makes one more launch slower.
- Logo cache, custom IPTV sources and the disclaimer state are stored in `%LOCALAPPDATA%\WinPalmTV\`
  and survive upgrades or moving the folder.
- Custom IPTV sources: About page → "Add / edit custom sources…".

---

## 🆕 Version evolution: v1.1.0 → v1.1.8 (build differences)

| | **v1.1.0** (2026-09-16) | **v1.1.8** (2026-09-30) |
|---|---|---|
| Desktop playback core | Web player (`hls.js`) inside WebView2 | **Native LibVLC** (bundled `libvlc\`, pruned plugins) |
| External dependency | System **WebView2 Runtime** | **None** (VLC ships in the archive) |
| Decryption | In-page wasm (`cmg.slim.js` / `hls.cmg.js` / `eb_prog.bin` / `reloc_table.bin`) | **Native C**: CMG kernel inside `PalmTVCore.dll` |
| Signing / ticket / cKey | Page JS + wasm + in-process V8 | **All native C** (inside `PalmTVCore.dll`; cKey = home-grown AES-128-CBC) |
| JS engine | ClearScript.V8 + page injection | **Removed entirely** (no JS engine, no injection) |
| Package entries | exe + `proxy.exe` + `player.served.html` + `sapi_cache\` (4 files) + icon | exe + `proxy.exe` + `PalmTVCore.dll` + `libvlc\` + `logos.dat` |
| Package size | 61.4 MB | **95.1 MB** |
| Channels | 55 | **79** = 55 + 24 IPTV locals (extensible) |
| Logos | Text-only tiles | **79 packed logos** (`logos.dat`, extracted to the user cache at runtime) |
| New capabilities | — | First-run disclaimer, About page, **custom IPTV sources**, stream pre-checks with no-signal fallback, EPG improvements |

**Why the package grew**: 1.1.8 replaced "system WebView2 + in-page JS" with a **bundled LibVLC** (`libvlc\`, ~22 MB).
In exchange you get **zero external dependencies** and an end to the whole "page not ready / injection failed" class of
failures; the 1.5 MB pre-baked player page and the four injected assets are gone as well.

---

## Disclaimer

- This project is for **technical research and client-architecture study** only. Users must comply with the laws of
  their jurisdiction and with the upstream platform's terms of service. It must not be used for infringing
  redistribution, commercial resale, or bypassing paid content.
- This repository contains **no copyrighted media**, and it does **not** ship every component required to build and
  run (see "5. What is not included").
- All icons in this repository are **hand-drawn placeholders** and are unrelated to any broadcaster.

---

## 1. The source in this repo is a **v1.1.0-era public snapshot**

> ⚠️ Read this first: `desktop/`, `proxy/` and `harmony/` here are the **"application shell" snapshot from v1.1.0**
> (WebView2 + wasm architecture). It is **not the same implementation** as the 1.1.8 build on the Releases page —
> the 1.1.8 native kernel (`PalmTVCore.dll`) and the related rewrites **are not synced into this repository**.
> Treat this repo as a **client-architecture reference**, not as "clone and build 1.1.8".

|  | **Desktop** — `desktop/` (snapshot) | **HarmonyOS** — `harmony/` |
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

## 2. Architecture (v1.1.0 snapshot)

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
  (★ 1.1.8 plays with native LibVLC instead — no player page, no injection; see "Version evolution" above.)
- **HarmonyOS**: native AVPlayer plus an ArkTS local service. Media processing happens in native code and is
  serialized on a worker thread, so the JS thread is never blocked.

---

## 3. Layout (v1.1.0 snapshot)

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

## 4. Build (v1.1.0 snapshot)

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
| Desktop ticket generation | local private script under `desktop/` (see `.gitignore`) | Plus `desktop/legacy/` (historical implementation) |
| Desktop local service | `proxy/main.go` | Go proxy and hosting logic |
| HarmonyOS native build script | `harmony/entry/src/main/cpp/CMakeLists.txt` | Produces `libcmg_napi.so` |
| HarmonyOS native kernel | — | Must implement every API declared in `index.d.ts` |
| HarmonyOS runtime assets | `harmony/entry/src/main/resources/rawfile/` | Files loaded at runtime |
| HarmonyOS signing | `harmony/.../common/ProxySigner.ets` | Request signing |
| HarmonyOS parameter generation | `harmony/.../common/ckey_core.ts` | See the placeholder note in `TvConfig.ets` |
| App identity config | `harmony/.../common/TvConfig.ets` | Repository ships **placeholder values** |

> All missing files are listed in `.gitignore`; they exist locally for development and are simply not distributed.

> ★ Also note: the **1.1.8 native implementation is not in this repository either** — `PalmTVCore.dll`
> (CMG decryption kernel + signing/ticket/cKey), the VLC integration, the `logos.dat` logo-packing pipeline,
> and features such as custom IPTV sources / first-run disclaimer / About page have not been synced here.

---

## 6. Diagnostics

| Edition | Logs |
|---|---|
| Desktop | `player-debug.log` (page `postMessage`) and `proxy.log` (Go process) in the run directory |
| HarmonyOS | hilog; filter by tag in the DevEco Log window |

Suggested order: verify the local service is listening → verify the player received a playlist → only then inspect
the media module's statistics.

> 1.1.8 is diagnosed differently: it uses native playback plus a native kernel, and logs come from
> `WinPalmTV.exe --log` (there is no page `postMessage` stage any more).

---

## 7. Contributing

1. After changing anything in `proxy/`, run `proxy/build.ps1` (it validates the JS).
   A bare `go build` skips validation; a syntax error breaks the whole page script and looks like
   "player failed to initialize".
2. When changing cached deployment artifacts on the HarmonyOS side, remember to bump the deploy version.
3. Before committing, make sure you did not add any component listed in §5.

## 8. License

See [LICENSE](./LICENSE).
