# PalmTV — A Three-Edition Live TV Player

> **Desktop edition** (C# / WPF; **native LibVLC since v1.1.8**) + **HarmonyOS edition** (ArkTS / native AVPlayer)
> + **Android edition** (Kotlin / Jetpack Compose; **new in v1.2.0**)
>
> An engineering project that turns the whole chain of *channel list → stream resolution → decryption → playback*
> into a clean, long-running, uninterrupted player. The three editions share the same stream-orchestration
> approach and the same channel list, while using **completely different playback internals**.

---

## 📦 Download

The latest runnable builds are on the **Releases** page: <https://github.com/RickyOnes/PalmTV/releases/latest>

**Windows x64 desktop build** (unzip and run)

| Item | Value |
|---|---|
| Version | **v1.2.0** (2026-10-02) |
| Asset | `PalmTV-v1.2.0-win-x64.zip` |
| Size | 95.2 MB (99,832,618 bytes) |
| SHA-256 | `3B10911530A7BD4ED35D3DC9852C57370D7ED0A4552FDB876E0E517DF329449D` |
| Requirements | Windows 10 / 11 x64; **no WebView2 Runtime needed** (VLC is bundled) |
| How to run | Unzip anywhere → double-click `WinPalmTV.exe` |

**Android build** (install the APK directly — **the same package runs on phones and TVs**)

| Item | Value |
|---|---|
| Version | **v1.2.0** (2026-10-04) |
| Asset | `PalmTV-v1.2.0-android.apk` |
| Size | 16.5 MB (17,263,276 bytes) |
| SHA-256 | `16AAAA31BA49551BA90A823A997411D7B47C086C05974DCAE4FFCEABB2ABFAA9` |
| Requirements | **Android 7.0+**; installs on **phones, Android TV / TV boxes — including 32-bit TV systems** (the package ships `arm64-v8a` / `armeabi-v7a` / `x86_64`) |
| How to run | Download the APK → install (the system will ask to allow installing unknown apps) → open |

> **One package for phones and TVs**: on an Android TV / TV box it **switches to a remote-control UI**
> automatically — D-pad to move, OK to confirm, channel ± on the remote to zap, Back to exit; video on the left,
> channel list on the right. Phones keep the touch/gesture UI. Everything works the same on both; the only
> difference is that **editing custom IPTV sources is not available on TV** (typing with a remote is painful —
> edit on the phone or desktop edition; the m3u list format is shared). Also: **use your TV remote for volume** —
> the app has no in-app volume control, which is the convention for TV apps.
>
> How it works on TV: **a channel starts playing automatically on launch** (it resumes the last one watched,
> or CCTV-1 if there is no record); **8 seconds after the picture actually starts**, being idle **switches to
> fullscreen**; in fullscreen **OK exits fullscreen directly** and **Up / Down zap channels**, while the control
> bar auto-hides after 4 seconds (any D-pad key brings it back); **after leaving fullscreen, focus lands on the
> channel being played**; move focus to the "on now" strip and press OK for the **programme (EPG) popup**
> (D-pad to scroll, OK / Back to close); press the remote's **Menu** key to toggle an on-screen **diagnostics
> overlay** (resolve time / decryption rate / bitrate / buffer).

> The Android edition **ships as a package only**: its source code is not in this repository (see §1).

**HarmonyOS edition** — distributed through **Huawei AppGallery "internal testing"** (no offline package)

HarmonyOS packages must be signed and authorised by Huawei, so **a directly distributed file cannot be installed**.
That is why this edition is released through AppGallery's **internal testing** channel. If you would like to try it,
please **leave your Huawei account** (email is preferred: **162004332@qq.com**, subject "HarmonyOS internal test";
you can also open an issue in this repository to describe your need) and I will add it to the internal-testing list —
afterwards you will find and install the app under **AppGallery → Me → Internal testing**.

> ⚠️ **A Huawei account is personal information — please do not post it in a public issue or comment**;
> send it by email or direct message instead. You can also build it yourself in DevEco Studio (§4).

First-run notes:

- **The first launch takes a little longer** (a few seconds): the first run initialises the runtime and unpacks the
  bundled assets (channel logos, etc.) into a local cache. Later launches are fast; upgrading the app or unzipping
  it into a new folder makes one more launch slower.
- Logo cache, custom IPTV sources and the disclaimer state **survive upgrades**
  (`%LOCALAPPDATA%\WinPalmTV\` on the desktop edition, the app's own data directory on Android).
- Custom IPTV sources: About page → "Add / edit custom sources…" (on Android: "Technical notes" item 4 → "Add / edit").

---

## 🆕 Version evolution: v1.1.8 → v1.2.0 (this release)

| | **v1.1.8** (2026-09-30) | **v1.2.0** (2026-10-02) |
|---|---|---|
| Editions | Desktop + HarmonyOS | **Desktop + HarmonyOS + Android** |
| Android edition | — | **New**: Kotlin + Jetpack Compose UI, Media3 playback core; system media card (notification / lock screen / headset buttons); portrait channel wall and landscape fullscreen |
| **Android TV** | — | **The same Android package also supports Android TV / TV boxes** (auto-detected): a **remote-control UI** on TV — D-pad focus, OK to confirm, channel ± to zap, Back to exit; video left / channel list right; fullscreen control bar **auto-hides after 4 s** (any D-pad key brings it back); volume stays with the TV remote (no in-app volume) |
| App name / icon | Named separately per edition | Unified as "**掌上电视**" across all three editions, icons and credits aligned |
| Version number | 1.1.8 | Unified **1.2.0** across all three editions |
| Audio | HarmonyOS already mixed with other apps | **All three editions mix instead of taking exclusive focus**: playing this app no longer silences or interrupts other apps |
| Text-only logos | First character of the channel name | **Full channel name** (one shared sizing rule, up to two lines, then ellipsis) |
| Custom IPTV sources | Editable on desktop; added to the other editions later | One shared m3u format + **paste m3u text to import** + numbered list with click-to-edit + buttons colour-coded by role (primary / secondary / delete) + a receipt after every action |
| No-signal handling | Inconsistent timings across editions | Unified: 6 s source pre-check, 15 s without a picture marks a direct channel as no-signal; the fallback notice **names the channel the user actually picked** |
| Package size | Desktop 95.1 MB | Desktop **95.2 MB** / Android **16.0 MB** |

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

## 1. The source in this repo is a **v1.1.0-era public snapshot** (Android source is not included)

> ⚠️ Read this first: `desktop/`, `proxy/` and `harmony/` here are the **"application shell" snapshot from v1.1.0**
> (WebView2 + wasm architecture). It is **not the same implementation** as the 1.1.8 / 1.2.0 builds on the
> Releases page — the 1.1.8 native kernel (`PalmTVCore.dll`) and the related rewrites **are not synced here**.
>
> ★★ The **Android edition (new in v1.2.0) ships as a package only** — its source code is not in this repository.
> Treat this repo as a **client-architecture reference**, not as "clone and build 1.2.0".

|  | **Desktop** — `desktop/` (snapshot) | **HarmonyOS** — `harmony/` (snapshot) | **Android** — source not in this repo |
|---|---|---|---|
| Platform | Windows 10/11 (x64) | HarmonyOS NEXT | Android 7.0+ (phones / Android TV / TV boxes) |
| UI | C# / WPF | ArkTS / ArkUI | Kotlin / Jetpack Compose (remote-control UI on TV) |
| Playback core | Web player (`hls.js`) inside WebView2 | **Native AVPlayer** + `XComponent(SURFACE)` | **Media3 (ExoPlayer)** |
| Media processing | JavaScript inside the page | **Native N-API module** (`libcmg_napi.so`) | In-app native (JNI); the player fetches and decrypts on the fly |
| Local relay | Go reverse proxy on `127.0.0.1:18888` | ArkTS local HTTP service on `127.0.0.1:18899` | **None** (decryption happens in the data source layer; the player only sees playable data) |
| Request signing | `desktop/PlayerService.cs` | `harmony/.../common/NativeSigner.ets` | Same approach as desktop / HarmonyOS |
| Status | Works (bring your own components, see §5) | Works (same) | **Package only** (APK on the Releases page) |

**Shared capabilities in the current release (v1.2.0)**

- **79 live channels** built in (55 + 24 IPTV locals, extensible), channel grid with groups
- **EPG**: scrolling "now / next" in the status bar, full-day list in a popup
- **Gestures**: left half adjusts brightness, right half adjusts volume
- **Playback state machine**: first-play watchdog, error self-healing (re-resolve / rebuild player), zero rebuild in background
- **System media card** with title and artwork (native `AVSession` on HarmonyOS, a Media3 session on Android)
- **Audio**: mixed with other apps (never exclusive, never interrupting them)
- **Custom IPTV sources**: one shared m3u format, paste-to-import on every edition
- **Foreground/background policy**: no downloading or processing in background, resume on demand, stale-session recovery
- Keep-screen-on, mute/volume persistence, fullscreen and lock controls, prefetch on channel switch

---

## 2. Architecture (v1.1.0 snapshot)

All three editions follow one idea: **the player only ever sees data it can play directly.**

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
- **Android (v1.2.0)**: Media3 (ExoPlayer) plus a custom data source — decryption happens in the data source
  layer, so there is **no local relay service** (no `127.0.0.1` port as above). Its source code is not part of
  this repository; this line only describes where it sits in the architecture.

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

> The Android edition's source code is not in this repository, so there is no matching entry above
> (it ships as a package only).

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

> You do not need to build it just to *use* it: see the HarmonyOS note under "Download" above
> (leave a Huawei account and it will be added to the internal test).

1. Project Structure → Signing Configs → enable **Automatically generate signature**.
   Automatic signing only writes the `signingConfigs` array and does **not** add `products[*].signingConfig`
   (already added in this project).
2. Sync and Refresh Project → Build Hap(s); verify the artifact is `entry-default-signed.hap`.

### Android

The source is not part of this repository, so no build instructions are provided; a **ready-to-install package**
is published on the Releases page (see "Download" above).

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

> ★ Also note: the **1.1.8 / 1.2.0 native implementation is not in this repository either** — `PalmTVCore.dll`
> (CMG decryption kernel + signing/ticket/cKey), the VLC integration, the `logos.dat` logo-packing pipeline,
> and features such as custom IPTV sources / first-run disclaimer / About page have not been synced here.
>
> ★★ The **Android edition (new in v1.2.0) is not in this repository at all** — there is no `Android/` directory
> and no stream-resolution / decryption code for it. It is published as a **package (APK)** only.

---

## 6. Diagnostics

| Edition | Logs |
|---|---|
| Desktop | `player-debug.log` (page `postMessage`) and `proxy.log` (Go process) in the run directory |
| HarmonyOS | hilog; filter by tag in the DevEco Log window |
| Android | system log (`adb logcat`, filter by the app's package name) |

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
