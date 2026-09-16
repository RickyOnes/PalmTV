// 注入语法校验器：在 go build 之前运行，确保 main.go 里的 JS 注入串
// 应用到缓存的 hls.cmg.js / cmg.worker.js 后整文件语法合法。
// 用法：node verify_inject.cjs
// 从 main.go 解析所有 `const NAME = `...`` 反引号串，按注入逻辑做替换，
// 再用 vm.Script 校验语法。任一文件语法错误即退出码 1。
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const root = path.resolve(__dirname, '..');
const maingo = path.join(root, 'proxy', 'main.go');
const hlsCache = path.join(root, 'desktop', 'bin', 'Debug', 'net10.0-windows', 'win-x64', 'sapi_cache', 'assets_2025_wasm_hls.cmg.js');
const wkrCache = path.join(root, 'desktop', 'bin', 'Debug', 'net10.0-windows', 'win-x64', 'sapi_cache', 'assets_2025_wasm_cmg.worker.js');
const slimCache = path.join(root, 'desktop', 'bin', 'Debug', 'net10.0-windows', 'win-x64', 'sapi_cache', 'assets_2025_wasm_cmg.slim.js');

const src = fs.readFileSync(maingo, 'utf8');
// 捕获所有 `const NAME = `...`` 反引号串（注入串内部不含反引号）
const re = /const\s+(\w+)\s*=\s*`([\s\S]*?)`/g;
const consts = {};
let m;
while ((m = re.exec(src))) consts[m[1]] = m[2];

let failed = false;

function applyAndCheck(file, pairs, label) {
  if (!fs.existsSync(file)) {
    console.log(`SKIP ${label}: 缓存文件不存在 ${file}（首次构建前可忽略）`);
    return;
  }
  let body = fs.readFileSync(file, 'utf8');
  let applied = 0;
  for (const [o, n] of pairs) {
    if (consts[o] == null || consts[n] == null) {
      console.log(`WARN ${label}: 缺少常量 ${o} 或 ${n}`);
      continue;
    }
    if (body.includes(consts[o])) {
      body = body.split(consts[o]).join(consts[n]);
      applied++;
      console.log(`  applied ${o} -> ${n}`);
    } else {
      console.log(`  WARN ${label}: 未匹配 ${o}（可能已注入或上游变更）`);
    }
  }
  try {
    new vm.Script(body, { filename: label });
    console.log(`SYNTAX OK ${label} (${applied} 处替换, ${body.length} bytes)`);
  } catch (e) {
    console.log(`SYNTAX ERROR ${label}: ${e.message}`);
    failed = true;
  }
}

console.log('=== 校验 hls.cmg.js 注入 ===');
applyAndCheck(hlsCache, [
  ['cmgDecOld', 'cmgDecNew'],
  ['cmgDecOld2', 'cmgDecNew2'],
  ['dispProbeOld', 'dispProbeNew'],
  ['initBlockOld', 'initBlockNew'],
], 'hls.cmg.js');

console.log('=== 校验 cmg.worker.js 注入 ===');
applyAndCheck(wkrCache, [
  ['fetchGateOld', 'fetchGateNew'],
], 'cmg.worker.js');

console.log('=== 校验 cmg.slim.js 注入 ===');
applyAndCheck(slimCache, [
  ['fetchGateOld', 'fetchGateNew'],
], 'cmg.slim.js');

if (failed) {
  console.log('\n*** 语法校验失败，禁止 go build ***');
  process.exit(1);
}
console.log('\n*** 全部语法 OK，可以 go build ***');
