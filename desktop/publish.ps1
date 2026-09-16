# 单文件精简发布脚本
#
# 发布结构 (PalmTV-release.zip) —— 只含运行必需文件:
#   PalmTV.Desktop.exe       单文件自包含 (.NET10 + WebView2, 已压缩)
#   proxy.exe       Go 反代 (注入 + 缓存 + /media + /warm 预热)
#   player.served.html   预烘焙页面 (player.html + keygen_bg.wasm + ts_module_body.js
#                        + RJq7sO71JF.wasm 的 base64 内联), 运行时直接由代理同源托管
#   tv-icon.ico          标题栏图标
#   sapi_cache\          cmg.slim.js + eb_prog.bin + reloc_table.bin + hls.cmg.js
#                        (slim 三件套是本地生成产物, 上游没有, 缺了必然绿屏)
#
# 不再随行 (仅开发/分析用, 保留在 git):
#   player.html / keygen_bg.wasm / ts_module_body.js / RJq7sO71JF.wasm / gen_yspticket.cjs
#     —— 只有"重建 player.served.html"时才需要, 运行时读的是 served html
#   sapi_cache\assets_2025_wasm_cmg.worker.js (1.30MB) —— 已由 slim 取代, 页面从不请求
$ErrorActionPreference = "Stop"

$projDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir  = Split-Path -Parent $projDir
$proxyDir = Join-Path $rootDir "proxy"

$publishDir = Join-Path $projDir "publish"              # dotnet publish 临时输出
$releaseDir = Join-Path $projDir "desktop-release"   # 最终发布目录
$zipFile    = Join-Path $rootDir "PalmTV-release.zip"

# 1) 清理旧目录
Remove-Item -Recurse -Force $publishDir -ErrorAction Ignore
Remove-Item -Force $zipFile -ErrorAction Ignore
Remove-Item -Recurse -Force $releaseDir -ErrorAction Ignore
New-Item -ItemType Directory -Force $releaseDir | Out-Null

# 2) 单文件发布 .NET 程序 (含 WebView2 Runtime 检测, 系统自带则不打包)
Write-Host "Publishing single-file self-contained app..."
dotnet publish "$projDir/PalmTV.Desktop.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:PublishReadyToRun=false `
    -p:PublishTrimmed=false `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $publishDir

# 3) 复制主程序
Copy-Item (Join-Path $publishDir "PalmTV.Desktop.exe") (Join-Path $releaseDir "PalmTV.Desktop.exe") -Force

# 4) 复制 Go 代理 (已编译好的最新版)
$proxyExe = Join-Path $proxyDir "proxy.exe"
if (-not (Test-Path $proxyExe)) {
    throw "proxy.exe not found at $proxyExe. Run '.\build.ps1' in proxy first."
}
Copy-Item $proxyExe (Join-Path $releaseDir "proxy.exe") -Force

# 5) 生成 player.served.html: player.html 的三个占位标记替换为注入资产的 base64。
#    ★ 与 MainWindow.EnsureServedHtml() 完全同一套替换规则, 保证发布版与调试版一致。
$playerHtml = Join-Path $projDir "player.html"
if (-not (Test-Path $playerHtml)) { throw "player.html 缺失: $playerHtml" }
$html = [IO.File]::ReadAllText($playerHtml)
$injections = @(
    @{ Marker = '<!-- WASM_BASE64 -->';    File = 'keygen_bg.wasm';    Var = '__wasmBase64' },
    @{ Marker = '<!-- CKEY_CORE -->';      File = 'ts_module_body.js'; Var = '__ckeyCoreB64' },
    @{ Marker = '<!-- YSPTICKET_WASM -->'; File = 'RJq7sO71JF.wasm';   Var = '__yspTicketWasmB64' }
)
foreach ($inj in $injections) {
    $src = Join-Path $projDir $inj.File
    if (-not (Test-Path $src)) { throw "$($inj.File) 缺失, 无法生成 player.served.html: $src" }
    if (-not $html.Contains($inj.Marker)) { throw "player.html 缺少占位标记 $($inj.Marker)" }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
    $html = $html.Replace($inj.Marker, "<script>window.$($inj.Var)='$b64'</script>")
}
$servedHtml = Join-Path $releaseDir "player.served.html"
[IO.File]::WriteAllText($servedHtml, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("player.served.html 已生成 ({0} MB)" -f [math]::Round((Get-Item $servedHtml).Length / 1MB, 2))

# 6) 复制标题栏图标 (此前漏拷, 发布版标题栏图标是空的)
$icon = Join-Path $projDir "tv-icon.ico"
if (Test-Path $icon) { Copy-Item $icon $releaseDir -Force }

# 7) 复制 sapi_cache —— ★ 源目录是 proxy\sapi_cache, 不是 $rootDir\sapi_cache
#    (旧版指向不存在的 $rootDir\sapi_cache, 被 if (Test-Path) 静默跳过 → 发布包没有解密资产)
$cacheSrc = Join-Path $proxyDir "sapi_cache"
if (-not (Test-Path $cacheSrc)) {
    throw "sapi_cache 未找到: $cacheSrc (slim 三件套为本地生成产物, 缺失必然绿屏)"
}
$cacheDst = Join-Path $releaseDir "sapi_cache"
New-Item -ItemType Directory -Force $cacheDst | Out-Null
$copied = Get-ChildItem $cacheSrc -File |
    Where-Object { $_.Name -notlike '*_cmg.worker.js' } |   # cmg.worker.js 已由 slim 取代
    ForEach-Object { Copy-Item $_.FullName $cacheDst -Force; $_.Name }
Write-Host ("sapi_cache 已复制: {0}" -f ($copied -join ', '))

# 8) 清理 publish 临时目录 (不再需要)
Remove-Item -Recurse -Force $publishDir -ErrorAction Ignore

# 9) 生成 ZIP
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipFile -Force

# 10) 删除中间发布目录, 只保留 ZIP 分发包 (避免 bin/Release + desktop-release 重复)
Remove-Item -Recurse -Force $releaseDir -ErrorAction Ignore

$size = [math]::Round((Get-Item $zipFile).Length / 1MB, 1)
Write-Host ""
Write-Host "ZIP 发布完成: $zipFile ($size MB)"
Write-Host ""
Write-Host "运行: 解压 ZIP 到任意目录, 双击 PalmTV.Desktop.exe"
Write-Host "要求: Windows 10+ x64 (WebView2 系统自带)"
