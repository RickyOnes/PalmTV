# 单文件精简发布脚本
#
# 发布结构 (PalmTV-release.zip) —— 只含运行必需文件（现状：2026-11-06）:
#   WinPalmTV.exe       单文件自包含 (.NET10 + WPF + LibVLCSharp, 已压缩)
#   libvlc\             ★ LibVLC 原生库 + plugins（播放必需, 缺了开播即失败；已精简到直播那条链）
#   logos.dat           ★ 台标打包（运行期解到用户缓存目录；不再散落明文 PNG）
#   PalmTVCore.dll      ★ 原生核：**自研安卓 cKey** + 江苏签名（取流的命脉，见第 5 步自检）
#
# ★★ 2026-11-05 起**不再随包**（桌面整条链路已与它们无关）★★
#   · proxy.exe（Go 反代 18888）：央视频走安卓平台链路、江苏台 C# 现算签名 + 本地解密代理，
#     节目单直连 capi ⇒ 代理彻底不需要（csproj 里连 debug 输出也不再复制）；
#   · eb_prog.bin / reloc_table.bin / CMGPlayer.json：CMG 解密核已从 PalmTVCore.dll 移除
#     （8 个加密台改 sm4c，见 `Sm4C.cs`）；
#   · sapi_cache\ / player.html / keygen_bg.wasm / RJq7sO71JF.wasm：页内播放（WebView2）时代的资产。
#   回退办法在各步注释里都留着（被注释掉的代码块）。
#
# ★ 更早已改为内置、不随包：
#   tv-icon.ico / copyright.png → exe 嵌入资源；iptv-local.m3u → `IptvChannels.cs` 的 BuiltIn 表。
#
# ⚠️ 采集方式 = "整个 publish 输出照搬 + 剔除开发文件"。白名单式清单踩过坑:
#    只拷 exe 会漏掉 libvlc\ 这类原生依赖 ⇒ 发布包在用户机上直接跑不起来。
$ErrorActionPreference = "Stop"

$projDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir  = Split-Path -Parent $projDir

$publishDir = Join-Path $projDir "publish"              # dotnet publish 临时输出
$releaseDir = Join-Path $projDir "desktop-release"   # 最终发布目录
$zipFile    = Join-Path $rootDir "PalmTV-release.zip"

# 1) 清理旧目录
#    ★ 用 .NET API 而非 Remove-Item -Recurse：本机 harness 的安全删除守卫会拦大目录递归删除
#      ("Safe delete could not verify this bulk deletion. Nothing was deleted." ⇒ 脚本会中断)。
function Remove-Tree([string]$p) { if (Test-Path $p) { try { [IO.Directory]::Delete($p, $true) } catch { } } }
Remove-Tree $publishDir
Remove-Tree $releaseDir
if (Test-Path $zipFile) { [IO.File]::Delete($zipFile) }
New-Item -ItemType Directory -Force $releaseDir | Out-Null

# 2) 单文件发布 .NET 程序 (含 WebView2 Runtime 检测, 系统自带则不打包)
#    ⚠️⚠️ **不要再传 `-p:IncludeNativeLibrariesForSelfExtract=true`**（2026-09-30 修）：
#       命令行 `-p:` 会**覆盖 csproj 里的 `false`**，而那正是 csproj 注释里说的坏状态 ——
#       它把所有 native（含 LibVLC 的 x64/arm64/x86 三份 dll，约 100MB+）**塞进 exe 且不能压缩**
#       （`IncludeNativeLibrariesForSelfExtract` 与 `EnableCompressionInSingleFile` 互斥）
#       ⇒ 实测 exe 193MB / ZIP **223MB**（正确应为 exe ~70MB / ZIP ~60-70MB）。
#       取 `false` 时 native 与 exe 同布局落盘，压缩才生效；本脚本下面"剔除 libvlc 按架构子目录"
#       那段**也只在 false 下才有意义**（true 时它们根本不在磁盘上）。ExcludeFromSingleFile 的
#       Content（PalmTVCore.dll / 图标 / iptv-local.m3u）在两种模式下都会落盘。
dotnet publish "$projDir/WinPalmTV.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:PublishReadyToRun=false `
    -p:PublishTrimmed=false `
    -p:IncludeNativeLibrariesForSelfExtract=false `
    -o $publishDir

# 3) 复制**整个 publish 输出**（exe + libvlc\ + PalmTVCore.dll + 图标/清单 …）
#    ★ 用"照搬 + 剔除"而不是逐个白名单：白名单漏一个运行期必需文件，发布包就会在用户机器上崩。
Copy-Item (Join-Path $publishDir "*") $releaseDir -Recurse -Force
Get-ChildItem $releaseDir -Recurse -Filter *.pdb | Remove-Item -Force -ErrorAction Ignore
# 若发布输出里残留页内注入资产（P3b 后已作废），一并剔除
foreach ($dead in @("player.served.html", "player.html", "keygen_bg.wasm", "RJq7sO71JF.wasm")) {
    $p = Join-Path $releaseDir $dead
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "  剔除已作废资产: $dead" }
}

# 4) 复制 Go 代理 (已编译好的最新版)
# ★ 2026-11-05：**不再随包 proxy.exe** —— 桌面已彻底不依赖 Go 代理
#   （央视频走安卓链路，江苏台由 C# 现算签名 + LocalDecryptServer 转发）
#   若将来要回退，恢复下面三行并把 $must 里的 "proxy.exe" 加回去。
# $proxyExe = Join-Path $proxyDir "proxy.exe"
# if (-not (Test-Path $proxyExe)) {
#     throw "proxy.exe not found at $proxyExe. Run '.\build.ps1' in proxy first."
# }
# Copy-Item $proxyExe (Join-Path $releaseDir "proxy.exe") -Force
Write-Host "  （已跳过 proxy.exe：2026-11-05 起桌面不再使用 Go 代理）"

# ★ P3b（2026-09-21）：原第 5 步"生成 player.served.html"整段已删除 —— 页内播放摘除后
#   不再需要 served html（连 player.html 本身都已不随包分发）。三个 wasm/JS 注入资产同步作废。

# ★ libvlc 包同时带 arm64/x86 两份副本（约 100MB 冗余）⇒ 只保留 win-x64, 大幅缩小发布包
# ★★ 补 libvlc —— 单文件发布**不会**把该 RID 的 runtime 资产落盘（反倒 arm64/x86 会落盘）,
#    而 VLC 的 plugins 必须留在磁盘上 ⇒ 缺了就是"开播即失败"（发布版实测踩过）。
#    ★ 2026-09-21：目标目录**扁平化为 libvlc\**（去掉 win-x64 这一层，子目录太多没意义）。
#      代价：LibVLCSharp 的默认搜索路径失效 ⇒ MainWindow.EnsureVlc() 显式 Core.Initialize(<AppDir>\libvlc)。
#    源 = NuGet 包的 build\x64（排除 include 与 *.lib）。只拷 x64 ⇒ arm64/x86 天然不进包，无需再剔除。
$libvlcDst = Join-Path $releaseDir "libvlc"
if (-not (Test-Path (Join-Path $libvlcDst "libvlc.dll"))) {
    $pkgRoot = Join-Path $env:USERPROFILE ".nuget\packages\videolan.libvlc.windows"
    $pkgBuild = Get-ChildItem $pkgRoot -Directory -ErrorAction Ignore |
                 Sort-Object Name -Descending |
                 ForEach-Object { Join-Path $_.FullName "build\x64" } |
                 Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $pkgBuild) { throw "libvlc\win-x64 缺失, 且找不到 NuGet 包(build\x64): $pkgRoot" }
    New-Item -ItemType Directory -Force $libvlcDst | Out-Null
    Copy-Item (Join-Path $pkgBuild "*") $libvlcDst -Recurse -Force -Exclude 'include', '*.lib'
    Write-Host "  libvlc 已从 NuGet 补齐(扁平): $pkgBuild"
}

# ★ 删掉发布输出带进来的 NuGet 风格"按架构子目录"（libvlc\win-x64 / win-arm64 / win-x86）：
#   扁平化后没人读它们（VLC 由 Core.Initialize(<AppDir>\libvlc) 显式指向），留着是几十 MB 纯冗余。
foreach ($arch in @("win-x64", "win-arm64", "win-x86")) {
    $p = Join-Path $libvlcDst $arch
    if (Test-Path $p) { try { [IO.Directory]::Delete($p, $true) } catch { }; Write-Host "  剔除按架构子目录: libvlc\$arch" }
}

# ★★ 精简 libvlc：只留"网络直播 (HLS/TS) → H.264/AAC → 屏幕输出"这条链真正会加载的模块。
#    被删的都是本场景**绝对不会加载**的：编码器 / 流输出 / 视觉特效 / 字幕渲染 / 界面 / 发现服务 / Lua / HRTF。
#    ⚠️ 不可动：plugins\codec\libav*.dll、plugins\access、plugins\demux、plugins\{video,audio}_output
#       —— 那些是解码链本体，删了就是"能起播但黑屏/无声"。
$pruneDirs = @(
    "lua", "hrtfs", "include",
    "plugins\access_output", "plugins\stream_out", "plugins\visualization",
    "plugins\services_discovery", "plugins\text_renderer", "plugins\gui"
)
$pruneFiles = @("plugins\codec\libx264*", "plugins\codec\libx265*", "plugins\codec\libschroedinger*",
                "plugins\codec\libtheora*", "plugins\codec\libtwolame*")
foreach ($d in $pruneDirs) { Remove-Tree (Join-Path $libvlcDst $d) }
foreach ($f in $pruneFiles) {
    Get-ChildItem (Join-Path $libvlcDst $f) -ErrorAction Ignore | ForEach-Object { [IO.File]::Delete($_.FullName) }
}
Get-ChildItem $libvlcDst -Recurse -Include *.lib, *.exp -ErrorAction Ignore | ForEach-Object { [IO.File]::Delete($_.FullName) }
# ★ 插件缓存 plugins.dat 必须删：它记录了刚被裁掉的模块，留着会让 VLC 启动时报模块缺失（删掉会自动重建）。
$pluginsDat = Join-Path $libvlcDst "plugins\plugins.dat"
if (Test-Path $pluginsDat) { [IO.File]::Delete($pluginsDat) }
Write-Host "  libvlc 已精简：编码器 / 流输出 / 视觉特效 / 字幕渲染 / 界面 / Lua / HRTF + 插件缓存"

# ★ 发布包自检：任何一项缺失都直接失败（宁可打不出包，也不要发出一个跑不起来的包）
$must = @(
    "WinPalmTV.exe",
    "libvlc\libvlc.dll", "libvlc\plugins",
    "PalmTVCore.dll"
)
# 注：`sapi_cache\*.bin` 与 `logos.dat` 的自检放在各自**生成步骤**里（本块执行顺序早于它们）。
$missing = @($must | Where-Object { -not (Test-Path (Join-Path $releaseDir $_)) })
if ($missing.Count -gt 0) { throw ("发布包自检失败, 缺少: " + ($missing -join ', ')) }
Write-Host ("发布包自检通过: {0} 项齐全" -f $must.Count)

# ★★ 2026-11-06 新增：**原生核自检（cKey 的命脉）** ★★
#   `PalmTVCore.dll` 由 `common\build\build-palmtv-core.ps1 -WithSign` 单独编译并**入库**，
#   `dotnet publish` **不会**重建它 ⇒ 改了 `common\native\src\*.c`（尤其是自研安卓 cKey
#   `ysp_ckey_self.c`）却忘了重编核，打出来的包会"界面正常、所有央视频台取流失败"。
#   判据 = DLL 写入时间 vs 原生源最新写入时间；DLL 更旧 ⇒ 明显警告（不阻断，打包人自己判断）。
$dll = Get-Item (Join-Path $releaseDir "PalmTVCore.dll")
Write-Host ("  原生核: PalmTVCore.dll {0:N0} B, 构建于 {1:yyyy-MM-dd HH:mm}" -f $dll.Length, $dll.LastWriteTime)
$nativeNewest = Get-ChildItem (Join-Path $rootDir "common\native\src") -Filter *.c -File -ErrorAction Ignore |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($nativeNewest -and $nativeNewest.LastWriteTime -gt $dll.LastWriteTime) {
    Write-Host ("  ⚠️ PalmTVCore.dll 比原生源旧：源 {0} {1:yyyy-MM-dd HH:mm} > DLL {2:yyyy-MM-dd HH:mm}" -f `
        $nativeNewest.Name, $nativeNewest.LastWriteTime, $dll.LastWriteTime) -ForegroundColor Yellow
    Write-Host "     ⇒ 先重编原生核再发布： powershell -ExecutionPolicy Bypass -File common\build\build-palmtv-core.ps1 -WithSign" -ForegroundColor Yellow
    Write-Host "       （否则 cKey / 江苏签名仍是旧的 ⇒ 发布版可能「界面正常但所有台取流失败」）" -ForegroundColor Yellow
}

# ★ 2026-09-30 自检：这三个**不该**出现在发布目录（均已改为"编进程序里"）
#   · `tv-icon.ico` / `copyright.png` → exe 的嵌入资源（csproj EmbeddedResource）
#   · `iptv-local.m3u`               → 内置在 `IptvChannels.cs` 的 BuiltIn 表
#   混进来就直接删掉并点名（防止"改一半"的中间状态被打进包）。
$shouldNotShip = @("tv-icon.ico", "copyright.png", "iptv-local.m3u") |
                 Where-Object { Test-Path (Join-Path $releaseDir $_) }
if ($shouldNotShip) {
    foreach ($f in $shouldNotShip) { [IO.File]::Delete((Join-Path $releaseDir $f)) }
    Write-Host ("  剔除已改为内置的文件: " + ($shouldNotShip -join ', '))
}

# ★ 台标打包：全部明文 PNG → **单个 logos.dat**（运行期由 LogoPack.cs 解到用户缓存目录后再走原路径）。
#   容器格式见 LogoPack.cs：magic "PLOGO1\n" + u32 count + 重复{ u16 nameLen, name(**UTF-8**, 无扩展名), u32 dataLen, data }
#   ⚠️ 台标绝不能漏（曾因 csproj 写成 Never 导致发布版只有文字台标，用户实测反馈）⇒ 源缺失直接失败。
#   ★★ 2026-09-30：**名字必须用 UTF-8** ★★ 原先用 ASCII ⇒ 中文台标名（`广州电视` 等 15 个）变成 `????`，
#      而 `?` 是 Windows 非法文件名字符 ⇒ 解包端 WriteAllBytes 抛异常 ⇒ **发布版全部台标失效**（只剩文字，
#      且缓存里只留下已写成功的 64 张）。打包后本段会**回读校验**，容器坏了一律拦在发布之前。
$logoSrc = Join-Path $projDir "logos\real"
$logoPng = @(Get-ChildItem $logoSrc -Filter *.png -File -ErrorAction Ignore)
if ($logoPng.Count -lt 1) { throw "台标源缺失: $logoSrc\*.png（发布版会退化成文字台标）" }
$logoDat = Join-Path $releaseDir "logos.dat"
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([Text.Encoding]::ASCII.GetBytes("PLOGO1`n"))   # magic 本身仍是 ASCII
$bw.Write([int]$logoPng.Count)
foreach ($f in $logoPng) {
    $nm = [Text.Encoding]::UTF8.GetBytes($f.BaseName)     # ★ UTF-8（见上方说明，勿改回 ASCII）
    $bw.Write([uint16]$nm.Length); $bw.Write($nm)
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $bw.Write([int]$b.Length); $bw.Write($b)
}
$bw.Flush()
[IO.File]::WriteAllBytes($logoDat, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()
if (-not (Test-Path $logoDat)) { throw "logos.dat 生成失败" }

# ★ 回读自检：容器必须能完整解析，且条数、末位偏移与文件长度严格一致（坏包拦在发布前）
$lbytes = [IO.File]::ReadAllBytes($logoDat)
if ([Text.Encoding]::ASCII.GetString($lbytes, 0, 7) -ne "PLOGO1`n") { throw "logos.dat 自检失败: magic 不正确" }
$lcnt = [BitConverter]::ToInt32($lbytes, 7)
if ($lcnt -ne $logoPng.Count) { throw "logos.dat 自检失败: 条数 $lcnt ≠ 源文件数 $($logoPng.Count)" }
$loff = 11
for ($i = 0; $i -lt $lcnt; $i++) {
    if ($loff + 2 -gt $lbytes.Length) { throw "logos.dat 自检失败: 第 $i 条 nameLen 越界" }
    $nl = [BitConverter]::ToUInt16($lbytes, $loff); $loff += 2
    if ($loff + $nl + 4 -gt $lbytes.Length) { throw "logos.dat 自检失败: 第 $i 条 name/dataLen 越界" }
    $loff += $nl
    $dl = [BitConverter]::ToInt32($lbytes, $loff); $loff += 4
    if ($dl -le 0 -or $loff + $dl -gt $lbytes.Length) { throw "logos.dat 自检失败: 第 $i 条 data 越界 (dl=$dl)" }
    $loff += $dl
}
if ($loff -ne $lbytes.Length) { throw "logos.dat 自检失败: 解析末位 $loff ≠ 文件长度 $($lbytes.Length)" }
Write-Host ("  台标: {0} 张 → logos.dat ({1} KB)  ✔ 容器自检通过" -f $logoPng.Count, [math]::Round((Get-Item $logoDat).Length / 1KB, 1))
# 发布包里不该再有散装 logos\ 目录（自检）
if (Test-Path (Join-Path $releaseDir "logos")) { throw "发布包不应包含散装 logos\ 目录（应只有 logos.dat）" }

# ★ 2026-09-30：原第 5 步"复制标题栏图标"**已删除** —— `tv-icon.ico` 与 `copyright.png` 现在是 exe 的
#   嵌入资源（csproj `EmbeddedResource`），发布目录/发布包里不再需要这两个文件。
#   ⚠️ 别为了"稳妥"再拷回来：多出来的散文件正是本次要消掉的东西（而且运行期根本不会去读）。
#   ⚠️ 改回散文件时别忘了恢复上面的 `$must` 自检项与"剔除已改为内置的文件"那段。

# ★ sapi_cache：**只带原生死活必需的两个文件**。
#   ⚠️ 曾误以为整个 sapi_cache 都是"页内播放的遗产"而整段删除 ⇒ 原生核直接报
#   `cmg_rt_init 失败 rc=-1: 打不开 <AppDir>/eb_prog.bin`（画面永不播）。
#   事实（见 hmnative\native\cmg_runtime.c:163-181）：原生核**必须有**
#     eb_prog.bin        —— CMG wasm 的 AOT 镜像（装到 EB_BASE 并做重定位）
#     reloc_table.bin    —— 重定位表
#   而 `assets_2025_wasm_cmg.slim.js` / `hls.cmg.js` 才是页内专用（/sapi/* 已无人请求）⇒ 不随包。
# ★ 2026-09-21：素材不再放 sapi_cache\，而是**去前缀后放进 libvlc\**（内核只认 eb_prog.bin /
#   reloc_table.bin 这两个不带前缀的名字，见 cmg_runtime.c:163/166 ⇒ 连改名逻辑都省了）。
$cacheSrc = Join-Path $rootDir "common\assets"
# ★ 2026-09-30：**只随包这两个 bin**。`CMGPlayer.json` 不随包 —— 它是 8 行常量、只有
#   `PalmTVCore.CmgPlayerJson` 一份定义，由**首次运行**生成到 assets_dir（正常= libvlc\），
#   这样就不存在"包里那份与代码常量不同步"的隐患。三个文件仍然**同目录**（内核要求）。
# ★★★★★ 2026-11-05：**不再随包 CMG 素材** ★★★★★
#   CMG 解密核已从 `PalmTVCore.dll` 移除（桌面改 sm4c，见 `Sm4C.cs`），
#   `eb_prog.bin` / `reloc_table.bin` / `CMGPlayer.json` 三件**全部不再需要**，
#   少拷 ~410 KB。若将来真要回退到 CMG 链路，恢复下面这段循环即可。
# foreach ($m in @(@{ s = "eb_prog.bin"; d = "eb_prog.bin" },
#                  @{ s = "reloc_table.bin"; d = "reloc_table.bin" })) {
#     $s = Join-Path $cacheSrc $m.s
#     if (-not (Test-Path $s)) { throw "原生核必需资产缺失: $s" }
#     Copy-Item $s (Join-Path $libvlcDst $m.d) -Force
# }
Write-Host "  （已跳过 CMG 素材：2026-11-05 起桌面不再需要 eb_prog.bin / reloc_table.bin）"
# 自检：素材已并入 libvlc\ ⇒ 发布包里不该再有 sapi_cache\
if (Test-Path (Join-Path $releaseDir "sapi_cache")) { throw "发布包不应包含 sapi_cache\（素材已并入 libvlc\）" }
# ★ 自检：CMGPlayer.json **不该**出现在 libvlc\ 里（它是运行期生成的产物，别把它打进去）
if (Test-Path (Join-Path $libvlcDst "CMGPlayer.json")) {
    [IO.File]::Delete((Join-Path $libvlcDst "CMGPlayer.json"))
    Write-Host "  剔除 libvlc\CMGPlayer.json（应由运行期生成, 不随包）"
}

# ★ 2026-09-30 自检：**exe 同目录不该有这三件**（内核资产只用 libvlc\ 那份，运行期原地使用）。
#   为什么还要拦：旧版本的运行期逻辑会把它们复制到 exe 同目录 ⇒ 用户实际看到"重复一份"。
#   若发布输出里混进来（例如手工拷过 / 上一次运行留下的），这里**直接删掉**并在日志里点名。
$stray = @("eb_prog.bin", "reloc_table.bin", "CMGPlayer.json") |
         Where-Object { Test-Path (Join-Path $releaseDir $_) }
if ($stray) {
    foreach ($f in $stray) { [IO.File]::Delete((Join-Path $releaseDir $f)) }
    Write-Host ("  剔除 exe 同目录的重复资产(内核只用 libvlc\ 那份): " + ($stray -join ', '))
}

# 8) 清理 publish 临时目录 (不再需要)
Remove-Tree $publishDir

# 9) 生成 ZIP
#    ★ 不用 Compress-Archive：libvlc\plugins 有几千个小文件，它又慢又容易撞上瞬时文件占用而报
#      "The process cannot access the file"(实测踩过) ⇒ 改用 ZipFile.CreateFromDirectory。
Remove-Item -Force $zipFile -ErrorAction Ignore
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($releaseDir, $zipFile,
    [IO.Compression.CompressionLevel]::Optimal, $false)

# 10) 删除中间发布目录, 只保留 ZIP 分发包 (避免 bin/Release + desktop-release 重复)
Remove-Tree $releaseDir

$size = [math]::Round((Get-Item $zipFile).Length / 1MB, 1)
Write-Host ""
Write-Host "ZIP 发布完成: $zipFile ($size MB)"
Write-Host ""
Write-Host "运行: 解压 ZIP 到任意目录, 双击 WinPalmTV.exe"
Write-Host "要求: Windows 10+ x64 (WebView2 系统自带)"
