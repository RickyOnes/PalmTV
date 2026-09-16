# 一键构建 proxy：先校验注入语法，再 go build，再覆盖 bin exe。
# 用法（PowerShell）：cd d:/TV/CCTV/proxy; .\build.ps1
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$bin = Join-Path $root 'desktop\bin\Debug\net10.0-windows\win-x64\proxy.exe'

Write-Host '>>> [1/3] 校验注入语法 ...' -ForegroundColor Cyan
node (Join-Path $PSScriptRoot 'verify_inject.cjs')
if ($LASTEXITCODE -ne 0) {
    Write-Host '!!! 语法校验失败，已中止构建。请修复 main.go 注入串后再试。' -ForegroundColor Red
    exit 1
}

Write-Host '>>> [2/3] go build ...' -ForegroundColor Cyan
Push-Location (Join-Path $root 'proxy')
go build -o proxy.exe .
if ($LASTEXITCODE -ne 0) {
    Write-Host '!!! go build 失败' -ForegroundColor Red
    Pop-Location
    exit 1
}
Pop-Location

Write-Host '>>> [3/3] 覆盖 bin exe ...' -ForegroundColor Cyan
Copy-Item -Force (Join-Path $root 'proxy\proxy.exe') $bin
$len = (Get-Item $bin).Length
Write-Host ">>> 完成。已部署 $len bytes 到 $bin" -ForegroundColor Green
