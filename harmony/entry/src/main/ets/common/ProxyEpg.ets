/**
 * ProxyEpg - EPG 节目单 protobuf → JSON 解码（ArkTS 重写版）。
 * 与 hmos/proxy/main.go 的 readVarint/parseEpgProgram/capi 解码完全对齐。
 */

class VarintResult {
  value: number = 0;
  n: number = 0;

  constructor(value: number, n: number) {
    this.value = value;
    this.n = n;
  }
}

/** 读取 protobuf varint，返回 [值, 消耗字节数] */
function readVarint(b: Uint8Array, start: number): VarintResult {
  /* ★ 不要用 `v |= x << s`：s=28 且该字节 ≥ 8 时会溢出成**负数**（32 位有符号左移）。
   *   用乘法累加，最大支持到 2^53，安全。 */
  let v = 0;
  let s = 0;
  for (let i = start; i < b.length; i++) {
    v += (b[i] & 0x7F) * Math.pow(2, s);
    if (b[i] < 0x80) {
      return new VarintResult(v, i - start + 1);
    }
    s += 7;
    if (s > 56) {
      break;
    }
  }
  return new VarintResult(0, 0);
}

/**
 * 解析单个节目 protobuf 消息 → JSON 字符串。
 *
 * 权威字段表（来源：真实抓包响应体逐字节解码 + `proxy/main.go` 的 parseEpgProgram）：
 *   [1] id(string)  [2] title(string)
 *   [3] start_time **epoch 秒**(varint)   ★ UI 侧就是按这个解析的（此前漏读 ⇒ 时间恒为 --:--）
 *   [4] end_time   **epoch 秒**(varint)   ★
 *   [5] start_time "HH:mm"(string)  [6] end_time "HH:mm"(string)   ← 仅作兜底/显示
 *   [7] duration(varint 秒)  [9]/[10] 标志位(string)
 * 注：抓包里**没有**"是否正在播出"字段、也没有描述；正在播出只能由 [3]/[4] 与本地时间比较得出。
 */
function parseEpgProgram(b: Uint8Array): string {
  let id = '';
  let title = '';
  let startSec = 0;
  let endSec = 0;
  let startHm = '';
  let endHm = '';
  let dur = 0;
  let off = 0;
  while (off < b.length) {
    const tagRes = readVarint(b, off);
    const tag = tagRes.value;
    if (tagRes.n === 0) {
      break;
    }
    off += tagRes.n;
    const fnum = tag >> 3;
    const wtype = tag & 0x7;
    if (wtype === 0) { // varint
      const vRes = readVarint(b, off);
      off += vRes.n;
      if (fnum === 3) {
        startSec = vRes.value;
      } else if (fnum === 4) {
        endSec = vRes.value;
      } else if (fnum === 7) {
        dur = vRes.value;
      }
    } else if (wtype === 2) { // length-delimited
      const lenRes = readVarint(b, off);
      off += lenRes.n;
      const length = lenRes.value;
      const s = bytesToString(b.subarray(off, off + length));
      off += length;
      if (fnum === 1) {
        id = s;
      } else if (fnum === 2) {
        title = s;
      } else if (fnum === 5) {
        startHm = s;
      } else if (fnum === 6) {
        endHm = s;
      }
    } else {
      /* ★ 未知 wire type（1/3/4/5）：**跳过该字段**而不是丢掉整条节目（原来 return '' 会连标题一起没了） */
      if (wtype === 1) {
        off += 8;
      } else if (wtype === 5) {
        off += 4;
      } else {
        break; // 3/4（已废弃的 group）无法安全跳过，放弃本条
      }
    }
  }
  if (title === '') {
    return '';
  }
  /* 优先用 epoch 秒（UI 侧 hhmm() 按 epoch 解析）；没有则退化为 "HH:mm" 字符串 */
  const st = startSec > 0 ? String(startSec) : startHm;
  const et = endSec > 0 ? String(endSec) : endHm;
  const titleEsc = title.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return `{"id":"${id}","title":"${titleEsc}","start":"${st}","end":"${et}","dur":${dur}}`;
}

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

/** 将整个 capi protobuf 响应解码为 JSON 数组字符串。 */
export function decodeEpgProtobuf(data: Uint8Array): string {
  const jsonParts: string[] = [];
  let off = 0;
  while (off < data.length) {
    const tagRes = readVarint(data, off);
    if (tagRes.n === 0) {
      break;
    }
    off += tagRes.n;
    const fnum = tagRes.value >> 3;
    const wtype = tagRes.value & 0x7;
    if (wtype === 0) { // varint
      const vRes = readVarint(data, off);
      off += vRes.n;
      // fnum==1 为 total，跳过
    } else if (wtype === 2) { // length-delimited
      const lenRes = readVarint(data, off);
      off += lenRes.n;
      const length = lenRes.value;
      const sub = data.subarray(off, off + length);
      off += length;
      if (fnum === 2) { // program message
        const prog = parseEpgProgram(sub);
        if (prog !== '') {
          jsonParts.push(prog);
        }
      }
    } else {
      break;
    }
  }
  return '[' + jsonParts.join(',') + ']';
}

/** UTF-8 字节转字符串（用于 protobuf 字段） */
function bytesToString(b: Uint8Array): string {
  let s = '';
  let i = 0;
  while (i < b.length) {
    const c = b[i];
    if (c < 0x80) {
      s += String.fromCharCode(c);
      i += 1;
    } else if (c < 0xE0) {
      s += String.fromCharCode(((c & 0x1F) << 6) | (b[i + 1] & 0x3F));
      i += 2;
    } else if (c < 0xF0) {
      s += String.fromCharCode(((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F));
      i += 3;
    } else {
      s += String.fromCharCode(((c & 0x07) << 18) | ((b[i + 1] & 0x3F) << 12) | ((b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F));
      i += 4;
    }
  }
  return s;
}
