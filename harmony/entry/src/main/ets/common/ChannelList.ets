/**
 * ChannelList - 央视频频道列表（★ 权威来源）
 * 桌面版 PlayerService.cs Channels 已按本文件全量回灌对齐 (2026-09-04)。
 * 切换频道时以 Pid 走 /auth + /get-live-info 全流程。
 */

export interface CctvChannel {
  id: string;
  name: string;
  pid: string;
  cnlId: string;
  group: 'cctv' | 'satellite' | 'local';  // 分组：CCTV / 卫视频道 / 地方频道
  /**
   * ★ 2026-09-19 起：取流来源。**缺省 = 'ysp'**（央视频：自研 cKey → liveinfo → 明文 HLS，本地代理只转发）。
   *   'jstv' = 江苏台（荔枝 TV）直连：只需本地代理带 Referer 转发 + native 签名，**无需解密**
   *   ⇒ 见 `common/JiangsuTv.ets` 与 `LocalProxyServer` 的 `/jstv.m3u8`、`/jstv-seg`。
   *   ★★ 2026-09-22 新增 'iptv' = **外部 IPTV 明文直链**（各地方台自建 CDN / 第三方直播源）。
   *     · 与 jstv 的**关键区别**：上游是**明文 HLS 直链**，**不需要签名**，也**不需要任何代理/转发**
   *       ⇒ 播放器**直接吃 `streamId` 里的原始 URL**，不经 `LocalProxyServer`、不解密。
   *     · 桌面端对应实现：`windows/IptvChannels.cs` 的 `BuiltIn` 表
   *       （桌面走 VLC 直连；鸿蒙走 AVPlayer 直连）。
   *     · ★★ 2026-09-30：**两端都是"代码即清单"** —— 桌面那边也把 15 条内置移进了 `IptvChannels.cs`
   *       （原先的外置 `common/channels/iptv-local.m3u` 已删除，包内不再有 m3u 文件）。
   *       ⇒ **改一处必须改另一处**（内容 + **顺序**都要一致；顺序决定 id）。
   *       ⚠️ 用户自己加的源在桌面上仍是外置文件 `%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`（鸿蒙无此机制）。
   */
  src?: 'ysp' | 'jstv' | 'iptv';
  /**
   * `src === 'jstv'`：荔枝 TV 流 ID（如 `'jszypro'`）。
   * `src === 'iptv'`：**原始明文 HLS 直链 URL**（与桌面端 `IptvChannels.cs` 把 URL 存在 `StreamId` 一致）。
   */
  streamId?: string;
}

/** 是否走江苏台（荔枝 TV）直连链路（**忽略 auth/签名/EPG/CMG 解密**） */
export function isJstvChannel(ch: CctvChannel): boolean {
  return ch.src === 'jstv';
}

/** ★★ 2026-09-22 新增：是否走 **IPTV 外部明文直链**（同样忽略 auth/签名/EPG/CMG 解密，且连代理都不走） */
export function isIptvChannel(ch: CctvChannel): boolean {
  return ch.src === 'iptv';
}

/** 是否属于"本地直连类"频道（jstv + iptv）—— 二者都**不参与央视频预热/取流/解密的任何环节** */
export function isLocalDirectChannel(ch: CctvChannel): boolean {
  return ch.src === 'jstv' || ch.src === 'iptv';
}

export const Channels: CctvChannel[] = [
  // ===== CCTV 组（默认）=====
  { id: 'cctv1', name: 'CCTV-1 综合', pid: '600001859', cnlId: '2024078203', group: 'cctv' },
  { id: 'cctv2', name: 'CCTV-2 财经', pid: '600001800', cnlId: '2024075403', group: 'cctv' },
  { id: 'cctv3', name: 'CCTV-3 综艺', pid: '600001801', cnlId: '2024068503', group: 'cctv' },
  { id: 'cctv4', name: 'CCTV-4 中文国际', pid: '600001814', cnlId: '2029797103', group: 'cctv' },
  { id: 'cctv5', name: 'CCTV-5 体育', pid: '600001818', cnlId: '2024078403', group: 'cctv' },
  { id: 'cctv5p', name: 'CCTV-5+ 赛事', pid: '600001817', cnlId: '2024078003', group: 'cctv' },
  { id: 'cctv6', name: 'CCTV-6 电影', pid: '600108442', cnlId: '2013693901', group: 'cctv' },
  { id: 'cctv7', name: 'CCTV-7 军事', pid: '600004092', cnlId: '2024072003', group: 'cctv' },
  { id: 'cctv8', name: 'CCTV-8 电视剧', pid: '600001803', cnlId: '2029793003', group: 'cctv' },
  { id: 'cctv9', name: 'CCTV-9 纪录', pid: '600004078', cnlId: '2024078603', group: 'cctv' },
  { id: 'cctv10', name: 'CCTV-10 科教', pid: '600001805', cnlId: '2024078703', group: 'cctv' },
  { id: 'cctv11', name: 'CCTV-11 戏曲', pid: '600001806', cnlId: '2027248703', group: 'cctv' },
  { id: 'cctv12', name: 'CCTV-12 社会与法', pid: '600001807', cnlId: '2027248803', group: 'cctv' },
  { id: 'cctv13', name: 'CCTV-13 新闻', pid: '600001811', cnlId: '2029797203', group: 'cctv' },
  { id: 'cctv14', name: 'CCTV-14 少儿', pid: '600001809', cnlId: '2027248903', group: 'cctv' },
  { id: 'cctv15', name: 'CCTV-15 音乐', pid: '600001815', cnlId: '2027249003', group: 'cctv' },
  { id: 'cctv16', name: 'CCTV-16 奥林匹克', pid: '600098637', cnlId: '2027249103', group: 'cctv' },
  { id: 'cctv16k', name: 'CCTV-16(4K)', pid: '600099502', cnlId: '2027249303', group: 'cctv' },
  { id: 'cctv17', name: 'CCTV-17 农业', pid: '600001810', cnlId: '2027249403', group: 'cctv' },
  { id: 'cctv4k', name: 'CCTV-4K 超高清', pid: '600002264', cnlId: '2029810303', group: 'cctv' },
  { id: 'cctv8k', name: 'CCTV-8K', pid: '600156816', cnlId: '2026774121', group: 'cctv' },
  { id: 'cetv1', name: '中国教育1台', pid: '600171827', cnlId: '2022823801', group: 'cctv' },
  { id: 'cgne', name: 'CGN英文台', pid: '600014550', cnlId: '2024181703', group: 'cctv' },
  // ===== 卫视频道组 =====
  { id: 'jsws', name: '江苏卫视', pid: '600002521', cnlId: '2024171103', group: 'satellite' },
  { id: 'hnws', name: '湖南卫视', pid: '600002475', cnlId: '2024054803', group: 'satellite' },
  { id: 'zjws', name: '浙江卫视', pid: '600002520', cnlId: '2024054703', group: 'satellite' },
  { id: 'bjws', name: '北京卫视', pid: '600002309', cnlId: '2024052703', group: 'satellite' },
  { id: 'dfws', name: '东方卫视', pid: '600002483', cnlId: '2024054503', group: 'satellite' },
  { id: 'henws', name: '河南卫视', pid: '600002525', cnlId: '2029797303', group: 'satellite' },
  { id: 'hebws', name: '河北卫视', pid: '600002493', cnlId: '2024171503', group: 'satellite' },
  { id: 'ahws', name: '安徽卫视', pid: '600002532', cnlId: '2024171403', group: 'satellite' },
  { id: 'tjws', name: '天津卫视', pid: '600152137', cnlId: '2019927003', group: 'satellite' },
  { id: 'sdws', name: '山东卫视', pid: '600002513', cnlId: '2029787903', group: 'satellite' },
  { id: 'sxws', name: '山西卫视', pid: '600190407', cnlId: '2025560803', group: 'satellite' },
  { id: 'dnws', name: '东南卫视', pid: '600002484', cnlId: '2024061503', group: 'satellite' },
  { id: 'hbws', name: '湖北卫视', pid: '600002508', cnlId: '2024171203', group: 'satellite' },
  { id: 'jxws', name: '江西卫视', pid: '600002503', cnlId: '2024061703', group: 'satellite' },
  { id: 'shxws', name: '陕西卫视', pid: '600190400', cnlId: '2029795103', group: 'satellite' },
  { id: 'lnws', name: '辽宁卫视', pid: '600002505', cnlId: '2024171303', group: 'satellite' },
  { id: 'jlws', name: '吉林卫视', pid: '600190405', cnlId: '2025561503', group: 'satellite' },
  { id: 'hebs', name: '黑龙江卫视', pid: '600002498', cnlId: '2029797003', group: 'satellite' },
  { id: 'ynws', name: '云南卫视', pid: '600190402', cnlId: '2025561303', group: 'satellite' },
  { id: 'gzws', name: '贵州卫视', pid: '600002490', cnlId: '2024061603', group: 'satellite' },
  { id: 'scws', name: '四川卫视', pid: '600002516', cnlId: '2024061403', group: 'satellite' },
  { id: 'cqws', name: '重庆卫视', pid: '600002531', cnlId: '2024061103', group: 'satellite' },
  { id: 'hainanws', name: '海南卫视', pid: '600002506', cnlId: '2024055603', group: 'satellite' },
  { id: 'gdws', name: '广东卫视', pid: '600002485', cnlId: '2024060903', group: 'satellite' },
  { id: 'gxws', name: '广西卫视', pid: '600002509', cnlId: '2024060703', group: 'satellite' },
  { id: 'szws', name: '深圳卫视', pid: '600002481', cnlId: '2024061303', group: 'satellite' },
  { id: 'nmgws', name: '内蒙古卫视', pid: '600190401', cnlId: '2025561203', group: 'satellite' },
  { id: 'gansuws', name: '甘肃卫视', pid: '600190408', cnlId: '2025561703', group: 'satellite' },
  { id: 'qhws', name: '青海卫视', pid: '600190406', cnlId: '2025559103', group: 'satellite' },
  { id: 'xzws', name: '西藏卫视', pid: '600190403', cnlId: '2025558003', group: 'satellite' },
  { id: 'xinjiangws', name: '新疆卫视', pid: '600152138', cnlId: '2019927403', group: 'satellite' },
  { id: 'ningxiaws', name: '宁夏卫视', pid: '600190737', cnlId: '2025608503', group: 'satellite' },
  // ===== 地方频道组（本地台）=====
  // ★ 2026-09-19：首批接入**江苏省**（荔枝 TV / live.jstv.com）。
  //   这几路**不走央视频**：没有 pid/cnlId，也不需要 auth/签名/get_live_info —— 上游地址只需
  //   一次 `txSecret`（MD5，签名在 native `libpalmtv_napi.so`，见 `common/native/src/jstv_sign.c`
  //   与 `common/JiangsuTv.ets`），且**流是明文的**（代理只转发不解密）。
  //   `id` 直接用荔枝 TV 的 streamId（与 `ChannelList` 既有 id 不冲突）。
  //   ⚠️ 源文件（桌面版）：`IptvPlayerMpv/Services/JiangsuTvProxyService.cs` 的 Channels 表，
  //      增删台时两处必须同步（`JiangsuTv.JSTV_CHANNELS` 同名同序）。
  //   ★ 2026-09-19（用户要求）：**不列江苏卫视（jswspro）** —— 卫视组里已有同名的 `jsws`（央视频源），
  //     重复出现只会让人分不清；`JiangsuTv.JSTV_CHANNELS` 里也已同步移除，并保留注释说明。
  { id: 'jsws4kpro', name: '江苏卫视4K', pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsws4kpro' },
  { id: 'jszypro',   name: '江苏综艺',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jszypro' },
  { id: 'jsyspro',   name: '江苏影视',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsyspro' },
  { id: 'jscspro',   name: '江苏城市',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jscspro' },
  { id: 'jsxwpro',   name: '江苏新闻',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsxwpro' },
  { id: 'jsjypro',   name: '江苏教育',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsjypro' },
  { id: 'jsxxpro',   name: '江苏休闲',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsxxpro' },
  { id: 'jsgjpro',   name: '江苏国际',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'jsgjpro' },
  { id: 'ymktpro',   name: '优漫卡通',   pid: '', cnlId: '', group: 'local', src: 'jstv', streamId: 'ymktpro' },
  /* ===== ★★ 2026-09-22 新增：IPTV 外部明文直链（`src: 'iptv'`）=====
   *   与上面江苏台（jstv）的**区别**：上游是**明文 HLS 直链**，**没有签名、没有本地代理** ⇒
   *   播放器**直接吃 `streamId` 里的原始 URL**（不经 `LocalProxyServer`、不解密）。
   *   ★★ 2026-09-30：**本表（鸿蒙）与桌面 `windows/IptvChannels.cs` 的 `BuiltIn` 表互为镜像** ——
   *      两边都是"代码即清单"（桌面原先的外置 m3u 已删除），**改一处必须改另一处**（内容 + **顺序**）：
   *     · `id`        = `iptv-<下标>`，**从 0 开始**（桌面按同一下标生成同一个 id ⇒ 台标/高亮口径一致）；
   *     · `name`      = 去掉清晰度后缀（`(720p)` 之类）的频道名；
   *     · `streamId`  = 原始直链 URL（桌面把同一个 URL 存在 `StreamId`）。
   *   ⚠️ 两边**顺序**都别为了"看起来整齐"重排（id 会整体错位 ⇒ 台标串台）。
   *   ⚠️ 用户自己加的源：桌面是外置文件 `%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`，
   *      **内置在前、用户新增追加到最后**（同 URL 以内置为准）；鸿蒙无此机制。 */
  { id: 'iptv-0',  name: '广州电视',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://tencentplaybusiness.gztv.com/live/zonghes.m3u8' },
  { id: 'iptv-7',  name: '广州新闻',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://tencentplay.gztv.com/live/nanguodushi.m3u8?txSecret=550af55c0ea34ce492748481415b6dfa&txTime=1903e7b17de' },
  { id: 'iptv-1',  name: '哈尔滨电影', pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://stream.hrbtv.net/yspd/playlist.m3u8' },
  { id: 'iptv-2',  name: '哈尔滨综合', pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://stream.hrbtv.net/xwzh/playlist.m3u8?_upt=ef41dd531755913594' },
  { id: 'iptv-3',  name: '吉林都市',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/7e8474e6daea44ccaa5aa2300191439e/index.m3u8' },
  { id: 'iptv-4',  name: '吉林乡村',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/3ffc4824dce54b92be185555923ce382/index.m3u8' },
  { id: 'iptv-5',  name: '吉林生活',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/0a76740c72b74fabae611845aa21e06a/index.m3u8' },
  { id: 'iptv-6',  name: '吉林影视',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/906341e6f19b4c4bacdc89941eb85d12/index.m3u8' },
  { id: 'iptv-8',  name: '农林卫视',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://124.116.183.146:9901/tsfile/live/1004_1.m3u8' },
  { id: 'iptv-9',  name: '山东教育',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://test1.live.sdetv.com.cn/live/dianshizhibo/playlist.m3u8' },
  { id: 'iptv-10', name: '四平综合',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://stream2.jlntv.cn/sptv/sd/live.m3u8?_upt=f27750421743154598' },
  { id: 'iptv-11', name: '通化新闻',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/43ea5771aa44421591f9dfd2b71f1b9b/index.m3u8' },
  { id: 'iptv-12', name: '赤峰综合',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://play1-qk.nmtv.cn/live/1735546697341033.m3u8' },
  { id: 'iptv-13', name: '香港卫视',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'https://hkstv.tv/api/m3u8-proxy?url=http%3A%2F%2Fwebcast.hkstv.tv%2Flivestream%2Fmutfysrq%2Fplaylist.m3u8' },
  { id: 'iptv-14', name: '金鹰卡通',  pid: '', cnlId: '', group: 'local', src: 'iptv', streamId: 'http://59.39.89.130:60901/tsfile/live/0125_25.m3u8?key=txiptv&playlive=1&authid=0' },

  // 后续补其他省/市级台时：若是"直连 + 签名"的地方源，照抄上面江苏那组（新增一个 provider 即可）；
  // 若是"明文直链"，照抄 IPTV 这组（只需 name + URL，无需任何 provider/代理）。
];

/** 按分组筛选频道 */
export function channelsByGroup(g: 'cctv' | 'satellite' | 'local'): CctvChannel[] {
  return Channels.filter((c) => c.group === g);
}

/**
 * 频道 id → **台标资源包条目名**（`rawfile/logos.dat` 内的 `lNN`）。缺失图标的频道返回空字符串。
 *
 * ★ 演变史：`resources/base/media/*.png`（明文 PNG，会被资源扫描看到）
 *      → 2026-09-18 `rawfile/rf/lNN.dat`（**一台一个文件**，XOR 掩码去明文）
 *      → **2026-10-01 `rawfile/logos.dat`（79 个合并成 1 个文件）**（用户要求：打包后文件数不要太多）
 *   载荷仍是 XOR 掩码态；读取 = `Index.ets` 的 `logoEntry()`（取条目）+ `AssetMask.unmask()`（解掩码）。
 *   生成/更新：`powershell -File tools/pack_harmony_logos.ps1 -Apply`（自带条目长度/首字节自检）。
 *   ⚠️ 本表的值现在只是**包内条目名**，不再是文件路径。
 */
const CHANNEL_ICONS: Record<string, string> = {
  // CCTV 组
  'cctv1': 'l03',
  'cctv2': 'l13',
  'cctv3': 'l14',
  'cctv4': 'l15',
  'cctv5': 'l17',
  'cctv5p': 'l18',
  'cctv6': 'l19',
  'cctv7': 'l20',
  'cctv8': 'l21',
  'cctv9': 'l23',
  'cctv10': 'l04',
  'cctv11': 'l05',
  'cctv12': 'l06',
  'cctv13': 'l07',
  'cctv14': 'l08',
  'cctv15': 'l09',
  'cctv16': 'l10',
  'cctv16k': 'l11',
  'cctv17': 'l12',
  'cctv4k': 'l16',
  'cctv8k': 'l22',
  'cetv1': 'l24',
  'cgne': 'l00',
  // 卫视频道
  'jsws': 'l38',
  'hnws': 'l37',
  'zjws': 'l54',
  'bjws': 'l02',
  'dfws': 'l26',
  'szws': 'l48',
  'ahws': 'l01',
  'gdws': 'l29',
  'tjws': 'l50',
  'hbws': 'l36',
  'sdws': 'l46',
  'dnws': 'l27',
  'hebs': 'l34',
  'lnws': 'l41',
  'sxws': 'l47',
  'jxws': 'l39',
  'jlws': 'l40',
  'shxws': 'l45',
  'ynws': 'l53',
  'scws': 'l49',
  'gxws': 'l30',
  'gzws': 'l31',
  'hebws': 'l33',
  'hainanws': 'l32',
  'cqws': 'l25',
  'henws': 'l35',
  'gansuws': 'l28',
  'qhws': 'l44',
  'xzws': 'l52',
  'xinjiangws': 'l51',
  'ningxiaws': 'l43',
  'nmgws': 'l42',
  // ===== 地方台（江苏省，2026-09-19）=====
  // ★ 各台**独立台标**（2026-09-19 第二轮）：源图来自用户云盘目录
  //   `C:\Users\Administrator\OneDrive\图片\TV图标\`，与下面的取值一一对应
  //   （jiangsu_ws4k / jiangsu_zy / jiangsu_ys / jiangsu_cs / jiangsu_xw / jiangsu_jy /
  //     jiangsu_xx / jiangsu_gj / youmankatong）。
  // ★ 改台标的固定流程（工具已改为**增量编号 + 支持换图**，重跑安全、不会覆盖别的图）：
  //   ★ 2026-10-01 更新：旧工具 `tools/hide_assets.cjs` / `tools/asset_map.json` 已不在仓库，
  //     现在**只有一件事**：
  //   ① 换图（编号不变）⇒ 把 PNG 按掩码键 `PalmTV-rs-2026` XOR 回同名 `rawfile/rf/lNN.dat`；
  //      新增台标 ⇒ 用新编号（只许增量）放进 `rawfile/rf/`，并在本表加一行；
  //   ② `powershell -File tools/pack_harmony_logos.ps1 -Apply` ⇒ 重新生成 `rawfile/logos.dat`（自带自检）；
  //   ③ Build（台标是资源，改了必须重新打包）。
  // ★ 不列 jswspro（江苏卫视）：卫视组已有同名台，见上面频道表处的注释。
  'jsws4kpro': 'l58',
  'jszypro': 'l62',
  'jsyspro': 'l61',
  'jscspro': 'l55',
  'jsxwpro': 'l59',
  'jsjypro': 'l57',
  'jsxxpro': 'l60',
  'jsgjpro': 'l56',
  'ymktpro': 'l63',
  /* ===== ★★ 2026-09-23：IPTV 外部直链地方台（15 张，独立台标）=====
   * 源图 = 用户放在 `windows/logos/real/<频道名>.png` 的那批（中文名，与 `name` 字段一一对应）；
   * 落地 = 条目 `l64~l78`（XOR 掩码后的 PNG，掩码键 `PalmTV-rs-2026`，见 `AssetMask.MASK_KEY`）。
   * ★ 2026-10-01：这些条目已随其余台标一起合并进 **`rawfile/logos.dat`**（单文件），
   *   本表的值因此从 `rf/lNN.dat` 变成包内条目名 `lNN`。
   * ★ 新增/换图流程（工具：`tools/pack_harmony_logos.ps1`）：
   *   ① 把新图（PNG）按掩码键 XOR 成 `lNN.dat` 放回 `rawfile/rf/`，并在本表加一行；
   *   ② `powershell -File tools/pack_harmony_logos.ps1 -Apply` ⇒ 重新生成 `logos.dat`（自带自检）；
   *   ③ 确认无误后删掉 `rawfile/rf/*.dat`（git 可恢复），再 Build。
   * ⚠️ 编号只许增量（l79 起），**不要**从 l00 重排 —— 会静默覆盖别的台标。 */
  'iptv-0': 'l64',
  'iptv-1': 'l65',
  'iptv-2': 'l66',
  'iptv-3': 'l67',
  'iptv-4': 'l68',
  'iptv-5': 'l69',
  'iptv-6': 'l70',
  'iptv-7': 'l71',
  'iptv-8': 'l72',
  'iptv-9': 'l73',
  'iptv-10': 'l74',
  'iptv-11': 'l75',
  'iptv-12': 'l76',
  'iptv-13': 'l77',
  'iptv-14': 'l78'
};

/** 按频道 id 获取**台标资源包条目名**（`rawfile/logos.dat` 内的 `lNN`）；无图标返回空字符串。
 *  ⚠️ 2026-10-01 起不再是文件路径 ⇒ 读取方必须走 `Index.ets` 的 `logoEntry()`。 */
export function channelIcon(id: string): string {
  return CHANNEL_ICONS[id] ?? '';
}

/** 源标错 PAR 的台（键=频道名）：按 16:9 摆画面 */
export const ASPECT_OVERRIDES: Record<string, number> = {
  '哈尔滨电影': 16 / 9,
  '哈尔滨综合': 16 / 9,
  '农林卫视': 16 /9
};
