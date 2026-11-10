/**
 * 自定义 IPTV 源 —— 与桌面端 `windows/IptvChannels.cs`、安卓端 `IptvSources.kt`
 * **同规则、同 m3u 格式、同存储文件名**。
 *
 * ★ 2026-10-02（用户要求：鸿蒙端也要有，且"增加源的方式同桌面端"）。
 *
 * 存储：`<filesDir>/iptv-local.m3u`
 *   （桌面：`%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`；安卓：`filesDir/iptv-local.m3u`）
 *   格式：`#EXTM3U` + 注释头 + 每项 `#EXTINF:-1,频道名` 换行 `地址`（UTF-8）
 *   写入：先写 `.tmp` 再 `renameSync` **原子替换**（与桌面 `File.Move(overwrite)` 同思路）
 *
 * 规则（三端一致）：
 *   · 地址必填且必须 `http://` / `https://` 开头；
 *   · 频道名留空 ⇒ **取域名**（取不到用 "IPTV"）；
 *   · 解析时剥掉 `(720p)` 之类清晰度后缀、跳过 `#` 注释、忽略没有 `#EXTINF` 配对的裸地址行；
 *   · 并表：**内置优先**（同 URL 不重复加）+ 用户内部同 URL 去重；
 *     用户条目 id 用 `user-iptv-N`（内置台标表里没有这些 id ⇒ 自动走"名称首字"文字兜底，不串台标）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Channels, CctvChannel } from './ChannelList';
import { Log } from './Log';

/** 用户条目 id 前缀（与内置 `iptv-0..14` 区分开，避免台标串台） */
const USER_ID_PREFIX: string = 'user-iptv-';
const FILE_NAME: string = 'iptv-local.m3u';

export interface IptvEntry {
  name: string;
  url: string;
}

/** 地址校验（桌面 `IptvSourceWindow.Validate()` 前两条）。返回 null = 通过，否则是中文错误文案 */
export function validateUrl(url: string): string | null {
  const u: string = url.trim();
  if (u.length === 0) {
    return '请填写播放地址。';
  }
  const lower: string = u.toLowerCase();
  if (lower.indexOf('http://') !== 0 && lower.indexOf('https://') !== 0) {
    return '播放地址需以 http:// 或 https:// 开头。';
  }
  return null;
}

/** 空名 ⇒ 取域名（桌面 `new Uri(url).Host` 同语义）；取不到用 "IPTV" */
export function nameOrHost(name: string, url: string): string {
  const n: string = name.trim();
  if (n.length > 0) {
    return n;
  }
  try {
    const noScheme: string = url.trim().replace(/^[a-zA-Z]+:\/\//, '');
    const host: string = noScheme.split('/')[0].split(':')[0];
    return host.length > 0 ? host : 'IPTV';
  } catch (e) {
    return 'IPTV';
  }
}

/** 剥掉 `(720p)` / `(1080P)` 之类清晰度后缀（桌面 `LoadFile` 的正则同款） */
export function stripQuality(name: string): string {
  return name.replace(/\s*\(\d{3,4}[pP]\)\s*$/, '').trim();
}

/** 解析 m3u 文本（桌面 `IptvChannels.LoadFile()` 同规则） */
export function parseM3u(text: string): IptvEntry[] {
  const out: IptvEntry[] = [];
  let pending: string = '';
  let hasPending: boolean = false;
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    const upper: string = line.toUpperCase();
    if (upper.indexOf('#EXTM3U') === 0) {
      continue;                                  // 头，忽略
    }
    if (upper.indexOf('#EXTINF') === 0) {
      const comma: number = line.indexOf(',');
      pending = comma >= 0 ? line.substring(comma + 1).trim() : '';
      hasPending = true;
      continue;
    }
    if (line.indexOf('#') === 0) {
      continue;                                  // #EXTVLCOPT 等一律忽略
    }
    if (!hasPending) {
      continue;                                  // 没有配对 EXTINF 的裸地址行跳过（桌面同）
    }
    let nm: string = stripQuality(pending);
    if (nm.length === 0) {
      nm = 'IPTV';
    }
    out.push({ name: nm, url: line } as IptvEntry);
    hasPending = false;
  }
  return out;
}

/** 生成 m3u 文本（与桌面 `IptvChannels.SaveFile()` / 安卓 `IptvSources.toM3u()` 同格式） */
export function toM3u(entries: IptvEntry[]): string {
  let s: string = '#EXTM3U\n';
  s += '# 掌上电视 自定义 IPTV 源（由「关于 → 技术说明 → 添加 / 编辑」维护；也可用文本编辑器直接改）\n';
  s += '# 格式：#EXTINF:-1,频道名  换行  http://.../xxx.m3u8\n';
  s += '# ⚠️ 内置的地方台不在本文件里，这里只放你自己加的源。\n';
  for (let i = 0; i < entries.length; i++) {
    s += '#EXTINF:-1,' + entries[i].name + '\n' + entries[i].url + '\n';
  }
  return s;
}

/** 读文件（不存在 / 读失败 ⇒ 空数组，不抛） */
export function loadFile(ctx: common.Context): IptvEntry[] {
  const path: string = ctx.filesDir + '/' + FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return [];
    }
    return parseM3u(fs.readTextSync(path));
  } catch (e) {
    Log.w('[iptv] 读自定义源文件失败: ' + (e as Error).message);
    return [];
  }
}

/** 写文件（原子替换；空列表 ⇒ 删文件，桌面同）。@return 是否成功 */
export function saveFile(ctx: common.Context, entries: IptvEntry[]): boolean {
  const path: string = ctx.filesDir + '/' + FILE_NAME;
  const tmp: string = path + '.tmp';
  try {
    if (entries.length === 0) {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      return true;
    }
    const f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, toM3u(entries));
    fs.closeSync(f);
    fs.renameSync(tmp, path);
    return true;
  } catch (e) {
    Log.w('[iptv] 写自定义源文件失败: ' + (e as Error).message);
    return false;
  }
}

/**
 * 把用户条目并入 `Channels`（**先移除上一批用户台**再加，便于"保存后立即生效"时重复调用）。
 * @return 真正并入的条数（已按"内置优先 + 同 URL 去重"过滤）
 */
export function mergeIntoChannels(entries: IptvEntry[]): number {
  for (let i = Channels.length - 1; i >= 0; i--) {
    if (Channels[i].id.indexOf(USER_ID_PREFIX) === 0) {
      Channels.splice(i, 1);
    }
  }
  const builtIn: string[] = [];
  for (let i = 0; i < Channels.length; i++) {
    const c: CctvChannel = Channels[i];
    if (c.src === 'iptv' && c.streamId !== undefined) {
      builtIn.push(c.streamId.toLowerCase());
    }
  }
  const seen: string[] = [];
  let n: number = 0;
  for (let i = 0; i < entries.length; i++) {
    const url: string = entries[i].url.trim();
    if (url.length === 0) {
      continue;
    }
    const key: string = url.toLowerCase();
    if (builtIn.indexOf(key) >= 0 || seen.indexOf(key) >= 0) {
      continue;                                  // 内置优先 + 用户内部去重
    }
    seen.push(key);
    Channels.push({
      id: USER_ID_PREFIX + n,
      name: nameOrHost(entries[i].name, url),
      pid: '',
      cnlId: '',
      group: 'local',
      src: 'iptv',
      streamId: url
    } as CctvChannel);
    n++;
  }
  return n;
}

/** 当前已并表的用户条目数（关于页显示"自定义 N 条"用，与桌面 `LastUserCount` 同口径） */
export function userChannelCount(): number {
  let n: number = 0;
  for (let i = 0; i < Channels.length; i++) {
    if (Channels[i].id.indexOf(USER_ID_PREFIX) === 0) {
      n++;
    }
  }
  return n;
}

/** 自定义源文件路径（提示文案里显示给用户，与桌面 `IptvChannels.UserPath` 同用途） */
export function filePath(ctx: common.Context): string {
  return ctx.filesDir + '/' + FILE_NAME;
}
