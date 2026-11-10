/**
 * Index.ets —— 掌上电视（gate4：频道列表 → 自动取流 → 明文播放）
 *
 * ★ 界面/交互**照搬原鸿蒙版**（`D:\TV\CCTV\CctvPoC\...\pages\Index.ets`）：
 *   深色主题（底 #0a0a0a / 卡 #1e1e1e / 主蓝 #2f6bff / 当前台红 #ff3b3b / 当前节目红 #ff4444）
 *   状态栏（状态圆点 + 状态文字；**不再有加载指示器**，见 `statusBar()` 内注释）
 *   播放区（原生 AVPlayer + XComponent surface，明文由本地代理产出）
 *   胶囊 Tab（CCTV / 卫视 / 本地）+ 圆形台标网格（竖屏 5 列、横屏 3 列）
 *   当前/下一节目条 + 「接下来精彩内容」8 小时节目单 + EPG 弹层
 *
 * ★ 与原版的核心差异：**不再需要 ArkWeb / hls.js / /sapi 脚本注入**（相关遗留模块已全部删除）
 *   - 取流：`YspLive`（**自研 cKey** → `liveinfo.ysp.cctv.cn` 安卓平台 → **明文** playurl）
 *   - 解密：**没有**（2026-11-07 起 CMG 解密核已整条移除；这条路给的就是明文流）
 *   - 播放：media.AVPlayer + XComponent(SURFACE)（真正的原生 AVPlayer，音量可控）
 *
 * 数据流：频道 → YspLive.resolveLive() → 上游明文 m3u8（带一次性令牌）
 *        → LocalProxyServer.yspPlaylistUrl()（只转发、带 UID/UA）→ Video 播放
 * 江苏台 / IPTV 直链见各自分支（同样明文，前者经代理转发，后者直连）。
 */
import { common, bundleManager } from '@kit.AbilityKit';
/** ★ 2026-09-24：首启免责声明的"只弹一次"标记（`ohos.data.preferences`，本工程首个持久化项） */
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
/** 全屏 / 横竖屏（沿用原鸿蒙版 CctvPoC/Index.ets 的实现方式） */
import { window as ohWindow, display } from '@kit.ArkUI';
/** ★ 原生播放层：media.AVPlayer（配 XComponent surface 渲染）——真正的原生 AVPlayer */
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { LocalProxyServer, SegStat } from '../common/LocalProxyServer';
/* ★★★ 2026-11-07：央视频**唯一**取流链路 —— 自研 cKey → liveinfo（安卓平台）→ 明文 HLS ★★★ */
import { YspPlayInfo, resolveLive, resolveFrom, lastResolveError, warmDns, warmHostOf } from '../common/YspLive';
/** ★ 自研 cKey 门面（native `libpalmtv_napi.so`）+ 启动自检 */
import { SelfCKey } from '../common/SelfCKey';
/** ★ 台标等"去明文"资产的 XOR 掩码（原在 CmgNative 里，CMG 删除后搬到这里） */
import { unmask } from '../common/AssetMask';
import { Channels, CctvChannel, channelsByGroup, channelIcon, isJstvChannel, isIptvChannel, isLocalDirectChannel, ASPECT_OVERRIDES } from '../common/ChannelList';
/** ★ 江苏台（本地台）：取流来源信息（上游主机 / 频道表 / 签名） */
import { JSTV_ORIGIN } from '../common/JiangsuTv';
import { decodeEpgProtobuf } from '../common/ProxyEpg';
import { YspAppId, Ua } from '../common/CctvConfig';
/** ★ 播控中心/锁屏的媒体会话（2026-09-16 补齐；module.json5 早已声明 audioPlayback 但没有对应代码） */
import { TvSession } from '../common/TvSession';
/** ★★ 2026-10-02（用户要求：鸿蒙也要有自定义 IPTV 源，且与桌面端一致）★★
 *   规则/存储都与桌面 `IptvChannels.cs`、安卓 `IptvSources.kt` 相同：同 m3u 格式、同文件名
 *   `iptv-local.m3u`、校验/空名取域名/剥后缀/内置优先去重。 */
import { IptvEntry, loadFile as iptvLoadFile, saveFile as iptvSaveFile, filePath as iptvFilePath, mergeIntoChannels, userChannelCount, parseM3u, validateUrl as iptvValidate, nameOrHost as iptvNameOrHost, stripQuality as iptvStripQuality } from '../common/IptvSources';
/** ★ 音频焦点（AudioSession，恒 SHARE/MIX 不独占）+ 来电/其它应用打断（AVPlayer.on('audioInterrupt')） */
import { AudioFocus } from '../common/AudioFocus';
import { audio } from '@kit.AudioKit';
import { Log } from '../common/Log';

interface EpgItem {
  title: string;
  start: string;   // HH:mm
  end: string;
  now: boolean;
  /** ★ 原始时间戳（ms）：节目跨点时用它**在本地重新判定**"正在播出"，无需重新请求接口 */
  startMs: number;
  endMs: number;
  /** ★ 2026-11-08：官方是否允许回看（EPG protobuf 字段 [10]，`"2"` = 不可回看；缺字段 = 允许）。
   *   只判"已播完"会给版权原因不可回看的节目也画上「回看」⇒ 点了必然失败（安卓踩过）。 */
  replayable: boolean;
  /** ★ 2026-11-08：该节目属于哪一天（`yyyyMMdd`）。节目单扩到「前 6 天 ~ 后 3 天」后，
   *   弹窗要按天分组（安卓 `Epg.groupByDay` 同款）。
   *   ★ 2026-11-10：**由节目自身的开始时间戳推出**（不再直接用请求参数里的日期）——
   *     央视频的 EPG「一天」是 06:00 → 次日 06:00，跨零点那档节目的 start 属于前一天，
   *     用请求日期会把它归错天；更关键的是服务端万一给错数据（请求未来日却返回今天的时刻），
   *     按时间戳归天能让"未来日期没有已播节目"这条判据天然成立。 */
  ymd: string;
}

/**
 * ★ 2026-11-10：节目单弹窗的**一行视图模型** —— 颜色 / 字重 / 右侧标记 / ForEach 键值都在
 * `epgRows()` 里一次算好，`build` 只做纯渲染。
 *
 * 为什么必须这样（真机 BUG 根因，别再改回去）：
 *   ArkUI 的 `ForEach` **按 key 复用子组件：key 相同的行不会重建**。
 *   原来 key 是 `${idx}-${it.start}`（例：`0-06:00`），而 CCTV-4K/8K 的节目单每天都是
 *   "06:00 起、同一批时刻"⇒ 切换日期时几乎每一行的 key 都撞上，于是屏幕留着**上一天渲染的**字样：
 *     · 今天「直播中」红粗 ⇒ 切到别的日期，那一行仍是红粗（看起来"别的日期也在播"）；
 *     · 往日满屏「回看」 ⇒ 切到未来日期，仍是满屏「回看」（用户报的第二个 BUG）。
 *   ⇒ key 必须带上 **ymd + startMs + 状态**（凡影响显示的都要进 key）。
 */
interface EpgRow {
  /** ForEach 键：`ymd#startMs#行号#状态#颜色`（任一项变化 ⇒ 该行重建） */
  key: string;
  /** `HH:mm-HH:mm` */
  startText: string;
  title: string;
  color: string;
  bold: boolean;
  /** 右侧状态文案（空串 = 不画标记） */
  label: string;
  labelColor: string;
  labelSize: number;
  labelBold: boolean;
  /** `epgRowState` 的结果（1 回看中 / 2 直播中 / 3 回看 / 4 不可回看 / 0 普通） */
  state: number;
  item: EpgItem;
}

/** 频道分组（必须与 ChannelList.channelsByGroup 的入参类型一致，否则 ArkTS 编译报 union 不匹配） */
type ChannelGroup = 'cctv' | 'satellite' | 'local';
const TAB_CCTV: ChannelGroup = 'cctv';
const TAB_SAT: ChannelGroup = 'satellite';
const TAB_LOCAL: ChannelGroup = 'local';

/**
 * 信息栏 / 节目条高度（vp）——**仅作视频区兜底估算**用（真正的尺寸由 `playerArea` 的
 * 布局权重决定、再由 onAreaChange 实测，见 `videoAreaW/H`）。
 * ⚠️ 不要再回到"用实测栏高反推视频区高度"那套：试过两轮都溢出（节目条被挤出屏）。
 */
const STATUS_BAR_H0: number = 33;
const EPG_STRIP_H0: number = 38;
/** ★ EPG 网络重刷间隔（原版 ≥60s 才走一次网络；期间只做本地时钟推进） */
/**
 * ★ 2026-11-09（用户要求）：节目单**每 30 秒**向服务端对齐一次（原来 60s）。
 *   · ticker 本身仍是 10s 粒度（只做**本地**时间推进，零网络开销）；
 *   · 真正走网络的门槛由这个常量控制 = 30s；
 *   · 每次只重拉**今天**那一天（10 天全量只在换台/回前台时拉），否则 30s × 10 天 = 请求过密。
 */
const EPG_REFRESH_MS: number = 30000;
/**
 * ★ 2026-09-24：首启「内容来源与免责声明」正文（**请谨慎改动**：改了同时要改 `discVer` 让它重建后再弹一次）。
 * 口径要点（上架/合规角度）：① 本应用只是**播放器**，不提供/不存储/不制作内容；
 *   ② 播放地址与台标来自互联网公开渠道（GitHub、Gitee 等开源项目、电视台公开直播地址）；
 *   ③ 版权归原权利人、不担保；④ 侵权可联系移除；⑤ 禁止商用/二次分发，使用者自负合规。
 */
const DISCLAIMER_TEXT: string =
  '1. 本应用为纯播放器客户端，自身不提供、不存储、不制作任何音视频内容。\n\n' +
  '2. 所有频道的播放地址（直播流）与台标图片均来自互联网公开渠道，包括 GitHub、Gitee 等开源项目' +
  '以及各地电视台公开发布的直播地址，仅用于网络流媒体播放技术的演示与个人学习。\n\n' +
  '3. 音视频内容的著作权、播出权及解释权归原电视台或相应权利人所有；' +
  '本应用不对其合法性、准确性、完整性与可用性作任何担保。\n\n' +
  '4. 若权利人认为本应用展示或播放的内容侵犯其合法权益，请通过下方联系方式告知我们，核实后将及时移除相关来源。\n\n' +
  '5. 请勿将本应用用于商业用途或二次分发；使用者应自行确保其使用行为符合所在地区法律法规。';

/**
 * ★ 2026-09-24：**举报 / 联系渠道**（内容侵权投诉、源失效反馈、其它意见都用它）。
 * ⚠️ 改这里不用动 `discVer`（它不是声明正文的一部分）；但**声明正文里若引用了它，就一起改版号**。
 */
const CONTACT_EMAIL: string = '162004332@qq.com';
const CONTACT_LABEL: string = '举报 / 联系：';

/**
 * ★★ 网络恢复自动续播参数（2026-09-15）★★
 *   用户实测：断网 → 立刻恢复网络后，App 停在"播放出错"不动了。
 *   ⇒ 网络类失败后按 5s 间隔自动重试，最多 24 次（≈2 分钟）；一旦出画就归零。
 */
const NET_RESUME_GAP_MS: number = 5000;
const NET_RESUME_MAX: number = 24;
/** 断网判定窗口（ms）：此窗口内的播放器 error/异常只告警、不重建播放器（重建也没用，纯浪费） */
const NET_DOWN_WINDOW_MS: number = 15000;
/**
 * ★★ 2026-09-23：「无信号 ⇒ 回退原台」两个参数（用户实测：IPTV 源常失效，却把画面卡死）
 *
 * · `IPTV_PROBE_TIMEOUT_MS` —— IPTV 外部直链**起播前预检**超时，语义与桌面端
 *   `windows/MainWindow.xaml.cs` 的 `IptvSourceAliveAsync`（6 秒）**一致**：
 *   超时/连不上 ⇒ 判不可用 ⇒ **根本不换播放器**（画面/声音全程还是原台，不会起黑屏）。
 * · `LOCAL_DIRECT_NOPIC_MS` —— 江苏台/IPTV 这类**不经本地代理**的台"多久没出画算无信号"。
 *   央视频链路用"8 秒内本地代理有没有分片"判断；直连台没有这个统计，只看播放器是否进过
 *   `playing` ⇒ 见 `armAutoRetry`。
 */
const IPTV_PROBE_TIMEOUT_MS: number = 6000;
/**
 * ★★ 2026-10-02：**三端统一为 15s**（原 12s）★★
 *   用户实测："安卓端的判断无信号检测花时比鸿蒙长很久" —— 安卓那边是 18s（2026-10-02 为容忍
 *   金鹰卡通那种"分片 5.4 MB / 7.9 s"的慢源而上调），鸿蒙是 12s ⇒ 同一台无信号，两端等待差 6 秒。
 *   ⇒ 取中间值 **15s 统一**（金鹰卡通在安卓上首帧天然≈12s ⇒ 15s 仍留 3s 余量；鸿蒙 AVPlayer 起播更快，
 *     15s 也远够）。
 *   ⚠️ 这条同时影响"回退后的原台能不能来得及出画"：窗口太短会把**能播但慢**的原台也判成无信号，
 *     于是回退条幅被后面那句"信号中断，正在自动重试…"顶掉（用户实测的两种表现就是同一个根因）。
 */
const LOCAL_DIRECT_NOPIC_MS: number = 15000;
/**
 * ★ 回前台"**轻量恢复**（复用同一个本地 m3u8 URL 重建播放器）"的适用上限（2026-09-18 C3）。
 *   实测依据：22s 后台后用同一 token 轻量恢复**成功**（12:39:33，1829ms 出画）⇒ 远端 token
 *   的有效期远大于原先假设的 10s；真过期时 `prepare` 会失败并自动退化为"完整重新拉流"。
 */
const REVIVE_SAME_URL_MAX_MS: number = 30000;
/* ⚠️⚠️ 2026-09-18：**"退后台宽限期（延迟退后台）"的设计已废弃**，教训留在这里，别再来第三次：
 *   ① 现象：用户"切后台马上回前台，卡画面不动"。
 *      实测（11:40:50）：`pause()` 后再 `play()` **调用成功**，但直播播放器**停在旧画面**，
 *      要等它下一次轮询 playlist 才继续（2.9~5.8s）⇒ **"暂停再恢复"本身就是卡的根源**。
 *   ② 于是曾改成"宽限 2500ms 内干脆不暂停/不退焦点/不挂代理"。结果更糟：
 *      **后台里 JS 定时器会被系统挂起** —— 2500ms 的定时器实际 **9.5s 后才执行**
 *      （11:49:41.191 退后台 → 11:49:50.718 才 `退后台宽限期已过`）⇒ 后台**真的持续播放了 9.5s**
 *      （音画都在响、音频焦点没还）⇒ 用户质疑"后台后还一直播放"，**设计作废**。
 *   ⇒ **终态（C3）**：`onPageHide` **立即、同步**完成全部退后台；
 *      回前台用 `reviveSameUrl()`"轻量恢复"（复用同一个本地 m3u8 URL 重建播放器，跳过 auth/签名/取流）。
 *   ⇒ **教训：不要在 `onPageHide` 里依赖 `setTimeout` 做后台清理。** */

/* ★ 2026-11-07：取流已改为**自研 cKey + 安卓平台 liveinfo**（`common/YspLive.ets`）。
 *   Web/PC 链路（`StreamResolver` + `ProxySigner` + `NativeSigner`）与 CMG 解密核**已全部删除**；
 *   native 侧只剩 `yspSelfGenCKey`（自研 cKey）与 `jstv*`（江苏台签名），见 `common/native/src/palmtv_napi.c`。 */

@Entry
@Component
struct Index {
  // ---------------- 状态 ----------------
  @State bootMsg: string = '正在初始化…';
  @State loading: boolean = false;
  @State videoSrc: string = '';
  @State playing: boolean = false;

  @State currentTab: ChannelGroup = TAB_CCTV;
  @State list: CctvChannel[] = [];
  @State activeChannelId: string = '';
  @State currentName: string = '未选择频道';
  /**
   * ★★ 2026-10-02（用户实测："无信号回退原台时，条幅信息认错了台"）★★
   *   **用户最后一次亲手点的频道 id**（只有频道宫格点击 / 播控切台才算）。
   *
   * 为什么需要它：自动回退（`fallbackToPlayingChannel`）会用 `playChannel(原台)` 把**原台**拉回来，
   *   之后原台若也判无信号，老写法会对它说"xxx 暂无信号，请点击其他频道" ——
   *   而 xxx 正是用户**没点过**的那个原台。用户实测：看 CCTV-1 时点无信号的广州电视 ⇒
   *   回退到 CCTV-1 后条幅却显示"CCTV-1 暂无信号，请点击其他频道"，看起来像"条幅认错了台"。
   * ⇒ 现在只有"失败的就是用户亲手点的那个台"才用那句口径；自动拉起的台改用中性的
   *   "信号中断，正在自动重试…"（不提台名，不指向用户没选过的台）。
   */
  private userPickedId: string = '';
  /**
   * ★★ 2026-10-02（用户实测："从地方台切广州台时，回退条幅被『信号中断，正在自动重试…』顶掉了"）★★
   *   **最近一次展示"已切回原台"提示的时刻**（`noticeNoSignal` 的"有原台可退"分支 / `fallbackToPlayingChannel`）。
   *   用途：接下来 5 秒内若又因"原台没出画"要走中性提示，**不动视频区浮层**（只改状态栏），
   *   免得把刚显示的回退提示顶掉 —— 原台多是 IPTV 直连、起播本来就慢，这一会儿没画是正常的。
   */
  private noticeFallbackAt: number = 0;
  /**
   * ★ 2026-09-21：「上一次真正出过画」的频道 id = 可回退的"原台"（见 `revertToPlayingChannel`）。
   *   写：播放器进 `playing`；清：进 `error`（已死的台不能再当回退目标，否则会谎报"播放中"）。
   */
  private lastPlayingId: string = '';
  @State iconMap: Record<string, image.PixelMap> = {};
  @State iconSize: number = 46;
  /** ★ 分组 Tab「苹果式分段控件」实测宽度（vp，已扣左右 padding）—— 滑块宽度 = 它/3 */
  @State tabBarW: number = 0;

  @State episodeNow: string = '-';
  @State episodeNext: string = '-';
  /** ★ 2026-11-08：**回看/时移起播时刻**（epoch 秒）；0 = 正在看直播。
   *   非 0 时节目条显示"回看中"并给出「返回直播」，同时所有"重新取流"都按这个时刻复现。 */
  @State replayStart: number = 0;
  /** 回看/时移的结束时刻（只有"节目单回看"才有：带上它服务端才给整段 VOD 清单） */
  private replayEnd: number = 0;
  /**
   * ★ 2026-11-09（对齐安卓 `replayIsProgram`）：本次回看是不是"**节目单里的整档节目**"。
   *   · true  = 点节目单里的已播节目 ⇒ 带 endtime（整段 VOD），**播完自动接下一档**；
   *   · false = 时移（手势 / 节目单里点"正在播出"）⇒ **不带 endtime**（滚动窗口，持续延迟直播，
   *     不会播几分钟就"完播"）。上一版时移也传了 endtime ⇒ 播到 now 就 completed ⇒ 自动回直播
   *     （用户实测："向左时移一次，一会就自动回直播了"）。
   */
  private replayIsProgram: boolean = false;
  /** ★ 时移的"延迟秒数"（= 起播时 now − playbacktime）；滚动窗口意外结束时按同样延迟续播 */
  private replayDelaySec: number = 0;
  /**
   * ★ 2026-11-09：**正在回看的那一档的"身份"**（`ymd` + `startMs`）。
   *   4K/8K 一天几十~两百多档、且大量 1 分钟短节目，只靠时间区间判定容易误命中
   *   ⇒ 列表里「回看中」只认这个身份完全相等的**一条**。
   */
  private replayKeyYmd: string = '';
  private replayKeyStart: number = 0;
  /** ★ 2026-11-08：节目单弹窗里选中的日期（`yyyyMMdd`；空 = 未选） */
  @State epgSelDay: string = '';
  @State epgItems: EpgItem[] = [];
  @State showEpg: boolean = false;
  /** ★ 状态灯：true = 播放出错（红点）；false = 正常播放（绿点）/待机（灰点） */
  @State playErr: boolean = false;
  /** ★ 全屏（横屏）模式：只显示视频，隐藏状态栏/节目条/频道栏 */
  @State isFullscreen: boolean = false;
  /** EPG 弹层滚动控制器（List 的 scrollToIndex 才支持 ScrollAlign.CENTER 精确定位） */
  private epgListScroller: ListScroller = new ListScroller();
  /** ★ 2026-11-09：日期行的滚动器（把"当前节目所在那天"滚到弹窗**中间**） */
  private epgDayScroller: ListScroller = new ListScroller();
  /** ★ 视频区中央提示（无流/暂停提供信号等，原版风格浮层），**2 秒自消**（原 5 秒） */
  @State videoNotice: string = '';
  private noticeTimer: number = -1;
  /* ---------------- 播放控制条 / 手势（全部走原生 API，原版那套 evalJs 是 WebView 时代的） -------- */
  /** 控制条是否可见（单击视频切换；全屏时 3 秒自动隐藏） */
  @State controlsVisible: boolean = true;
  /** 全屏锁屏：锁定后隐藏控制条、禁用手势，仅左上锁按钮可操作 */
  @State screenLocked: boolean = false;
  /** 静音（原生 Video.muted） */
  @State muted: boolean = false;
  /** 手势提示文案（"音量 60%" / "亮度 40%"），800ms 自消 */
  @State gestureHint: string = '';
  private controlsTimer: number = -1;
  /** 窗口对象（全屏/亮度都用它；在 bootSequence 里取到后缓存） */
  private winObj: ohWindow.Window | null = null;
  /**
   * 当前亮度（-1 = 跟随系统）。
   * ⚠️ 名字不能叫 `brightness`：ArkUI 的 `CustomComponent` 自带通用属性 `brightness(value)`，
   *    同名字段会编译报 "Property 'brightness' is not assignable to ... base type 'CustomComponent'"。
   */
  private curBrightness: number = -1;
  /** 手势起点：音量比例 / 亮度值 */
  private gestureActive: boolean = false;
  /** ★ 2026-11-09：手势时移的**待结算目标**（epoch 秒；0 = 本次手势没有位移） */
  private shiftPendingSec: number = 0;
  /** ★ 手势里已兑现的 ±10 步数（由累计位移换算，避免同一段位移重复加） */
  private shiftSteps: number = 0;
  /**
   * ★ 2026-11-09（对齐安卓 `shiftOffsetSec`）：本次手势**累计位移**（正 = 往前进、负 = 往后退）。
   *   直播态的 OSD 用它算"落后多少秒"：第一下左滑显示「时移 -10 秒」而不是 -12 秒
   *   （原来用 `now - target`，把"直播沿 now-2"那 2 秒也算进去了，用户已指出这个数不对）。
   */
  private shiftAccumSec: number = 0;
  private gestureStartRatio: number = 0.5;
  private gestureStartBri: number = 0.5;
  /** 视频区宽度（判断手势在左半屏还是右半屏）
   *  ★ 必须 @State：它同时用于画面尺寸计算，普通成员在 onAreaChange 里改了**不会重建** ⇒
   *   旋转/进出全屏后画面仍是旧尺寸（真机症状：横屏时信息栏/节目条与画面左右对不齐、全屏后画面没变大） */
  @State videoZoneWidth: number = 0;
  /* ---------------- ★ 原生播放层：media.AVPlayer + XComponent(SURFACE) ----------------
   * 之前用的是 ArkUI `Video` 组件：它虽属原生组件，但**不暴露 AVPlayer 句柄** ⇒
   *   只有 `muted` 属性、没有 volume ⇒ 音量手势无法生效（用户实测确认）。
   * 现在改为自己 createAVPlayer() + XComponent surface 渲染：
   *   `AVPlayer.setVolume(0.0~1.0)` 可控音量；`videoScaleType` 默认 FIT（保持宽高比、不裁切）。 */
  private avPlayer: media.AVPlayer | null = null;
  private xcController: XComponentController = new XComponentController();
  /** XComponent surface id（onLoad 时取得，prepare 之前必须设置给 AVPlayer） */
  private surfaceId: string = '';
  /* ★ 音量策略：手势改的是**播放器自身音量**（`AVPlayer.setVolume`，0~1）。
   *   ⚠️ 早期照搬原版用 `AudioManager.setVolume` 改**系统媒体音量**（audioMgr/volMin/volMax
   *   那套），但它是 deprecated API 且需 ACCESS_NOTIFICATION_POLICY 权限 ⇒ 已整体移除，
   *   改为播放器音量（与系统音量叠加，符合应用侧规范）。 */
  /** 播放器音量比例 0~1（手势起点用） */
  private volRatio: number = 0.5;
  /** 视频分辨率（由 videoSizeChange 上报，用于按比例显示、避免拉伸）
   *  ★ 必须 @State：它参与画面尺寸计算，普通成员改了不触发重建 ⇒ 分辨率变化后画面尺寸不更新 */
  @State videoW: number = 0;
  @State videoH: number = 0;
  /** ★ 2026-09-24：当前**画面上已生效**的宽高比修正（0 = 不干预）。
   *  为什么不在渲染时用 `currentName` 现查表：`playChannel` 一进来就把 `currentName` 改成新台，
   *  而旧画面此时**还挂在屏上**（旧播放器是异步 release）⇒ 修正被提前撤销，表现为
   *  "换台瞬间旧画面先弹回默认尺寸、再切到新台"（用户实测）。改为**新台 prepared 时**才切换。 */
  @State videoArFix: number = 0;
  /** ★ 2026-09-24：首启免责声明弹窗（只在未同意过时显示；点"同意"后写 preferences） */
  @State showDisclaimer: boolean = false;
  /**
   * ★ 2026-09-29：本次弹窗是不是"**再次查看**"（从关于页「查看完整声明」进入）。
   *   true  ⇒ **不显示"不同意并退出"**（用户早已同意过，那一步逻辑上不该再出现；与桌面端同口径），
   *           按钮变成「关闭」，关掉不改任何状态、不写标记；
   *   false ⇒ 首启流程：必须主动"我已阅读并同意"，否则退出应用。
   */
  @State disclaimerReadOnly: boolean = false;
  /** ★★ 2026-09-24：第 4 个 Tab「关于」（与三个频道分组互斥；为 true 时中间区域显示关于页） */
  @State aboutTab: boolean = false;
  /* ★★ 2026-10-02：自定义 IPTV 源编辑弹窗（交互与桌面 `IptvSourceWindow` 一致：
   *   列表点选 + 频道名/地址两个输入框 + 添加到列表 / 更新选中 / 删除选中 + 取消 / 保存并生效） */
  @State showIptv: boolean = false;
  @State iptvRows: IptvEntry[] = [];
  @State iptvSel: number = -1;
  @State iptvName: string = '';
  @State iptvUrl: string = '';
  @State iptvErr: string = '';
  @State iptvHint: string = '';
  @State iptvImportText: string = '';
  @State iptvShowImport: boolean = false;
  /** 应用版本号（启动时从 bundleManager 读，读不到就显示 '-'） */
  @State appVersion: string = '-';
  /** 声明的版本号：改动文案时改这个值 ⇒ 老用户升级后也会再弹一次 */
  private discVer: string = 'disc_v2';   // ★ 文案已加"联系方式" ⇒ 升版号，老用户升级后会再弹一次
  /** 下一次进 `prepared` 时要应用的修正值（`playChannel` 里按频道名查表得到） */
  private pendingArFix: number = 0;
  /** 窗口宽高（vp，用于按比例计算视频显示尺寸）——同样必须 @State（旋转/进出全屏都会变） */
  @State winW: number = 0;
  @State winH: number = 0;
  /** 是否横屏（窗口宽 > 高；横屏走"左视频 + 右频道"布局） */
  @State isLandscape: boolean = false;
  /** 视频区实际可用高度（同上，必须 @State 才能在量到新尺寸后重建画面） */
  @State videoZoneHeight: number = 0;
  /** 系统安全区（顶部状态栏 / 底部导航栏，vp）——横屏窗口模式下要避开，否则内容压到系统栏上 */
  private insetTop: number = 0;
  private insetBottom: number = 0;

  /** ★ 播控中心/锁屏的媒体会话（AVSession）——只创建一次，换台只更新 metadata；
   *  **退后台即销毁**（直播在后台不可靠，留卡片 = 留失效按钮），回前台重建 */
  private tvSession: TvSession | null = null;
  /** ★ 音频焦点（AudioSession，SHARE/MIX 不独占）；退后台归还、回前台/起播激活 */
  private audioFocus: AudioFocus | null = null;
  /** ★ 是否因音频打断（来电/其它应用抢焦点）而暂停 ⇒ 打断结束后才自动恢复 */
  private pausedByInterrupt: boolean = false;
  /* ★ 说明：退后台时刻统一用 `hideAt`（`onPageShow` 里按它算 `away`），
   *   不要再加第二个"后台起点"字段（曾有 `bgSince` 只写不读，属死代码，已删）。 */
  /**
   * ★ 后台发生过"播放器异常/需要重拉"（后台**不处理**，只登记）⇒ 回前台再恢复。
   *   为什么：直播暂停久了播放器必然报 error，后台重建 + 重拉 = 白下载 + 白解密 + 反复作废 token。
   */
  private needRecoverOnShow: boolean = false;
  /** ★ 分片失败累计值的"已打印水位"（只在增加时打日志，避免每 5 秒重复刷同一行） */
  private lastFailedSeen: number = 0;

  private server: LocalProxyServer = new LocalProxyServer();
  private statTimer: number = -1;
  /** ★ 节目单"跨点自动刷新"定时器句柄（-1 = 未挂） */
  private epgTimer: number = -1;
  /** 已拉取的 EPG 日期（yyyyMMdd）——用于跨天时自动重拉，避免过零点后节目单全过期 */
  private lastEpgDay: string = '';
  /** ★ EPG 上次**成功拿到**节目单的时间戳：≥60s 才允许再走一次网络（原版同款策略） */
  private lastEpgFetchAt: number = 0;
  /** ★ EPG 拉取失败后的重试定时器（-1 = 未挂）：旧实现失败就不管了 ⇒ 节目单永久停在"获取失败" */
  private epgRetryTimer: number = -1;
  /** ★ EPG 拉取的"进行中"标记（pid）：避免 60s 网络重刷与换台首拉**同时**发请求（真机日志里重复过一次） */
  private epgInflightPid: string = '';
  /** ★ 2026-11-09：周期性"只拉今天"是否在飞（与全量拉取互斥，避免同一时刻两个请求） */
  private epgTodayInflight: boolean = false;
  private playRequestId: number = 0;
  /** 首播看门狗：本轮是否已自动重试过（成功出片后复位，见 armAutoRetry） */
  private retried: boolean = false;
  /** 首播看门狗定时器句柄（-1 = 未挂） */
  private retryTimer: number = -1;
  /** 上次因 AVPlayer 网络错误自动重连的时间戳（节流，避免重连风暴） */
  private lastErrReplay: number = 0;
  /** 进入后台的时间戳（0 = 当前在前台）；回前台超过 10s 需重新拉流 */
  private hideAt: number = 0;
  /** ★ 退后台 `pause()` 的 Promise：`resumePlayback` 先等它落地再 `play()`（否则 pause 晚结算 ⇒ 停在 paused） */
  private pauseTask: Promise<void> | null = null;

  /** ★ 播放器异常重建次数（prepare 失败 / error 态时销毁重建；成功出画后归零） */
  private playerRebuilds: number = 0;
  /** ★★ 网络类失败的时间戳（0 = 网络正常）：用于抑制"断网期间的播放器重建/重拉风暴" */
  private netDownAt: number = 0;
  /** ★ 起播全链路打点：点击频道时刻（playChannel 里赋值） */
  private tClickChannel: number = 0;
  /** ★ 起播全链路打点：setupPlayer 开始时刻（setupPlayer 里赋值） */
  private tSetupStart: number = 0;
  /** ★★ 网络恢复自动续播定时器句柄（-1 = 未挂）与已重试次数 */
  private netResumeTimer: number = -1;
  private netResumeTries: number = 0;

  aboutToAppear(): void {
    this.list = channelsByGroup(this.currentTab);
    /* ★ 台标尺寸按**屏幕宽度**换算（不同分辨率自适应）：5 列布局，取列宽的 ~74%。
     *   原来固定 46vp ⇒ 大屏上偏小、小屏上偏大（真机上"台标显示不全/太小"）。 */
    try {
      const disp: display.Display = display.getDefaultDisplaySync();
      /* ★ 用 UIContext 版本消除 `px2vp` 的弃用警告。
       *   已核对 d.ts：`UIContext.px2vp` 是 **@since 22**，本工程 compatibleSdkVersion = 23 ⇒ 可用 ✓
       *   （之前我误以为工程 API 更低而改回全局版，属误判。） */
      const vpW: number = this.getUIContext().px2vp(disp.width);
      /* 5 列布局：留 16vp 页边距，每列用 88%（原 74% 偏小、四周留白过多）
       * 376vp 屏 ⇒ 列宽 72vp ⇒ 台标 ≈63vp（原来是 52vp） */
      this.iconSize = Math.max(48, Math.floor(((vpW - 16) / 5) * 0.88));
      this.winW = vpW;
      this.winH = this.getUIContext().px2vp(disp.height);
      Log.i(`[Index] 台标尺寸=${this.iconSize}vp（屏宽 ${Math.round(vpW)}vp）`);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`[Index] 取屏幕尺寸失败，用默认台标尺寸: ${err.message}`);
    }
    /* ★ 音频焦点：只初始化（激活交给起播/回前台），会话被系统停用时暂停播放 */
    this.audioFocus = new AudioFocus((reason: string): void => {
      this.onAudioSessionLost(reason);
    });
    this.audioFocus.init();
    this.bootSequence();
  }

  aboutToDisappear(): void {
    /* ★ 2026-09-16：这里原来只清了 statTimer，其余 6 个定时器会残留到页面销毁之后
     *   （EPG ticker / EPG 重试 / 首播看门狗 / 控制条自动隐藏 / 浮层自消 / 网络续播轮询）
     *   ⇒ 统一清干净；并恢复屏幕常亮、销毁 AVSession（否则播控中心留一张僵尸卡片）、归还音频焦点。 */
    this.clearAllTimers();
    this.applyKeepScreenOn(false);
    const ts: TvSession | null = this.tvSession;
    if (ts !== null) {
      ts.destroy();
      this.tvSession = null;
    }
    const af: AudioFocus | null = this.audioFocus;
    if (af !== null) {
      af.deactivate();
    }
    this.videoSrc = '';
    this.server.stop().catch((e: Error) => {
      Log.w(`[Index] 停止本地代理失败: ${e.message}`);
    });
  }

  /**
   * ★ 音频会话被系统停用 ⇒ 暂停播放，**不自动恢复**。
   *   直播没有"续播点"的概念，等用户自己回来点更符合直觉；否则容易出现"声音自己又响了"。
   *
   * ★ 2026-09-17：**按 reason 区分文案**（原来一律写"被其他应用占用"，会误导排查）。
   *   SDK 定义（`@ohos.multimedia.audio.d.ts`）：
   *     `DEACTIVATED_LOWER_PRIORITY = 0` —— 被更高优先级的应用抢占；
   *     `DEACTIVATED_TIMEOUT = 1`        —— **超时**：长时间没有音频输出，系统回收会话
   *       （真机实测：点开频道后**整 60 秒**触发；若取流/解密失败而从未真正出声，必然走到这里）。
   */
  private onAudioSessionLost(reason: string): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p !== null && (p.state === 'playing' || p.state === 'prepared')) {
      p.pause().catch((e: BusinessError) => {
        Log.w(`[Index] 音频会话失效后暂停失败: ${e.message}`);
      });
    }
    this.playing = false;
    const timeout: boolean = reason === '1';
    this.bootMsg = timeout
      ? `${this.currentName} 长时间无声音，已暂停`
      : `${this.currentName} 音频被其他应用占用，已暂停`;
    Log.w(`[Index] 音频会话被停用（reason=${reason}${timeout ? '=超时' : '=被抢占'}）⇒ 已暂停（不自动恢复）`);
  }

  /** 清掉所有定时器（页面销毁时用，避免回调打到已销毁的页面） */
  private clearAllTimers(): void {
    if (this.statTimer >= 0) {
      clearInterval(this.statTimer);
      this.statTimer = -1;
    }
    this.stopEpgTicker();
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.controlsTimer !== -1) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
    if (this.noticeTimer !== -1) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
    this.cancelNetResume();
  }

  private hostContext(): common.UIAbilityContext | undefined {
    try {
      const c = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (c) {
        return c;
      }
    } catch (e) {
      Log.w(`[Index] getHostContext 异常: ${(e as Error).message}`);
    }
    try {
      return getContext(this) as common.UIAbilityContext;
    } catch (e) {
      Log.e(`[Index] getContext 兜底失败: ${(e as Error).message}`);
      return undefined;
    }
  }

  /** 启动序列：DNS 预热 → 自研 cKey 自检 → 窗口/台标 → 本地代理（播放前 ensureStarted） */
  private async bootSequence(): Promise<void> {
    /* ★★ DNS/TLS 预热（fire-and-forget，失败忽略）：把 liveinfo / capi / CDN 的握手在后台做掉 ★★ */
    warmDns();
    const ctx = this.hostContext();
    if (!ctx) {
      this.bootMsg = '无法获取 UIAbilityContext';
      return;
    }
    try {
      /* ★★ 2026-11-07：不再有 CMG 资产落盘 / native init / 真实墙钟设置 —— 那套已整条移除。
       *   现在只自检一件事：**自研 cKey 的 native 接口是否真的存在**（release 混淆把属性名改掉时
       *   会在这里立刻暴露，而不是等用户点频道才报"取流失败"）。 */
      if (!SelfCKey.ensure()) {
        this.bootMsg = 'native 模块异常（自研 cKey 不可用）';
        return;
      }

      // ★ 允许跟随系统自动旋转（原版做法：初始化就设，否则要先点一次全屏再退出才会响应横屏）
      ohWindow.getLastWindow(ctx).then((w: ohWindow.Window) => {
        this.winObj = w;          // 全屏 / 亮度都复用它
        /* ★ 监听窗口尺寸：横竖屏切换时重排（横屏 = 左视频 + 右频道） */
        /* ★ 系统安全区（顶部状态栏 / 底部导航栏）：横屏窗口模式要避开，否则视频会压到导航栏上 */
        this.readInsets(w);
        w.on('windowSizeChange', (size: ohWindow.Size) => {
          this.winW = this.getUIContext().px2vp(size.width);
          this.winH = this.getUIContext().px2vp(size.height);
          this.readInsets(w);   /* ★ 旋转/系统栏显隐都会改变安全区，必须重读 */
          const land: boolean = size.width > size.height;
          if (land !== this.isLandscape) {
            this.isLandscape = land;
            Log.i(`[Index] 窗口 ${size.width}x${size.height} ⇒ ${land ? '横屏' : '竖屏'}`);
          }
        });
        w.setPreferredOrientation(ohWindow.Orientation.AUTO_ROTATION).catch((e: BusinessError) => {
          Log.w(`[Index] 设置自动旋转失败: ${e.message}`);
        });
        w.setWindowSystemBarEnable(['status', 'navigation']).catch((e: BusinessError) => {
          Log.w(`[Index] 系统栏设置失败: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        Log.w(`[Index] 获取窗口失败: ${e.message}`);
      });

      await this.server.start();
      /* ★ 播控中心/锁屏媒体会话（AVSession）：只建一次，失败只告警（不影响播放） */
      await this.initTvSession(ctx);
      this.bootMsg = '就绪';

      // 台标（动态名必须走 resourceManager，$r 不支持动态名）
      await this.loadIcons(ctx);
      /* ★ 2026-10-02（与桌面端 `MainWindow.Window_Loaded` 里的 `IptvChannels.Load()` 同位置同语义）：
       *   启动时把用户自定义 IPTV 源并进频道表；必须在**首次列表渲染之前**做。 */
      this.reloadCustomIptv();
      /* ★ 2026-09-24：首次启动（或声明文案升版）⇒ 弹一次免责声明/内容来源说明。
       *   失败一律**按"该弹"处理**（合规优先），只记日志。 */
      try {
        const store: preferences.Preferences = await preferences.getPreferences(ctx, 'palmtv');
        const agreed: string = String(await store.get('disc', ''));
        this.disclaimerReadOnly = false;   // ★ 首启流程（不是"再次查看"）⇒ 保留"不同意并退出"
        this.showDisclaimer = (agreed !== this.discVer);
        if (this.showDisclaimer) {
          Log.i('[Index] 首启免责声明 ⇒ 弹窗');
        }
      } catch (e) {
        this.disclaimerReadOnly = false;
        this.showDisclaimer = true;
        Log.w(`[Index] 读免责声明标记失败（仍弹窗）: ${(e as Error).message}`);
      }
      /* ★ 关于页要显示**真实版本号**（别硬编码）：从包信息里读 */
      try {
        const bi: bundleManager.BundleInfo =
          bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        this.appVersion = bi.versionName;
      } catch (e) {
        Log.w(`[Index] 读版本号失败: ${(e as Error).message}`);
      }
      // 统计（分片失败累计；只在"失败数增加"时打印，避免每 5 秒重复刷同一行）
      this.statTimer = setInterval(() => {
        const st: SegStat = this.server.getStat();
        if (st.failed > this.lastFailedSeen) {
          Log.w(`[Index] 分片拉取失败累计 ${st.failed} 个（新增 ${st.failed - this.lastFailedSeen}）`);
          this.lastFailedSeen = st.failed;
        }
      }, 5000);

      /* ★ 2026-11-09（用户要求）：**启动即自动播放上次看的台**，没有记录则 CCTV-1。
       *   放在最后：native/代理/台标/免责声明都就绪后再起播，避免"先黑屏再重来"。 */
      await this.autoPlayOnBoot();
    } catch (e) {
      const err = e as BusinessError;
      this.bootMsg = `启动异常: ${err.message}`;
      Log.e(`[Index] bootSequence 异常: ${err.message}`);
    }
  }

  /** ★ 2026-11-09：记住"上次观看的频道 id"（启动自动播放用；失败只记日志） */
  private saveLastChannel(id: string): void {
    const ctx = this.hostContext();
    if (!ctx || id.length === 0) {
      return;
    }
    preferences.getPreferences(ctx, 'palmtv').then((store: preferences.Preferences) => {
      store.put('lastCh', id).then(() => store.flush()).catch((e: BusinessError) => {
        Log.w(`[Index] 记录上次频道失败: ${e.message}`);
      });
    }).catch((e: BusinessError) => {
      Log.w(`[Index] 打开偏好存储失败: ${e.message}`);
    });
  }

  /**
   * ★ 2026-11-09（用户要求）：**启动自动播放"上次的节目"**，没有记录就用 CCTV-1。
   *   · 免责声明还没同意 ⇒ 不播（先让用户看声明）；
   *   · 已经在播（回前台/热启动）⇒ 不重复起播；
   *   · 记的台已被删除（自定义 IPTV 源被清理）⇒ 回落到 CCTV-1。
   */
  private async autoPlayOnBoot(): Promise<void> {
    if (this.showDisclaimer) {
      Log.i('[Index] 免责声明未同意 ⇒ 启动不自动播放');
      return;
    }
    if (this.activeChannelId !== '' || this.avPlayer !== null) {
      return;
    }
    let lastId: string = '';
    try {
      const ctx = this.hostContext();
      if (ctx) {
        const store: preferences.Preferences = await preferences.getPreferences(ctx, 'palmtv');
        lastId = String(await store.get('lastCh', ''));
      }
    } catch (e) {
      Log.w(`[Index] 读上次频道失败（用 CCTV-1）: ${(e as Error).message}`);
    }
    let ch: CctvChannel | undefined = lastId.length > 0
      ? Channels.find((c: CctvChannel) => c.id === lastId) : undefined;
    const fromLast: boolean = ch !== undefined;
    if (ch === undefined) {
      ch = Channels.find((c: CctvChannel) => c.id === 'cctv1');
    }
    if (ch === undefined) {
      return;
    }
    const target: CctvChannel = ch;
    Log.i(`[Index] 启动自动播放 ${target.name}（${fromLast ? '上次观看' : '默认 CCTV-1'}）`);
    await this.playChannel(target, false);
  }

  /**
   * ★ 建立 AVSession（播控中心 / 锁屏的媒体卡片）。
   *   为什么必须做：`module.json5` 早就声明了 `backgroundModes:["audioPlayback"]` +
   *   `KEEP_BACKGROUND_RUNNING`，注释也写着"保持 AVSession 活跃"，但工程里**没有任何
   *   AVSession 代码** ⇒ 播控中心/耳机/锁屏的播放键点不动，声明也没有对应的能力。
   *   播控命令 → 回调到这里（真正的播放器与频道列表在页面里）：
   *     play/pause 直接操作 AVPlayer（**后台也能生效**，这是 audioPlayback 后台模式的意义）；
   *     playNext/playPrevious 在当前分组的频道列表里切上/下一台。
   */
  private async initTvSession(ctx: common.UIAbilityContext): Promise<void> {
    if (this.tvSession !== null) {
      return;
    }
    const s: TvSession = new TvSession({
      onPlay: () => {
        /* 播控中心按"播放"：能直接恢复就直接恢复，否则重走取流 */
        const p: media.AVPlayer | null = this.avPlayer;
        if (p !== null && (p.state === 'prepared' || p.state === 'paused' || p.state === 'playing')) {
          p.play().catch((e: BusinessError) => {
            Log.w(`[Index] 播控 play 失败 ⇒ 重新取流: ${e.message}`);
            this.replayOrWait();
          });
        } else {
          this.replayOrWait();
        }
      },
      onPause: () => {
        const p: media.AVPlayer | null = this.avPlayer;
        if (p !== null && p.state === 'playing') {
          p.pause().catch((e: BusinessError) => {
            Log.w(`[Index] 播控 pause 失败: ${e.message}`);
          });
        }
        this.pausedByInterrupt = false;   /* 用户主动暂停 ⇒ 不自动恢复 */
      },
      onStop: () => {
        const p: media.AVPlayer | null = this.avPlayer;
        if (p !== null) {
          p.stop().catch((e: BusinessError) => {
            Log.w(`[Index] 播控 stop 失败: ${e.message}`);
          });
        }
        const ts: TvSession | null = this.tvSession;
        if (ts !== null) {
          ts.setStopped();
        }
      },
      onNextChannel: () => { this.switchChannelBy(1); },
      onPrevChannel: () => { this.switchChannelBy(-1); }
    });
    this.tvSession = s;
    await s.init(ctx);
  }

  /** 在当前分组的频道列表里按 offset 切台（播控中心的上一台/下一台） */
  private switchChannelBy(offset: number): void {
    const list: CctvChannel[] = this.list;
    if (list.length === 0) {
      return;
    }
    let idx: number = list.findIndex((c: CctvChannel) => c.id === this.activeChannelId);
    if (idx < 0) {
      idx = 0;
    }
    const n: number = (idx + offset + list.length) % list.length;
    Log.i(`[Index] 播控切台 ⇒ ${list[n].name}`);
    this.playChannel(list[n]);
  }

  /**
   * ★ 播放时保持屏幕常亮（看电视的刚需：默认熄屏时间一到画面就黑）。
   *   进播放 = true；暂停/出错/退后台/退出页面 = false（把省电交回系统）。
   */
  private applyKeepScreenOn(on: boolean): void {
    const w: ohWindow.Window | null = this.winObj;
    if (w === null) {
      return;
    }
    w.setWindowKeepScreenOn(on).catch((e: BusinessError) => {
      Log.w(`[Index] keepScreenOn(${on}) 失败: ${e.message}`);
    });
  }

  /** ★★ 台标资源包（单个 `rawfile/logos.dat`，2026-10-01 起替代 79 个 `rawfile/rf/lNN.dat`）★★
   *   容器 = `PALMRES1\n`(9B) + u32 条目数 + 重复 { u16 名长 + 名(UTF-8) + u32 数据长 + 数据 }，
   *   整数一律**大端**；数据 = XOR 掩码后的 PNG（读取方 `AssetMask.unmask()` 再解码）。
   *   同一格式安卓侧也有一份（构建期 `packPalmRes` 任务），见 `Android/app/src/main/java/.../player/Logos.kt`。
   *   生成工具：`tools/pack_harmony_logos.ps1`。 */
  private logoPack: Map<string, Uint8Array> | null = null;

  /** 从资源包里取一个条目（条目名 = `channelIcon(id)` 给的 `lNN`）；失败返回 undefined（不抛）。 */
  private async logoEntry(ctx: common.UIAbilityContext, name: string): Promise<Uint8Array | undefined> {
    if (this.logoPack === null) {
      const map: Map<string, Uint8Array> = new Map<string, Uint8Array>();
      try {
        const raw: Uint8Array = await ctx.resourceManager.getRawFileContent('logos.dat');
        const buf: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
        const dv: DataView = new DataView(buf);
        const magic: string = 'PALMRES1\n';
        let ok: boolean = magic.length + 4 <= raw.byteLength;
        for (let i = 0; ok && i < magic.length; i++) {
          ok = dv.getUint8(i) === magic.charCodeAt(i);
        }
        if (!ok) {
          Log.e('[Index] logos.dat 头不对（用 tools/pack_harmony_logos.ps1 重新生成）');
        } else {
          const all: Uint8Array = new Uint8Array(buf);
          let p: number = magic.length;
          const count: number = dv.getUint32(p, false); p += 4;   // false = 大端
          for (let n = 0; n < count; n++) {
            const nl: number = dv.getUint16(p, false); p += 2;
            let nm: string = '';
            for (let i = 0; i < nl; i++) {
              nm += String.fromCharCode(dv.getUint8(p + i));       // 条目名都是 ASCII（lNN）
            }
            p += nl;
            const dl: number = dv.getUint32(p, false); p += 4;
            map.set(nm, all.subarray(p, p + dl));
            p += dl;
          }
          Log.i(`[Index] logos.dat 载入 ${map.size} 项（${raw.byteLength} B）`);
        }
      } catch (e) {
        Log.e('[Index] logos.dat 读取失败: ' + (e as Error).message);
      }
      this.logoPack = map;
    }
    return this.logoPack.get(name);
  }

  private async loadIcons(ctx: common.UIAbilityContext): Promise<void> {
    const next: Record<string, image.PixelMap> = {};
    /* ★★ 台标内存控制（2026-09-16）★★
     *   55 个台标 PixelMap 会**常驻内存**，而解码尺寸默认 = **源图尺寸**（RGBA_8888 = 4B/px：
     *   512×512 一张就 1MB，×55 = 55MB）。这里按"实际显示像素 ×1.25"给 desiredSize 设上限：
     *     - 源图更大 ⇒ 解码时就缩小（省内存，显示质量不受影响）；
     *     - 源图更小 ⇒ 保持原样（**绝不放大解码**，否则内存反而更费）。
     *   目标像素用 `UIContext.vp2px(iconSize)`（@since 22，本工程 API 23 ✓），拿不到就按 ×4 兜底。 */
    let wantPx: number = 0;
    try {
      wantPx = Math.ceil(this.getUIContext().vp2px(this.iconSize) * 1.25);
    } catch (e) {
      wantPx = Math.ceil(this.iconSize * 4);
    }
    wantPx = Math.max(96, wantPx);
    const tasks: Promise<void>[] = [];
    for (const ch of Channels) {
      tasks.push((async () => {
        try {
          const name: string = channelIcon(ch.id);
          if (name.length === 0) {
            return;
          }
          /* ★★ 2026-10-01：台标已从 79 个 `rawfile/rf/lNN.dat` **合并成单个 `rawfile/logos.dat`**
           *   （用户要求减少打包文件数）⇒ 这里改成"从包里取条目"，`unmask()` 那步不变。
           *   载荷仍是 XOR 掩码态；包格式见 `logoEntry()` 的注释。 */
          const packed: Uint8Array | undefined = await this.logoEntry(ctx, name);
          if (packed === undefined) {
            return;
          }
          const u8: Uint8Array = unmask(packed);
          /* ⚠️ 不能直接 `u8.buffer.slice(0, u8.buffer.byteLength)`：包内条目是 subarray（byteOffset≠0）
           *   ⇒ 必须拷成一份独立 ArrayBuffer 再交给 ImageSource，否则会拿到别人的字节。 */
          const bmpBuf: ArrayBuffer = new ArrayBuffer(u8.byteLength);
          new Uint8Array(bmpBuf).set(u8);
          const src: image.ImageSource = image.createImageSource(bmpBuf);
          const opts: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.RGBA_8888 };
          try {
            const info: image.ImageInfo = src.getImageInfoSync();
            const sw: number = info.size.width;
            const sh: number = info.size.height;
            const longest: number = Math.max(sw, sh);
            if (longest > wantPx && longest > 0) {
              const scale: number = wantPx / longest;
              opts.desiredSize = {
                width: Math.max(1, Math.round(sw * scale)),
                height: Math.max(1, Math.round(sh * scale))
              } as image.Size;
            }
          } catch (e2) {
            // 读不到尺寸就用原始尺寸解码（不影响显示）
          }
          const pm: image.PixelMap = await src.createPixelMap(opts);
          await src.release();
          if (pm) {
            next[ch.id] = pm;
          }
        } catch (e) {
          Log.i('[Index] 台标加载失败: ' + ch.id + ' ' + (e as Error).message);
        }
      })());
    }
    await Promise.all(tasks);
    this.iconMap = next;
    Log.i(`[Index] 台标加载完成 ${Object.keys(next).length} 个（解码上限 ${wantPx}px）`);
  }

  /* ★★ 2026-11-07：原「起步热机 warmupChannels()」已删除 ★★
   *   它做的是"启动后预先跑一遍 auth → 签名 → get_live_info"，把结果缓存 20s 供点击时复用。
   *   那条链（Web/PC + CMG）整体移除后，新链路是"**一个 cKey + 一次 liveinfo GET**"
   *   （实测 100~300ms，且不需要 auth/token），预热的收益远小于它带来的复杂度
   *   （缓存一次性消费 / 过期 / 换台作废 / 校验）。⇒ 点击时现取，行为更直观。
   *   DNS/TLS 预热仍保留（`warmDns()`，见 `bootSequence`）。 */

  /** 切 Tab */
  private switchTab(t: ChannelGroup): void {
    this.currentTab = t;
    this.aboutTab = false;
    this.list = channelsByGroup(t);
  }

  // ---------------- 取流 + 播放 ----------------
  /**
   * @param byUser true = 用户亲手点的（默认，频道宫格/播控切台）；false = 内部自动拉起
   *  （回退原台 / 看门狗重取 / 断网续播 / 回前台恢复）—— 只影响消息口径（见 `userPickedId`），
   *  不影响取流与播放本身。
   * @param replayAt ★ 2026-11-08：**回看/时移的起播时刻**（epoch 秒）；0 = 直播。
   *   非 0 时走 `YspLive.resolveFrom`（带 `playbacktime`），节目条显示"回看中"，并给出「返回直播」。
   * @param replayEnd 回看结束时刻（= 节目结束；**必须带**，否则服务端只给 ~5 片滚动窗口）
   * @param replayTitle 回看节目名（节目条显示用）
   */
  private async playChannel(ch: CctvChannel, byUser: boolean = true, replayAt: number = 0,
    replayEnd: number = 0, replayTitle: string = ''): Promise<void> {
    this.playRequestId++;
    const requestId: number = this.playRequestId;
    if (byUser) {
      this.userPickedId = ch.id;    // ★ 只有真·用户选台才刷新"用户点过的台"
    }
    /* ★ 回看/时移状态**成功后才提交**（见下面的成功分支）：
     *   取流失败会退回原台，那时不该把 UI 说成"回看中"。 */
    this.activeChannelId = ch.id;
    this.currentName = ch.name;
    /* ★ 宽高比修正**不当场生效**（否则旧画面会先弹回默认尺寸）：只登记，等新台 prepared 时再套用 */
    this.pendingArFix = ASPECT_OVERRIDES[ch.name] ?? 0;
    this.loading = true;
    this.playErr = false;
    /* ★ 新的一轮取流开始 ⇒ 取消"待续播"安排（失败时会重新安排，见 scheduleNetResume） */
    this.cancelNetResume();
    /* ★ 换台耗时打点：t0 = 点击；resolve 完成 / 首次出画 各打一次（用于定位慢在哪一段） */
    const t0: number = Date.now();
    /* ★ 新增：记录点击时刻，供 onPlayerState('playing') 计算全链路耗时 */
    this.tClickChannel = t0;   // ★ 记录点击时刻，供 onPlayerState('playing') 汇总
    this.bootMsg = `${ch.name} 正在获取播放地址…`;
    Log.i(`[Index] 切台 ${ch.name} pid=${ch.pid} t0`);
    /* ★ 本地代理是播放链路的**单点**：起不来就必然播不了（端口被占/网络栈重启后
     *   原来的 listen 可能已失效）⇒ 每次播放前确认一次，不在就补一次 start（内部带重试）。 */
    await this.server.ensureStarted();
    /* ★ 音频焦点：起播即激活（SHARE/MIX，不独占、不打断别人）；退后台会归还 */
    const afPlay: AudioFocus | null = this.audioFocus;
    if (afPlay !== null) {
      afPlay.activate();
    }
    this.pausedByInterrupt = false;   /* 新一轮起播 ⇒ 打断标记复位 */
    try {
      /* ★★ 网络类错误自动重试（最多 3 次，2026-09-15）★★
       *   真机实测：弱网/切网/长时间后台后首次取流常报
       *   `Failed to resolve the host name`、`Failed to connect to the server`（瞬时抖动），
       *   之前直接把英文错误显示在信息栏且**不重试** ⇒ 用户只能手动再点一次。
       *   现在：提示"网络信号差，正在重试（n/3）"，1.5s 退避后自动重拉；三次都失败才提示用户。 */
      const jstv: boolean = isJstvChannel(ch);
      /* ★★ 2026-09-22：IPTV 外部明文直链 —— 不查 pid/不走取流，直接播原始 URL */
      const iptv: boolean = isIptvChannel(ch);
      let lastErr: Error = new Error('取流失败');
      let started: boolean = false;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          /* ★ 上游地址（**仅用于日志 / CDN 主机预热**；交给播放器的永远是本地地址或原始直链） */
          let playUrl: string = '';
          if (jstv) {
            /* ★★ 江苏台（荔枝 TV）：**不走央视频取流**（无 auth / 无 session / 无 liveinfo）★★
             *   这里只给"本地代理地址"；**上游地址（含 txSecret 签名）由代理在请求那一刻现算**
             *   ⇒ 重试、回前台复用都不会用到过期签名（见 `LocalProxyServer.jstvPlaylistUrl`）。 */
            const sid: string = ch.streamId !== undefined ? ch.streamId : ch.id;
            playUrl = JSTV_ORIGIN;
            this.videoSrc = LocalProxyServer.jstvPlaylistUrl(sid);
            Log.i(`[Index] 江苏台直连（跳过取流）${ch.name} streamId=${sid}`);
          } else if (iptv) {
            /* ★★ IPTV 外部明文直链 —— **既不走央视频取流，也不走本地代理** ★★
             *   上游是别人家的明文 HLS 直链（无需签名、不解密）⇒ 直接把原始 URL 交给播放器。 */
            const raw: string = ch.streamId !== undefined ? ch.streamId : '';
            /* ★★ 起播前**带超时的预检**（外部源慢/失效是常态）★★
             *   放这里的理由：此时 `activeChannelId` 已切成新台，但**播放器还没被换过** ⇒
             *   判死时 `revertToPlayingChannel` 只动 UI 就能干净退回原台（全程不黑屏、不断音）。 */
            if (!await probeIptvSource(raw)) {
              Log.w(`[Index] IPTV 源无响应 ⇒ 不换播放器，退回原台: ${ch.name}`);
              /* 提示语与 CCTV-10 版权停播、直连台播放器报错合并 ——
                 有原台 ⇒ "xxx 无信号，已切回 yyy"；无 ⇒ "xxx 暂无信号，请点击其他频道"。 */
              if (this.noticeNoSignal(ch.name, ch.id) !== '') {
                this.revertToPlayingChannel(ch.name);
              }
              return;
            }
            if (requestId !== this.playRequestId) {
              return;   // 预检期间用户又换台 ⇒ 本次作废（别把 UI 拽回旧台）
            }
            playUrl = raw;
            this.videoSrc = raw;
            Log.i(`[Index] IPTV 直连（跳过取流/代理）${ch.name} url=${raw.substring(0, 60)}…`);
          } else {
            /* ★★★ 央视频**唯一**取流链路：自研 cKey → liveinfo（安卓平台）→ **明文** playurl ★★★
             *   2026-11-07 起不再有 Web/PC 链路、不再有 CMG 解密 —— 拿到的分片就是明文。 */
            this.bootMsg = `${ch.name} ${replayAt > 0 ? '回看取流中…' : '取流中…'}`;
            /* ★ 回看/时移：带 `playbacktime` + `endtime`（后者才给整段 VOD 清单）；
             *   直播：`resolveLive`（真直播优先，不可播再退时移 10s）。 */
            let yp: YspPlayInfo | null;
            if (replayAt > 0) {
              /* ★ endTime 只在"整档节目回看"时给（服务端才返回 VOD 清单）；
               *   时移（replayEnd = 0）**不给 endtime** ⇒ 滚动窗口，能一直往下播（不会几分钟就完播） */
              const endSec: number = replayEnd > replayAt + 5 ? replayEnd : 0;
              yp = await resolveFrom(ch.cnlId, ch.pid, replayAt, endSec);
            } else {
              yp = await resolveLive(ch.cnlId, ch.pid);
            }
            if (requestId !== this.playRequestId) {
              return;   // 取流期间用户又换台 ⇒ 本次作废（结果直接丢弃）
            }
            if (yp === null) {
              throw new Error(lastResolveError().length > 0 ? lastResolveError() : '取流失败');
            }
            playUrl = yp.url;
            this.videoSrc = LocalProxyServer.yspPlaylistUrl(yp.url, yp.guid);
            warmHostOf(yp.url);
            /* 预热：清单（自检时已拉到）+ 头部 2 片。不 await —— 与播放器 prepare 并行。 */
            this.server.prewarmYsp(yp.url, yp.guid, yp.playlist);
            this.fetchEpg(ch.pid);
            Log.i(`[Index] 央视频${replayAt > 0 ? '回看' : '明文'}链路 ${ch.name} cnlid=${yp.cnlid} ` +
              `defn=${yp.defn} pb=${yp.playback} start=${yp.playbackStart} guid=${yp.guid.substring(0, 8)}…`);
            if (replayAt > 0) {
              /* 节目条立刻切到回看的这一档（EPG 回来后会由 `applyReplayStrip` 校正） */
              this.episodeNow = replayTitle.length > 0 ? replayTitle : '回看中';
              this.episodeNext = '-';
            }
          }
          if (requestId !== this.playRequestId) {
            return;   // 取流期间用户又换台 ⇒ 本次作废（结果直接丢弃）
          }
          /* ★ 成功分支：`this.videoSrc` 已在上面各分支里按链路设好（本地代理地址 / 原始直链）。 */
          /* ★ 回看/时移状态在这一刻提交（失败路径不会走到这里） */
          this.replayStart = replayAt;
          this.replayEnd = replayAt > 0 ? replayEnd : 0;
          /* ★ 2026-11-09：记住这个台（下次启动自动播放它） */
          this.saveLastChannel(ch.id);
          /* ★ 只有"节目单整档回看"才带 endtime ⇒ 播完也有明确的"下一档"语义 */
          this.replayIsProgram = replayAt > 0 && replayEnd > replayAt + 5;
          /* ★ 时移的"延迟秒数"（直播沿相对量）：滚动窗口意外结束时用它续播，保持同样的延迟 */
          this.replayDelaySec = (replayAt > 0 && !this.replayIsProgram)
            ? Math.max(0, Math.floor(Date.now() / 1000) - replayAt) : 0;
          /* ★ 非"整档回看"（= 直播 / 时移）⇒ 清掉"回看那一档的身份"，否则列表里会残留「回看中」 */
          if (!this.replayIsProgram) {
            this.replayKeyYmd = '';
            this.replayKeyStart = 0;
          }
          Log.i(`[Index] play -> ${this.videoSrc}（上游 ${playUrl.substring(0, 80)}…）`);
          this.bootMsg = `${ch.name} 正在缓冲…`;
          if (jstv) {
            /* 江苏台：预热 playlist + **首 2 片**（只下载，无解密）+ CDN 主机预热；
             * 节目单暂无（荔枝 TV 的 EPG 接口未接入）⇒ 清掉上一台的 EPG，显示"暂无节目单"。 */
            const sid: string = ch.streamId !== undefined ? ch.streamId : ch.id;
            this.server.prewarmJstv(sid);
            warmHostOf(JSTV_ORIGIN);
            this.stopEpgTicker();
            this.epgItems = [];
            this.episodeNow = '暂无节目单';
            this.episodeNext = '-';
          } else if (iptv) {
            /* ★★ IPTV 直链：不经本地代理 ⇒ 没有 playlist/分片预热；也没有 EPG ⇒ 只清节目单。 */
            this.stopEpgTicker();
            this.epgItems = [];
            this.episodeNow = '暂无节目单';
            this.episodeNext = '-';
          }
          /* 央视频链路的预热 + EPG 已在上面的分支里做掉（顺序：先预热再 setupPlayer）。 */
          this.setupPlayer(this.videoSrc);   // ★ 交给原生 AVPlayer（surface 渲染）
          this.armAutoRetry(ch);   // ★ 首播看门狗：8 秒无分片则自动重取一次
          /* ★ 播控中心/锁屏卡片：换台即更新标题与封面（台标 PixelMap） */
          const ts: TvSession | null = this.tvSession;
          if (ts !== null) {
            ts.setChannel(ch.name, ch.id, this.iconMap[ch.id]);
          }
          Log.i(`[Index] resolve 完成 用时=${Date.now() - t0}ms（${jstv ? '江苏台' : (iptv ? 'IPTV 直链' : '自研 cKey 明文链路')}）`);
          started = true;
          break;
        } catch (e) {
          const err = e as Error;
          lastErr = err;
          if (err.message.indexOf('版权') >= 0 || err.message.indexOf('加密频道') >= 0) {
            throw err;                 // 版权停播 / 加密台都不是网络问题 ⇒ 立刻走下面的友好提示（不重试）
          }
          if (attempt >= 3) {
            break;                     // 三次都失败 ⇒ 交给下面统一提示
          }
          /* ★ 文案按错误类型分档（2026-09-17 定稿）：网络类 ≠ 其它，别把非网络错误写成"网络信号差"。
           *   2026-11-07：**不再有"鉴权失效"这一档**（新链路没有 auth/token/info 三件套）。 */
          const netErr: boolean = isNetErr(err.message);
          const waitMs: number = 1500;
          Log.w(`[Index] 取流失败(第 ${attempt}/3 次) ⇒ ${waitMs}ms 后自动重试: ${err.message}`);
          this.bootMsg = netErr
            ? `${ch.name} 网络信号差，正在重试（${attempt}/3）…`
            : `${ch.name} 取流异常，正在重试（${attempt}/3）…`;
          await new Promise<void>((ok: () => void) => {
            setTimeout(() => { ok(); }, waitMs);
          });
          if (requestId !== this.playRequestId) {
            return;                    // 重试期间用户又换台 ⇒ 本次作废
          }
        }
      }
      if (!started) {
        throw lastErr;
      }
    } catch (e) {
      const err = e as Error;
      this.playErr = true;
      /* ★ 官方"无流"特例（真机实测）：get_live_info 回 code=12 + errinfo
       *   "应版权方要求，暂停提供直播信号，请点击观看其他精彩节目"（CCTV-10 等会命中）。
       *   这时不该显示"取流失败"，而是给出与原版一致的友好提示。 */
      if (err.message.indexOf('版权') >= 0 || err.message.indexOf('加密频道') >= 0) {
        /* ★★ 2026-10-01（用户要求统一）★★ "版权所有方停播"走**同一句提示**：
         *   有原台可退就说"xxx 无信号，已切回 yyy"，没有可退的原台才说"请点击其他频道"。
         * ★ 2026-11-08 模拟器实测补充：**8 个 ChinaDRM 加密台**（鸿蒙暂无 sm4c）也归这一类 ——
         *   它们取流成功但分片是 SM4 密文，原实现会一直停在"正在缓冲…"；
         *   现在 `YspLive` 在清单自检阶段就判死，这里走同一条"无信号 + 回退"路径，
         *   播放器**根本没被换过** ⇒ 原台继续播，用户不会看到黑屏/假缓冲。 */
        Log.i(`[Index] ${ch.name} 无信号（${err.message.indexOf('版权') >= 0 ? '版权停播' : '加密台'}）⇒ 走统一回退提示`);
        if (this.noticeNoSignal(ch.name, ch.id) !== '') {
          this.revertToPlayingChannel(ch.name);
        }
      } else if (isNetErr(err.message)) {
        /* ★★ 网络类失败（重试 3 次仍失败）★★
         *   - 不把英文错误甩给用户：中文提示 + 中央浮层（只提示一次，后续静默重试）；
         *   - **保留 activeChannelId**（用户选中的频道）⇒ 才可能"网络恢复后自动续播"；
         *   - 记 netDownAt ⇒ 断网期间抑制播放器重建/重拉风暴；
         *   - scheduleNetResume() 每 5s 用当前频道重试（用户实测：断网→迅速恢复网络
         *     后 App 卡在报错不动，就是缺这一步）。 */
        Log.e(`[Index] 取流失败（已重试 3 次）: ${err.message}`);
        this.netDownAt = Date.now();
        this.playErr = false;         // 正在自动重试，不是"播放出错"（避免信息栏变红误导）
        if (this.netResumeTries === 0) {
          this.showVideoNotice('网络信号差，暂时无法播放，正在自动重试…');
        }
        this.scheduleNetResume();
      } else {
        /* ★ 2026-09-21：失败原因仍要看得见 ⇒ 丢到视频区浮层（焦点若被退回，信息栏会被改写成"原台 播放中"） */
        const msg: string = `${ch.name} 取流失败：${err.message}`;
        this.showVideoNotice(msg);
        if (!this.revertToPlayingChannel(ch.name)) {
          this.bootMsg = msg;
          this.activeChannelId = '';
        }
      }
      Log.e(`[Index] playChannel 失败: ${err.message}`);
    } finally {
      if (requestId === this.playRequestId) {
        this.loading = false;
      }
    }
  }

  /**
   * ★ 2026-09-21：取流阶段失败（无信号 / 取流失败）⇒ **只把「状态栏 + 选中台标」退回仍在播放的原台**。
   *
   * 为什么够用：失败发生在取流阶段 ⇒ `setupPlayer()` 还没执行 ⇒ **播放器与画面完全没被换过（原台不中断）**，
   *   所以只需改 UI：选中态回原台、状态栏「原台 播放中」、绿点；视频区中央浮层照旧提示失败原因。
   *   播控卡片（AVSession）在本路径上**本来就没被改过**（`setChannel` 只在取流成功后才调）⇒ 不用动。
   *
   * @param failedName 失败的那个台名（仅用于日志）
   * @returns true = 已回退；false = 没有可回退的原台（如开机后第一次点击就命中）⇒ 调用方写"暂无直播信号"
   */
  private revertToPlayingChannel(failedName: string): boolean {
    const back: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.lastPlayingId);
    /* ★ 2026-09-23：`back.id === activeChannelId` ⇒ 失败的就是"原台"自己（例如回退到原台后又失败）
     *   ⇒ 不能声称它在"播放中"（那是谎报），直接返回 false 让调用方给最终提示。 */
    if (back === undefined || back.id === this.activeChannelId) {
      return false;
    }
    this.activeChannelId = back.id;    // 频道网格：选中的仍是原台
    this.currentName = back.name;
    this.playErr = false;              // 状态灯：绿点
    this.bootMsg = `${back.name} 播放中`;
    Log.i(`[Index] ★ ${failedName} 无信号 ⇒ 状态栏/选中回退到仍在播放的 ${back.name}`);
    return true;
  }

  /**
   * ★★ 2026-09-23：**播放器级**无信号 ⇒ 真正切回"原台"（不是只改 UI）★★
   *
   * 与 `revertToPlayingChannel` 的分工（**关键区别，别混用**）：
   *   · `revertToPlayingChannel` —— 失败在**取流阶段**，播放器根本没被换过 ⇒ 只改 UI 即可（画面仍是原台）；
   *   · 本函数 —— 失败在**播放器阶段**（IPTV 直链压根没有取流阶段；或央视频重建已达上限）⇒
   *     播放器**已经**被换成坏台（画面黑/卡死）⇒ 必须**真的把原台重播一遍**。
   *
   * 防"套娃回退"：回退目标就是 `lastPlayingId` 本身，切过去后 `activeChannelId === lastPlayingId`
   *   ⇒ 它若再失败，本函数入口判断即返回 false，由调用方给最终提示 ⇒ 不会无限递归。
   */
  /** ★ 回退目标台名（"真正出过画"的台 ⇒ `lastPlayingId`）；没有可退目标返回 ''。
   *  ⚠️ **必须在该回退动作之前**调用 —— 一旦回退完，`activeChannelId` 就等于它了，再判不出"有无可退目标"。 */
  private revertTargetName(): string {
    const back: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.lastPlayingId);
    return (back !== undefined && back.id !== this.activeChannelId) ? back.name : '';
  }

  /** ★★ 2026-10-01（用户要求统一）★★ **所有"没源"的提示都说同一句**（与安卓
   *  `MainViewModel.revertWithNotice()` 同口径）：
   *   · 有原台可退 ⇒ "xxx 无信号，已切回 yyy"；
   *   · 没有可退的原台 ⇒ "xxx 暂无信号，请点击其他频道"。
   *   IPTV 预检失败、**CCTV-10 的版权停播**、直连台播放器报错 —— 全部走这里
   *   （原来三套文案：`源无响应` / `应版权方要求，暂停提供直播信号…` / `暂无信号`）。
   *  @returns 回退目标台名（'' = 无原台可退，调用方按需保留报错态） */
  private noticeNoSignal(failedName: string, failedId: string): string {
    const backName: string = this.revertTargetName();
    if (backName !== '') {
      this.showVideoNotice(`${failedName} 无信号，已切回 ${backName}`);
      this.noticeFallbackAt = Date.now();   // ★ 记时刻：5 秒内不再用中性提示顶掉它
    } else if (failedId !== '' && failedId !== this.userPickedId) {
      /* ★★ 2026-10-02（用户实测："回退原台时条幅认错台"）★★
       *   走到这里说明**没有别的原台可退**，而失败的台**不是用户亲手点的**（是自动回退/看门狗重取
       *   拉起来的原台）⇒ 不能对它说"暂无信号，请点击其他频道"（那是在告诉用户"你选的那个台没信号"，
       *   可用户根本没选它）。用户实测的原话就是：
       *     "我正在看 CCTV-1，想切换无信号的广州电视，条幅显示 CCTV-1 暂无信号，请点击其他频道。"
       *   ⇒ 改成**中性口径**：不点台名，只说信号中断、正在自动重试（同时不再标"播放出错"红点，
       *     因为这是自动恢复流程，不是用户的锅）。 */
      this.playErr = false;
      this.bootMsg = `${failedName} 信号中断，正在自动重试…`;
      /* ★★ 2026-10-02（用户实测）★★ 刚回退过（5s 内）时**不弹浮层**：
       *   场景 —— 从地方台切广州台，回退到原台（也是 IPTV 直连，起播慢），原台在自己的看门狗窗口内
       *   还没出画 ⇒ 这里会再弹一句"信号中断，正在自动重试…"，把刚显示的
       *   "广州电视 无信号，已切回 哈尔滨电影"顶掉 ⇒ 用户最后只看到这句，以为条幅错了
       *   （原话："回退时显示：信号中断，正在自动重试…"）。
       *   ⇒ 5 秒内只更新状态栏文案、**不动视频区浮层**，回退提示得以留满自己的 2 秒。 */
      if (Date.now() - this.noticeFallbackAt > 5000) {
        this.showVideoNotice('信号中断，正在自动重试…');
      }
    } else {
      this.playErr = true;
      this.bootMsg = `${failedName} 暂无信号，请点击其他频道`;
      this.showVideoNotice(`${failedName} 暂无信号，请点击其他频道`);
    }
    return backName;
  }

  private fallbackToPlayingChannel(failedName: string, reason: string): boolean {
    const back: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.lastPlayingId);
    if (back === undefined || back.id === this.activeChannelId) {
      return false;
    }
    Log.w(`[Index] ★ ${failedName} 无信号（${reason}）⇒ 自动切回原台 ${back.name}`);
    this.playerRebuilds = 0;   /* 换到另一个台 ⇒ 自愈额度重新计（否则一进 recoverPlayer 就撞上限） */
    this.retried = false;
    /* ★★ 2026-10-02（用户实测："回退原台时条幅认错台"）★★ 顺序必须"**先切台、再提示**"：
     *   `playChannel` 一进来就会**清空视频区浮层**（换台本就该清）⇒ 原来提示写在它**之前**，
     *   这条正确提示（"广州电视 无信号，已切回 CCTV-1"）会被立刻抹掉 ✗，用户最后看到的反而是
     *   后面才冒出来的另一条（往往还指向错误的台）。
     *   安卓侧早踩过同一个坑并改成同一顺序（见 `MainViewModel.fallbackToLastGood` 的注释）⇒ 三端对齐。 */
    this.playChannel(back, false);   /* ★ 自动拉起（非用户点选）⇒ byUser=false，见 userPickedId */
    this.showVideoNotice(`${failedName} 无信号，已切回 ${back.name}`);
    this.noticeFallbackAt = Date.now();   // ★ 记时刻：5 秒内别再用中性提示顶掉这条回退提示
    return true;
  }

  /** ★ 首启免责声明：同意 ⇒ 落盘"已读"（此后不再弹；文案改版号会再弹一次）。
   *  ★ 2026-09-29：若本次是「再次查看」（`disclaimerReadOnly`）⇒ **只关窗**：不写标记、不改任何状态。 */
  private async agreeDisclaimer(): Promise<void> {
    const readOnly: boolean = this.disclaimerReadOnly;
    this.showDisclaimer = false;
    if (readOnly) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, 'palmtv');
      await store.put('disc', this.discVer);
      await store.flush();
      Log.i('[Index] 已记录免责声明同意状态');
    } catch (e) {
      Log.w(`[Index] 写免责声明标记失败: ${(e as Error).message}`);
    }
  }

  /** ★ 首启免责声明：不同意 ⇒ 直接退出（不进入播放界面） */
  private refuseDisclaimer(): void {
    Log.i('[Index] 用户不同意内容来源声明 ⇒ 退出');
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    if (ctx !== undefined) {
      ctx.terminateSelf().catch((e: BusinessError) => {
        Log.w(`[Index] terminateSelf 失败: ${e.message}`);
      });
    }
  }

  /** ★ 视频区中央提示（浮层，不打断当前播放）。
   *  ★ 2026-10-01（与安卓同步，用户要求）：**2 秒自消**（5 秒 → 1 秒 → 2 秒）。 */
  private showVideoNotice(msg: string): void {
    this.videoNotice = msg;
    if (this.noticeTimer !== -1) {
      clearTimeout(this.noticeTimer);
    }
    this.noticeTimer = setTimeout(() => {
      this.videoNotice = '';
      this.noticeTimer = -1;
    }, 2000);
  }

  /**
   * ★ 首播看门狗（真机实测：**首次**点频道常常播不出来，再点一次就好）。
   *
   * 原因在日志里很明确：首次取流时本地代理拉远端 playlist 连续报
   * `Failed to connect to the server`（连不上那个 CDN 节点），而重新取流会拿到**另一个** CDN 节点。
   * 所以这里在开播后 8 秒检查"有没有分片被解出来"：
   *   - 有 ⇒ 正常，解除标记；
   *   - 没有且还没自动重试过 ⇒ **自动重取一次**（用户不需要点第二次）。
   * 最多自动重试 1 次，且成功一次后标记会复位（下次失败又能救一次）。
   */
  private armAutoRetry(ch: CctvChannel): void {
    /* ★ 网络刚失败时不挂看门狗：必然拉不到分片，只会与"网络恢复续播"轮询撞车 */
    if (this.isNetDownRecently()) {
      return;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    /* ★★ 判据分两条路（原来只有"分片数"一条，对**直连台**永远不成立）★★
     *   · 央视频链路：用 `total`（= 真正返回给播放器的分片数，含缓存命中）判断"有没有出片"。
     *     （2026-11-07 起代理只转发不解密，原 `decrypted` 指标已删除。）
     *   · 江苏台（经代理，`total` 也会涨）/ IPTV 直链（**不经代理** ⇒ `total` 恒为 0）：
     *     统一改看"播放器是否真的进过 `playing`"，比只看分片数稳。 */
    const direct: boolean = isLocalDirectChannel(ch);
    const chId: string = ch.id;
    const before: number = direct ? 0 : this.server.getStat().total;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      /* ★ 触发时已在后台 ⇒ 不重取（后台不下载不解密；回前台 onPageShow 会自己恢复） */
      if (this.hideAt > 0) {
        this.needRecoverOnShow = true;
        Log.i('[Index] 看门狗触发时已在后台 ⇒ 跳过重取（回前台再处理）');
        return;
      }
      /* ★ 2026-09-23：期间用户又换台 ⇒ 本次作废（否则会把已经不看的那台判成"无信号"，
       *   甚至用 `playChannel(ch)` 把用户**拽回**刚刚那个台）。 */
      if (this.activeChannelId !== chId) {
        Log.i('[Index] 看门狗触发时已换台 ⇒ 本次作废');
        return;
      }
      if (direct) {
        /* ★★ 直连台（江苏台 / IPTV）无信号 ⇒ **回退原台**（用户要求：所有无信号的台都要回退）★★
         *   判据 = 到点还**从没出过画**。⚠️ 用 `lastPlayingId === chId`（"这个台进过 playing"）
         *   而不是只看 `this.playing`：后者在"已出画但用户手动暂停"时也是 false，会误判成无信号
         *   （`lastPlayingId` 只在**进 error** 时才清，暂停不清）。上游"有画面但卡住"的极端情况
         *   交给播放器自身的 error/超时路径（最终同样走到 `recoverPlayer` 的回退分支）。 */
        if (this.playing || this.lastPlayingId === chId) {
          this.retried = false;
          return;
        }
        const sec: number = Math.round(LOCAL_DIRECT_NOPIC_MS / 1000);
        Log.w(`[Index] ${ch.name} ${sec} 秒未出画 ⇒ 判无信号`);
        if (this.fallbackToPlayingChannel(ch.name, `${sec}s 未出画`)) {
          return;
        }
        /* ★ 2026-10-02（用户实测"条幅认错台"）：统一走 `noticeNoSignal` —— 由它自己判
         *   "有没有别的原台可退 / 失败的台是不是用户亲手点的"，别再各写一套文案。 */
        this.noticeNoSignal(ch.name, ch.id);
        this.destroyPlayer();   /* 别把一个卡死的画面留在屏幕上 */
        return;
      }
      const after: number = this.server.getStat().total;
      if (after > before) {
        this.retried = false;   // 这轮正常，允许下一轮再救
        return;
      }
      if (this.retried) {
        /* ★ 2026-09-23：自动重取一次仍无分片 ⇒ 判无信号，**回退原台**（原来是干等，画面停在"正在缓冲…"） */
        Log.w('[Index] 自动重试后仍无分片 ⇒ 判无信号');
        if (this.fallbackToPlayingChannel(ch.name, '重取后仍无分片')) {
          return;
        }
        /* ★ 2026-10-02：同 direct 分支 —— 文案统一交给 `noticeNoSignal`（口径见那里） */
        this.noticeNoSignal(ch.name, ch.id);
        this.destroyPlayer();
        return;
      }
      this.retried = true;
      Log.w('[Index] 8 秒内无分片解出 ⇒ 自动重取一次（首播连不上 CDN 节点的兜底）');
      this.playChannel(ch, false);   /* ★ 自动重取（非用户点选）⇒ byUser=false，见 userPickedId */
    }, direct ? LOCAL_DIRECT_NOPIC_MS : 8000);
  }

  // ---------------- EPG ----------------
  /**
   * 拉当天节目单（capi 直连 + protobuf 解码），失败只提示不影响播放。
   * ★ 2026-09-16：**失败要重试**（最多 3 次，2s/4s 退避，换台即作废）——
   *   旧实现失败就直接显示"EPG 获取失败"且不再重试（ticker 也只在成功时才启动）
   *   ⇒ 网络抖一下，节目条会一直错到用户换台为止。
   */
  private async fetchEpg(pid: string, attempt: number = 1): Promise<void> {
    const chId: string = this.activeChannelId;
    /* ★ 同一频道的 EPG 拉取**去重**（2026-09-16）：真机日志里出现过
     *   `refreshEpgNow` 的 60s 重刷与 `playChannel` 的首次拉取**同时**发起（两条成功日志差 400ms），
     *   白白多一次请求。这里让"进行中的那次"独占，后来者直接复用（等它完成即可）。 */
    if (this.epgInflightPid === pid) {
      Log.i(`[Index] EPG ${pid} 拉取进行中 ⇒ 跳过重复请求`);
      return;
    }
    this.epgInflightPid = pid;
    try {
      const ymd: string = ymdOf(0);
      /* ★ 2026-11-08：一次拉 10 天（前 6 + 今天 + 后 3），弹窗按天分组、过去的天可回看 */
      const items: EpgItem[] = await fetchEpgRange(pid);
      this.lastEpgDay = ymd;          /* 记录已拉取日期（跨天自动重拉用） */
      this.lastEpgFetchAt = Date.now(); /* ★ 记录"上次成功拿到"的时间（≥60s 才允许再走网络） */
      this.epgItems = items;
      /* ★ 回看/时移中：节目条跟着**回看的那一档**走，不要被"正在播出"覆盖 */
      if (this.replayStart > 0) {
        this.applyReplayStrip();
      } else {
        /* ★ 2026-11-10：与弹窗同一判据（`epgRowState === 2`）；`it.now` 是拉到数据那一刻的
         *   快照，跨零点/跨点后会过期，不能拿来当"正在播"。 */
        const nowIdx: number = items.findIndex((it: EpgItem) => this.epgRowState(it) === 2);
        if (nowIdx >= 0) {
          this.episodeNow = `${items[nowIdx].start} ${items[nowIdx].title}`;
          this.episodeNext = (nowIdx + 1 < items.length)
            ? `${items[nowIdx + 1].start} ${items[nowIdx + 1].title}` : '暂无';
        } else {
          this.episodeNow = '暂无节目单';
          this.episodeNext = '-';
        }
      }
      Log.i(`[Index] EPG ${pid} 共 ${items.length} 条${attempt > 1 ? `（第 ${attempt} 次尝试成功）` : ''}`);
      /* ★ 启动"跨点自动刷新"：否则节目播完了，"正在播出/接下来"还停在旧节目（用户报的 BUG） */
      this.startEpgTicker();
    } catch (e) {
      const err = e as Error;
      Log.w(`[Index] EPG 失败(第 ${attempt}/3 次): ${err.message}`);
      if (attempt < 3) {
        this.episodeNow = 'EPG 获取失败，正在重试…';
        this.episodeNext = '-';
        if (this.epgRetryTimer !== -1) {
          clearTimeout(this.epgRetryTimer);
        }
        this.epgRetryTimer = setTimeout(() => {
          this.epgRetryTimer = -1;
          /* 期间换台/退出 ⇒ 这次重试作废 */
          if (this.activeChannelId === '' || this.activeChannelId !== chId) {
            return;
          }
          this.fetchEpg(pid, attempt + 1);
        }, 2000 * attempt);
      } else {
        this.episodeNow = 'EPG 获取失败';
        this.episodeNext = '-';
      }
    } finally {
      /* 无论成功/失败都要放开去重锁，否则该频道的 EPG 再也不会刷新 */
      if (this.epgInflightPid === pid) {
        this.epgInflightPid = '';
      }
    }
  }

  /** ★ 启动节目单跨点刷新（20 秒粒度足够：EPG 是分钟级，跨点最多晚 20 秒刷新） */
  private startEpgTicker(): void {
    if (this.epgTimer !== -1) {
      return;
    }
    /* ★ 10s 一次 tick：只做本地时间推进（跨点立刻反映）；走网络由 `EPG_REFRESH_MS`(30s) 限流 */
    this.epgTimer = setInterval(() => { this.refreshEpgNow(); }, 10000);
  }

  /**
   * ★ 2026-11-08：**回看 / 时移**（与安卓 `playReplayFrom` 同一条判据）
   *   · 已播完 + `replayable` ⇒ 从该节目开始播（带 `endtime` ⇒ 整段 VOD 清单，可连续播）；
   *   · 正在播出 ⇒ **时移**：从 5 分钟前起播（安卓同款；结束时刻用"现在"）；
   *   · 已播完但官方标记不可回看（版权）⇒ 只提示，不发起取流（点了必然失败）。
   * ⚠️ 只有央视频道支持（江苏台 / IPTV 直链没有时移能力）。
   */
  private startReplay(it: EpgItem): void {
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    if (isJstvChannel(ch) || isIptvChannel(ch)) {
      this.showVideoNotice('该频道不支持回看');
      return;
    }
    const nowSec: number = Math.floor(Date.now() / 1000);
    const nowMs: number = Date.now();
    const ended: boolean = it.endMs > 0 && it.endMs < nowMs;
    const onAir: boolean = it.startMs > 0 && nowMs >= it.startMs && nowMs < it.endMs;
    if (ended && it.replayable) {
      this.showEpg = false;
      /* ★ 记下"这一档的身份"（ymd + start）：列表里只有它显示「回看中」 */
      this.replayKeyYmd = it.ymd;
      this.replayKeyStart = it.startMs;
      Log.i(`[Index] 回看 ${ch.name} ${it.title} ${it.start}-${it.end}（key=${it.ymd}#${it.startMs}）`);
      this.playChannel(ch, true, Math.floor(it.startMs / 1000), Math.floor(it.endMs / 1000), it.title);
    } else if (ended) {
      this.showVideoNotice('该节目暂不可回看');
    } else if (onAir) {
      this.showEpg = false;
      Log.i(`[Index] 时移 ${ch.name} ${it.title} ⇒ 从 ${nowSec - 300} 起播`);
      /* ★ 时移**不带 endtime**（滚动窗口 ⇒ 持续延迟直播；带 endtime 会变成有限 VOD，播到 now 就完播） */
      this.replayKeyYmd = '';
      this.replayKeyStart = 0;
      this.playChannel(ch, true, nowSec - 300, 0, it.title);
    } else {
      this.showVideoNotice('该节目尚未开始');
    }
  }

  /** 节目单覆盖的日期（升序去重；`fetchEpgRange` 给的是前 6 ~ 后 3 天） */
  private epgDays(): string[] {
    const seen: Set<string> = new Set<string>();
    const out: string[] = [];
    for (const it of this.epgItems) {
      if (it.ymd.length > 0 && !seen.has(it.ymd)) {
        seen.add(it.ymd);
        out.push(it.ymd);
      }
    }
    out.sort();
    return out;
  }

  /**
   * ★ 2026-11-10（用户要求，三端统一）：**"正在看的那天"** ——
   *   · 回看/时移：正在播放的那一档所属的日期（`ymd` 由 start 时间戳推出，与列表分组同源）；
   *   · 直播：今天。
   *   用途：那一天的日期 TAB **始终红粗**（即使已经切到别的日期 TAB），表示"你正在看这天的节目"。
   */
  private epgWatchDay(): string {
    if (this.replayStart <= 0) {
      return ymdOf(0);
    }
    return this.replayKeyYmd.length === 8 ? this.replayKeyYmd : ymdOfSec(this.replayStart);
  }

  /**
   * 日期 TAB 的文字颜色（优先级从高到低）：
   *   ① 正在看的那天 ⇒ 红（离开该 TAB 也保持红，表示"正在看这天的节目"）；
   *   ② 当前选中的、但**不是**正在看的那天 ⇒ 紫（`#a78bfa`，与红/绿都能区分，深色底上可读）；
   *   ③ 今天（且既不是正在看、也没被选中）⇒ 绿（跨天回看时"今日"不再抢红）；
   *   ④ 其余 ⇒ 灰。
   */
  private epgDayColor(d: string): string {
    if (d === this.epgWatchDay()) {
      return '#ff5c5c';
    }
    if (d === this.epgSelDay) {
      return '#a78bfa';
    }
    if (d === ymdOf(0)) {
      return '#3ddc84';
    }
    return '#999';
  }

  /** 日期 TAB 是否加粗（正在看的那天 或 当前选中） */
  private epgDayBold(d: string): boolean {
    return d === this.epgWatchDay() || d === this.epgSelDay;
  }

  /** 日期 TAB 的底色：选中时给一层同色微光（红=正在看/紫=只是选中），未选中透明 */
  private epgDayBg(d: string): string {
    if (d !== this.epgSelDay) {
      return '#00000000';
    }
    return d === this.epgWatchDay() ? '#33ff5c5c' : '#33a78bfa';
  }

  /** 把「当前节目所在那天」的日期 TAB 滚到弹窗**中间**（≈ 安卓 `dayRowState.scrollToItem(i-2)`） */
  private scrollEpgDayToSel(): void {
    const days: string[] = this.epgDays();
    const i: number = days.indexOf(this.epgSelDay);
    if (i < 0) {
      return;
    }
    setTimeout(() => {
      try {
        this.epgDayScroller.scrollToIndex(i, true, ScrollAlign.CENTER);
      } catch (e) {
        Log.w(`[Index] 日期行定位失败: ${(e as Error).message}`);
      }
    }, 200);
  }

  /** 选中那一天的节目（按开始时间戳升序；安卓 `Epg.groupByDay` 里也是 `sortedBy { it.start }`） */
  private epgOfDay(ymd: string): EpgItem[] {
    const out: EpgItem[] = [];
    for (const it of this.epgItems) {
      if (it.ymd === ymd) {
        out.push(it);
      }
    }
    out.sort((a: EpgItem, b: EpgItem) => a.startMs - b.startMs);
    return out;
  }

  /** 打开节目单：默认落在「正在回看的那天」，否则今天（与安卓 `EpgModal` 一致） */
  private openEpg(): void {
    const days: string[] = this.epgDays();
    let sel: string = '';
    if (this.replayStart > 0) {
      const t: number = this.replayStart * 1000;
      for (const it of this.epgItems) {
        if (it.startMs > 0 && t >= it.startMs && t < it.endMs) {
          sel = it.ymd;
          break;
        }
      }
    }
    if (sel.length === 0) {
      const today: string = ymdOf(0);
      sel = days.indexOf(today) >= 0 ? today : (days.length > 0 ? days[0] : today);
    }
    this.epgSelDay = sel;
    this.showEpg = true;
    this.scrollEpgDayToSel();   /* ★ 把"当前节目所在那天"的 TAB 滚到中间 */
    this.scrollEpgToNow();
    /* ★ 诊断（4K/8K 排查）：打印选中日的行数与各状态计数 —— 「回看中」必须 ≤ 1 */
    this.logEpgDayStats('打开', sel);
  }

  /** ★ 诊断：某一天的行数 + 各状态计数（`回看中` 必须 ≤ 1；未来日必须全 0） */
  private logEpgDayStats(tag: string, day: string): void {
    const list: EpgItem[] = this.epgOfDay(day);
    let c1: number = 0;
    let c2: number = 0;
    let c3: number = 0;
    let zero: number = 0;
    for (const it of list) {
      const st: number = this.epgRowState(it);
      if (st === 1) {
        c1++;
      } else if (st === 2) {
        c2++;
      } else if (st === 3) {
        c3++;
      }
      if (it.endMs <= it.startMs) {
        zero++;   /* 4K/8K 特有的"零长度"节目条（start == end），统计一下 */
      }
    }
    Log.i(`[EPG] ${tag} sel=${day} 行=${list.length} 零长=${zero} 回看中=${c1} 直播中=${c2} 回看=${c3}` +
      ` key=${this.replayKeyYmd}#${this.replayKeyStart} start=${this.replayStart}`);
  }

  /**
   * ★★★ 节目行状态 —— **唯一判据**（颜色 / 标签 / 是否可点全由它决定）★★★
   *
   *   1 = 回看中（红粗）· 2 = 直播中（回看时绿粗，否则红粗）
   *   3 = 可回看（蓝字）· 4 = 不可回看（灰字）· 0 = 普通（**未来节目一律 0**：不画标记、不可点）
   *
   * ★★ 2026-11-10：直播/已播完**只比时间戳**，与安卓 `EpgModal` 完全同一条判据
   *   （`now in it.start until it.end` / `it.end < now` / `it.end <= now && replayable`）★★
   *   为什么不比"日期"：① 抓包实测央视频 EPG 的"一天"是 06:00(4K)/07:00(8K) → 当天 23:59，
   *   凌晨那段服务端根本没数据 ⇒ 按日期判会出现"整段空白 + 全都算回看"的含糊地带；
   *   ② `ymd` 现在由 start 时间戳推出（见 `fetchEpgItems`），数据自洽，
   *   比 epoch 就等于比"绝对时刻"，不存在跨天歧义；③ 弹窗列表本来就**按天分组**，
   *   一条节目只会出现在它自己那一天的 TAB 里，所以"别的日期也显示正在播"
   *   只能由 UI 复用（ForEach 键撞车）造成 —— 见 `epgRows`。
   *
   * ★★ 2026-11-09 第二轮（CCTV-4K / 8K 仍异常）：回看中改成 **按"节目身份"精确匹配** ★★
   *   这两台一天几十~两百多档、且大量 30 秒短节目（`07:01-07:01`，显示上像零长度），
   *   只比时间区间容易误命中，改为：
   *     · 起播时记下**那一档的身份**（`ymd` + `startMs`）；
   *     · 列表里"回看中"**只认身份完全相等的那一条**；
   *     · 万一身份缺失（例如重启后按 playbacktime 复原），才退回"时间区间(含 -5s 容差)"。
   */
  private epgRowState(it: EpgItem): number {
    const nowMs: number = Date.now();
    /* ① 正在回看（身份匹配；身份缺失才退回时间区间） */
    if (this.replayStart > 0 && it.startMs > 0 && it.endMs > it.startMs) {
      const keyed: boolean = this.replayKeyYmd.length === 8 && this.replayKeyStart > 0;
      const t0: number = this.replayStart * 1000;
      if (keyed) {
        if (it.ymd === this.replayKeyYmd && it.startMs === this.replayKeyStart && t0 < it.endMs) {
          return 1;
        }
      } else if (t0 >= it.startMs - 5000 && t0 < it.endMs) {
        return 1;
      }
    }
    /* 时间戳缺失/非法 ⇒ 什么标记都不画（安卓同款：epoch 无效就不参与判定） */
    if (it.startMs <= 0 || it.endMs <= it.startMs) {
      return 0;
    }
    /* ② 正在播 ⇒ 直播中 */
    if (nowMs >= it.startMs && nowMs < it.endMs) {
      return 2;
    }
    /* ③ 已播完 ⇒ 回看 / 不可回看；④ 未开始（未来）⇒ 0 */
    if (it.endMs <= nowMs) {
      return it.replayable ? 3 : 4;
    }
    return 0;
  }

  /** 该节目是否正是"正在回看的那一档"（身份命中） */
  private epgInReplay(it: EpgItem): boolean {
    return this.epgRowState(it) === 1;
  }

  /**
   * 弹窗列表的整行数据（见 `EpgRow`：颜色/字重/右侧标记/键值都在这里算好）。
   * ⚠️ key 里**必须**带 `ymd`（不同日期的节目名与开始时刻常常一模一样，只按行号+时刻做 key
   *    会让 ArkUI 复用上一天的行组件 ⇒ 串日显示"直播中/回看"）。
   */
  private epgRows(): EpgRow[] {
    const list: EpgItem[] = this.epgOfDay(this.epgSelDay);
    /* ★ 2026-11-10（用户要求）：判据是**"当前是否处于回看/时移"（全局）**，不是"选中的这一天里
     *   有没有回看中"。跨天回看（回看昨天那档、人却看着今天的 TAB）时，直播那条也必须降级为绿字；
     *   原来按天判断 ⇒ 跨天时今天的主播节目又变回红粗（用户实测）。 */
    const replaying: boolean = this.hasReplay();
    const rows: EpgRow[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: EpgItem = list[i];
      const st: number = this.epgRowState(it);
      let color: string = '#c8c8c8';
      let bold: boolean = false;
      let label: string = '';
      let labelColor: string = '';
      let labelSize: number = 11;
      let labelBold: boolean = false;
      if (st === 1) {
        color = '#ff4444';
        bold = true;
        label = '回看中';
        labelColor = '#ff4444';
        labelBold = true;
      } else if (st === 2) {
        /* ★ 与安卓 `liveSecondary` 同义：**处于回看/时移**时直播那条整行（时间+标题+标记）
         *   统一变**绿粗**（用户要求：不能只有「直播」两个字变绿），文案也由「直播中」改为「直播」
         *   （你已经不在看直播了）。未回看时仍是红粗「直播中」。 */
        color = replaying ? '#3ddc84' : '#ff4444';
        bold = true;
        label = replaying ? '直播' : '直播中';
        labelColor = replaying ? '#3ddc84' : '#ff4444';
        labelBold = true;
      } else if (st === 3) {
        label = '回看';
        labelColor = '#2f6bff';
      } else if (st === 4) {
        label = '不可回看';
        labelColor = '#666666';
        labelSize = 10;
      }
      rows.push({
        key: `${it.ymd}#${it.startMs}#${i}#${st}#${color}`,
        startText: `${it.start}-${it.end}`,
        title: it.title,
        color: color,
        bold: bold,
        label: label,
        labelColor: labelColor,
        labelSize: labelSize,
        labelBold: labelBold,
        state: st,
        item: it
      } as EpgRow);
    }
    return rows;
  }

  /** 是否正处于"回看/时移"（用于把**直播那条**降为绿粗字、与回看区分） */
  private hasReplay(): boolean {
    return this.replayStart > 0;
  }

  /** 回看/时移中：把节目条切到"正在回看的那一档"（不跟直播节目走） */
  private applyReplayStrip(): void {
    const t: number = this.replayStart * 1000;
    const items: EpgItem[] = this.epgItems;
    const day: string = ymdOfSec(this.replayStart);   /* ★ 必须同一天，避免跨天误命中 */
    for (let k = 0; k < items.length; k++) {
      const it: EpgItem = items[k];
      if (it.ymd === day && it.startMs > 0 && t >= it.startMs && t < it.endMs) {
        this.episodeNow = `${it.start} ${it.title}`;
        this.episodeNext = (k + 1 < items.length && items[k + 1].ymd === day)
          ? `${items[k + 1].start} ${items[k + 1].title}` : '暂无';
        return;
      }
    }
    if (this.episodeNow.length === 0 || this.episodeNow === '暂无节目单') {
      this.episodeNow = '回看中';
      this.episodeNext = '-';
    }
  }

  /**
   * ★ 2026-11-09（对齐安卓 `MainViewModel.shiftBy`）：**左右滑动时移** —— 只累加待结算目标 + OSD，
   *   **不立刻取流**；抬手后由 `applyShift()` 统一取一次（连滑多次只发一个请求）。
   *   · 右滑 = 前进（`deltaSec` 正）、左滑 = 后退（负）；
   *   · 基准 = 待结算目标 → 当前时移位置 `replayStart` → 直播沿 `now-2`；
   *   · 上界 = 直播沿（到点 ⇒ 抬手后回直播）；下界 = now−7 天（服务端回看窗口）；
   *   · 不做"夹节目"：可跨节目连续滑（与安卓一致），边界只受上面两条约束。
   */
  private shiftBy(deltaSec: number): void {
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined || isJstvChannel(ch) || isIptvChannel(ch)) {
      return;
    }
    const nowSec: number = Math.floor(Date.now() / 1000);
    const liveEdge: number = nowSec - 2;
    /* 基准：本次手势累计值 → 当前时移位置 → 直播沿 */
    const base: number = this.shiftPendingSec > 0 ? this.shiftPendingSec
      : (this.replayStart > 0 ? this.replayStart : liveEdge);
    let target: number = base + deltaSec;
    const lo: number = nowSec - 7 * 24 * 3600;
    if (target > liveEdge) {
      target = liveEdge;
    }
    if (target < lo) {
      target = lo;
    }
    if (target === base) {
      this.gestureHint = target >= liveEdge ? '直播' : '已到回看最早处';
      return;
    }
    this.shiftPendingSec = target;
    this.shiftAccumSec += (target - base);
    /* OSD 文案与安卓一致：
     *   · 回看中 → 相对**节目起点**的秒数（`时移 +125 秒`）；
     *   · 直播态 → 用**累计位移**算落后秒数（`时移 -10 秒`），不再用 `now-target`（会多算 2 秒） */
    if (this.replayStart > 0) {
      const d: number = target - this.replayStart;
      this.gestureHint = `时移 ${d >= 0 ? '+' : ''}${d} 秒`;
    } else {
      this.gestureHint = this.shiftAccumSec >= 0 ? '直播' : `时移 ${this.shiftAccumSec} 秒`;
    }
  }

  /**
   * ★ 2026-11-09（对齐安卓 `settleTimeshift` / `doSettle`）：**手势结束才真正取流**。
   *   · 连滑多次只发一次请求；
   *   · 目标已到直播沿（≥ now−2）⇒ 回直播（不带 playbacktime）；
   *   · 否则按 `playbacktime` 重取一次（不夹节目，可跨节目连续滑）。
   */
  private applyShift(): void {
    const target: number = this.shiftPendingSec;
    this.shiftPendingSec = 0;
    this.shiftSteps = 0;
    if (target <= 0) {
      Log.i('[Index] 时移：本次无位移（已在边界）⇒ 不处理');
      return;
    }
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    const nowSec: number = Math.floor(Date.now() / 1000);
    if (target >= nowSec - 2) {
      Log.i('[Index] 时移：目标已到直播沿 ⇒ 回直播');
      this.backToLive();
      return;
    }
    Log.i(`[Index] 时移落地 ⇒ 起播 playbacktime=${target}（落后直播 ${nowSec - target}s）`);
    this.playChannel(ch, true, target, 0, this.currentName);
  }

  /**
   * ★ 2026-11-09（对齐安卓 `MainViewModel.autoNextReplay`）：**回看播完 ⇒ 自动接下一档**。
   *   · 取"起点晚于当前回看位置、已播完、官方允许回看"里**起点最早**的那一档
   *     （不按列表顺序找 idx —— EPG 与 playbacktime 差 1 秒时 idx 会 -1 ⇒ 重复当前档，安卓踩过）；
   *   · 找不到（已是最新一档 / 后面都不可回看）⇒ **回直播**，不要停在黑屏。
   */
  private autoNextReplay(): void {
    const cur: number = this.replayStart;
    if (cur <= 0) {
      return;
    }
    /* 时移（滚动窗口）不是"整档节目"，没有"下一档"的概念 ⇒ 不接档、也不回直播 */
    if (!this.replayIsProgram) {
      Log.i('[Index] 时移窗口结束（非整档回看）⇒ 保持当前位置');
      return;
    }
    const nowSec: number = Math.floor(Date.now() / 1000);
    const list: EpgItem[] = this.epgItems;
    if (list.length === 0) {
      Log.i('[Index] 回看结束：节目单为空 ⇒ 回直播');
      this.backToLive();
      return;
    }
    let next: EpgItem | undefined = undefined;
    let nextStart: number = 0;
    for (const it of list) {
      if (it.startMs <= 0 || it.endMs <= it.startMs) {
        continue;
      }
      const s: number = Math.floor(it.startMs / 1000);
      const e: number = Math.floor(it.endMs / 1000);
      if (s > cur && e <= nowSec && it.replayable) {
        if (next === undefined || s < nextStart) {
          next = it;
          nextStart = s;
        }
      }
    }
    if (next === undefined) {
      Log.i(`[Index] 回看结束：没有下一档可回看（cur=${cur}）⇒ 回直播`);
      this.backToLive();
      return;
    }
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    Log.i(`[Index] 回看结束 ⇒ 接下一档 ${next.title} ${next.start}-${next.end}`);
    this.replayKeyYmd = next.ymd;
    this.replayKeyStart = next.startMs;
    this.playChannel(ch, true, nextStart, Math.floor(next.endMs / 1000), next.title);
  }

  /** 「返回直播」：丢掉回看/时移时刻，重新按直播取流 */
  private backToLive(): void {
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    Log.i(`[Index] 返回直播 ${ch.name}`);
    this.replayStart = 0;
    this.replayEnd = 0;
    this.replayKeyYmd = '';
    this.replayKeyStart = 0;
    this.playChannel(ch, true);
  }

  private stopEpgTicker(): void {
    if (this.epgTimer !== -1) {
      clearInterval(this.epgTimer);
      this.epgTimer = -1;
    }
    if (this.epgRetryTimer !== -1) {
      clearTimeout(this.epgRetryTimer);
      this.epgRetryTimer = -1;
    }
  }

  /**
   * ★ 按"当前时间"重新判定正在播出/接下来，并同步节目条 + 弹窗里的红色标记。
   *   只做本地时间比较（时间戳在拉取时已存进 startMs/endMs）⇒ 不产生网络请求；
   *   且只在**内容真的变化**时才更新 @State，避免每 20 秒无谓重建。
   */
  private refreshEpgNow(): void {
    const items: EpgItem[] = this.epgItems;
    if (items.length === 0) {
      return;
    }
    /* ★ 原版策略（补齐）：**≥60s 才走一次网络刷新**，期间只做本地时钟推进。
     *   作用：长时间挂在一个频道上时，节目单能跟着服务端修正/更新，而不是只靠本地推进；
     *   同时用 60s 限流避免 ticker（20s 粒度）把请求打密。 */
    /* ⚠️ 正在取流/切台时**不抢带宽**：等下一个 20s tick 再做（EPG 是分钟级数据，晚 20 秒无感）。
     *   （真机日志里出现过"回前台重刷 + 换台首拉"同时发起，虽然已按 pid 去重，但仍不该与起播竞争。） */
    if (!this.loading && this.activeChannelId !== '' && Date.now() - this.lastEpgFetchAt > EPG_REFRESH_MS) {
      const chRefresh: CctvChannel | undefined =
        Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
      if (chRefresh !== undefined) {
        /* ★ 2026-11-09：周期性对齐**只拉今天**（1 个请求），其余 9 天保留——否则 30s × 10 天请求过密。
         *   回看时同样要刷新（节目单是回看/时移的判据来源，用户明确要求"包括回看时"）。 */
        Log.i(`[Index] EPG 距上次网络刷新 ≥${Math.round(EPG_REFRESH_MS / 1000)}s ⇒ 重新拉取今天`);
        this.fetchEpgToday(chRefresh.pid);
      }
    }
    const nowMs: number = Date.now();
    let nowIdx: number = -1;
    let changed: boolean = false;
    const next: EpgItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: EpgItem = items[i];
      /* ★ 2026-11-10："现在是否在播"**统一走 `epgRowState`**（弹窗里的红/绿标记与节目条
       *   必须同一判据，否则会出现"节目条说在播、弹窗说已播完"）。 */
      const cur: boolean = this.epgRowState(it) === 2;
      if (cur) {
        nowIdx = i;
      }
      if (it.now !== cur) {
        changed = true;
      }
      next.push({
        title: it.title, start: it.start, end: it.end, now: cur,
        startMs: it.startMs, endMs: it.endMs, replayable: it.replayable, ymd: it.ymd
      } as EpgItem);
    }
    if (this.replayStart > 0) {
      /* ★ 回看/时移中：节目条固定跟着回看那档，不被"直播跨点"改写 */
      this.applyReplayStrip();
    } else if (nowIdx >= 0) {
      const n: string = `${next[nowIdx].start} ${next[nowIdx].title}`;
      const nx: string = (nowIdx + 1 < next.length)
        ? `${next[nowIdx + 1].start} ${next[nowIdx + 1].title}` : '暂无';
      if (n !== this.episodeNow || nx !== this.episodeNext) {
        this.episodeNow = n;
        this.episodeNext = nx;
        Log.i(`[Index] 节目单跨点 ⇒ 正在播出: ${n}`);
      }
    }
    if (nowIdx < 0 && next.length > 0) {
      /* ★ 全部节目都已播完 ⇒ 多半是跨天（EPG 只拉了当天）⇒ 用当前频道重拉一次。
       *   用 lastEpgDay 把关：同一天内最多重拉一次，不会反复请求。 */
      const last: EpgItem = next[next.length - 1];
      const d: Date = new Date();
      const ymd: string =
        `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
      if (last.endMs > 0 && nowMs >= last.endMs && ymd !== this.lastEpgDay) {
        const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
        if (ch !== undefined) {
          Log.i('[Index] 当天节目单已播完（跨天）⇒ 重新拉取 EPG');
          this.fetchEpg(ch.pid);
        }
      }
    }
    if (changed) {
      this.epgItems = next;
    }
  }

  /**
   * ★ 全屏（横屏）切换 —— 逻辑沿用早期 ArkWeb 版（参考实现已随清理移除）：
   *   进入：AUTO_ROTATION_LANDSCAPE（忽略系统旋转锁，只在两个横屏方向间跟随重力翻转）
   *         + 隐藏系统栏 + 布局全屏；
   *   退出：AUTO_ROTATION + 恢复 status/navigation + 取消布局全屏。
   *   这样锁屏/音量/亮度等系统手势在横屏全屏下才测得到。
   */
  private async toggleFullscreen(): Promise<void> {
    try {
      const win: ohWindow.Window = this.winObj !== null
        ? this.winObj : await ohWindow.getLastWindow(getContext(this) as common.UIAbilityContext);
      this.winObj = win;
      if (!this.isFullscreen) {
        await win.setPreferredOrientation(ohWindow.Orientation.AUTO_ROTATION_LANDSCAPE);
        await win.setWindowSystemBarEnable([]);
        await win.setWindowLayoutFullScreen(true);
        this.isFullscreen = true;
        Log.i('[Index] 进入全屏（横屏自动旋转）');
      } else {
        await win.setPreferredOrientation(ohWindow.Orientation.AUTO_ROTATION);
        await win.setWindowSystemBarEnable(['status', 'navigation']);
        await win.setWindowLayoutFullScreen(false);
        this.isFullscreen = false;
        /* ★ 退出全屏复位：解锁 + 取消亮度覆盖（-1 = 跟随系统），与原版 exitFullscreen 一致 */
        this.screenLocked = false;
        this.controlsVisible = true;
        try {
          await win.setWindowBrightness(-1);
        } catch (e2) {
          Log.w('[Index] 恢复系统亮度失败');
        }
        this.curBrightness = -1;
        Log.i('[Index] 退出全屏');
      }
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`[Index] 全屏切换失败: ${err.message}`);
    }
  }

  /**
   * ★ 2026-11-09（用户要求"节目单每 30 秒对齐一次，包括回看时"）：
   *   **只重拉今天那一天**并合并进现有 10 天 —— 1 个请求/30s，代价可忽略；
   *   其余日期（前 6 / 后 3）只在换台、回前台、点开节目单时走全量 `fetchEpg`。
   */
  private async fetchEpgToday(pid: string): Promise<void> {
    if (this.epgInflightPid !== '' || this.epgTodayInflight) {
      return;   // 已有拉取在飞 ⇒ 让它来（避免重复请求同一批数据）
    }
    this.epgTodayInflight = true;
    const chId: string = this.activeChannelId;
    const ymd: string = ymdOf(0);
    const url: string = `https://capi.yangshipin.cn/api/yspepg/program/${pid}/${ymd}`;
    try {
      const one: EpgItem[] = await fetchEpgItems(url, ymd);
      if (one.length === 0 || this.activeChannelId !== chId) {
        return;
      }
      /* ★ 先剔除"今天"的旧数据（服务端可能修正过标题/时间，不剔除会新旧两份都在），
       *   再合并 + 去重（去重键含 ymd，跨天窗口头尾相接时的重复条目会被清掉）。 */
      const kept: EpgItem[] = [];
      for (const it of this.epgItems) {
        if (it.ymd !== ymd) {
          kept.push(it);
        }
      }
      const merged: EpgItem[] = epgDedupe(kept.concat(one));
      this.epgItems = merged;
      this.lastEpgFetchAt = Date.now();
      Log.i(`[Index] EPG 今日对齐完成（${one.length} 条，共 ${merged.length} 条）`);
      this.refreshEpgNow();   /* 复用"重算 now + 更新节目条/弹窗标记"，此时网络门槛已满足 ⇒ 不会再发请求 */
    } catch (e) {
      Log.w(`[Index] EPG 今日刷新失败（不影响播放）: ${(e as Error).message}`);
    } finally {
      this.epgTodayInflight = false;
    }
  }

  /**
   * ★ 打开节目单后，把"正在播出"那条**定位到弹层竖直中间**。
   *   直接调用会因为 Scroll 还没完成布局而失败 ⇒ 延迟 60ms 再滚（找不到当前节目就滚到第一条）。
   */
  private scrollEpgToNow(): void {
    /* ★ 列表现在只显示**选中那一天** ⇒ 索引要在"当天列表"里找。
     * ★ 2026-11-09（用户要求）：**回看中优先定位到"正在回看的那一档"**（红粗「回看中」那条），
     *   没有再找"正在播出"，都没有才回到第一条（与安卓 `EpgModal` 的 LaunchedEffect 同规则）。 */
    const day: EpgItem[] = this.epgOfDay(this.epgSelDay);
    let idx: number = -1;
    if (this.replayStart > 0) {
      idx = day.findIndex((it: EpgItem) => this.epgInReplay(it));
    }
    if (idx < 0) {
      /* ★ 用 `epgRowState` 而不是 `it.now`（后者是拉数据时的快照，跨点/跨天会过期） */
      idx = day.findIndex((it: EpgItem) => this.epgRowState(it) === 2);
    }
    if (idx < 0) {
      idx = 0;
    }
    /* ★ 用 List + ListScroller.scrollToIndex(..., ScrollAlign.CENTER)：
     *   - Scroll 的 scrollToIndex 对"单个 Column 子节点"支持不稳（真机上表现为不居中/无效）；
     *   - List 按 index 定位是标准能力，CENTER 即"目标项落在视口中间"。
     *   延迟 250ms 等弹层与列表完成布局（太早调用会被丢弃）。 */
    setTimeout(() => {
      try {
        this.epgListScroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
        Log.i(`[Index] EPG 定位到第 ${idx + 1} 条（正在播出，居中）`);
      } catch (e) {
        const err = e as Error;
        Log.w(`[Index] EPG 定位到当前节目失败: ${err.message}`);
      }
    }, 250);
  }

  /**
   * ★ 回前台：
   *   - 后台停留 **≤10s**：直接 `play()` 恢复（URL 还新鲜，最快）；
   *   - 后台停留 **>10s**：直播 m3u8/分片已过期，**用当前频道重新拉流**
   *     （否则回来会卡住或播到过期分片边界；用户要求）。
   */
  onPageShow(): void {
    const wasHidden: boolean = this.hideAt > 0;
    const away: number = wasHidden ? (Date.now() - this.hideAt) : 0;
    this.hideAt = 0;
    /* ★ 2026-09-18（C3）：退后台已在 `onPageHide` 里**立即**做完 ⇒ 这里无需"取消宽限期"（设计已废弃） */
    /* ★ 打点复位：否则"点击→出画 / setup→出画"会拿上一次的起点算出十几秒的假数字 */
    this.tClickChannel = 0;
    this.tSetupStart = 0;
    /* ★ 冷启动：onPageShow 会在 `aboutToAppear` 的 `bootSequence()` 之前触发，
     *   这时没有任何频道/播放器，**初始化一律交给 bootSequence**（否则日志里会出现
     *   `onPageShow ⇒ 恢复播放（后台 0s）` 这种误导行，而且会白建一次媒体卡）。 */
    if (!wasHidden && this.avPlayer === null && this.activeChannelId === '') {
      Log.i('[Index] onPageShow ⇒ 冷启动（初始化由 bootSequence 负责）');
      return;
    }
    /* ★ 回前台：网络状态未知 ⇒ 清掉"断网标记 + 续播计数"，给这次恢复完整的重试额度 */
    this.resetNetResume();
    /* ★ 2026-09-18：解除本地代理的"后台挂起"（退后台时置位，避免为死 socket 下载/解密） */
    this.server.setSuspended(false);
    /* ★ 音频焦点：回前台重新激活（SHARE/MIX） */
    const afShow: AudioFocus | null = this.audioFocus;
    if (afShow !== null) {
      afShow.activate();
    }
    /* ★ 重建媒体卡（退后台时销毁过）+ 用当前频道刷新标题/台标 */
    const ctxShow: common.UIAbilityContext | undefined = this.hostContext();
    if (ctxShow !== undefined) {
      this.initTvSession(ctxShow).then(() => {
        const chShow: CctvChannel | undefined =
          Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
        const tsShow: TvSession | null = this.tvSession;
        if (tsShow !== null && chShow !== undefined) {
          tsShow.setChannel(chShow.name, chShow.id, this.iconMap[chShow.id]);
        }
      }).catch((e: Error) => {
        Log.w(`[Index] 回前台重建媒体卡失败（忽略）: ${e.message}`);
      });
    }
    /* ★ 后台期间定时器被停掉 ⇒ 先补一次节目单刷新并重启（后台可能已跨点） */
    if (this.epgItems.length > 0) {
      this.refreshEpgNow();
      this.startEpgTicker();
    }
    /* ★★ 2026-09-18（C3）：回前台恢复策略（**按离场时长二选一**）★★
     *   ① **≤ `REVIVE_SAME_URL_MAX_MS`** ⇒ `reviveSameUrl()` **轻量恢复**：复用同一个本地 m3u8 URL
     *      **重建播放器**，跳过 auth/签名/取流。12:33~12:39 实测出画 **190ms~1230ms**
     *      （全程命中缓存时 ~200ms），远好于"`play()` 停在旧画面 2.9~5.8s"和"完整重新拉流 1~2s"。
     *      为什么不用 `play()`：实测（11:40:50）调用成功后播放器**停在旧画面**，要等下一次 playlist 轮询。
     *      为什么上限放到 30s：实测 22s 后台用同一 token 轻量恢复**成功**（12:39:33，1829ms）
     *      ⇒ 远端 token 有效期远大于原先假设的 10s；真过期时 prepare 失败会自动退化为 ②。
     *   ② **> 30s** ⇒ **完整重新拉流**（重算 cKey + 重新 liveinfo 取流）。
     *   ⚠️ 顺序要紧：原先 ① 写在了 ② 之前且条件写成"只要有活跃频道"，把 ② 整个挡掉了
     *      （日志里出现过 `后台 12s（≤10s）`/`后台 22s（≤10s）` 这种自相矛盾的行）。 */
    if (this.activeChannelId !== '') {
      this.needRecoverOnShow = false;
      if (away > REVIVE_SAME_URL_MAX_MS) {
        Log.i(`[Index] onPageShow ⇒ 后台 ${Math.round(away / 1000)}s（>${Math.round(REVIVE_SAME_URL_MAX_MS / 1000)}s）⇒ 当前频道重新拉流`);
        this.replayActiveChannel();
      } else {
        Log.i(`[Index] onPageShow ⇒ 后台 ${Math.round(away / 1000)}s（≤${Math.round(REVIVE_SAME_URL_MAX_MS / 1000)}s）⇒ 轻量恢复（复用本地 URL 重建播放器）`);
        this.reviveSameUrl();
      }
      return;
    }
    /* ★ 没有活跃频道（异常态）但后台报过播放器错误 ⇒ 先销毁重建再恢复 */
    if (this.needRecoverOnShow) {
      this.needRecoverOnShow = false;
      Log.i(`[Index] onPageShow ⇒ 后台 ${Math.round(away / 1000)}s，恢复播放器（后台曾报错，未在后台重建）`);
      this.destroyPlayer().then(() => {
        setTimeout(() => { this.replayActiveChannel(); }, 300);
      });
      return;
    }
    Log.i(`[Index] onPageShow ⇒ 恢复播放（后台 ${Math.round(away / 1000)}s）`);
    this.resumePlayback();
  }

  /**
   * ★★ 退后台（对齐原版 `CctvPoC` 的直播后台策略）★★
   *
   * 用户问"后台还留着媒体卡、还能控制，有必要吗？"——**没有必要，而且有害**：
   *   直播流在后台继续拉流 + 解密毫无意义（m3u8 令牌/分片都会过期；回前台 >10s 反正要重新取流），
   *   而卡片留着就会出现"按了没反应"的失效按钮（换台/解密在后台都可能失败）。
   * ⇒ 原版的做法：**退后台 = 暂停 + 停止拉流 + 销毁媒体卡 + 归还音频焦点**，回前台再重建。
   *    本函数照此逐条落地（顺序也有讲究：先停下载，再销毁会话，最后归还焦点）。
   */
  onPageHide(): void {
    this.hideAt = Date.now();
    this.stopEpgTicker();   /* ★ 后台不停没必要；回前台 onPageShow 里会补一次刷新并重启 */
    this.cancelNetResume(); /* ★ 后台不做网络续播轮询（回前台 onPageShow 会重新拉流） */
    /* ★★★ 2026-09-18（C3）：**立即、同步**完成全部退后台 ★★★
     *   为什么不"延迟到宽限期再退"（试过、已废弃 —— 教训见 NET_DOWN_WINDOW_MS 下面）：
     *     **后台里 JS 定时器会被系统挂起**：2500ms 的定时器实际 9.5s 后才执行
     *     （11:49:41.191 退后台 → 11:49:50.718 才真正退），期间**音画一直在播、焦点没还**
     *     ⇒ 用户质疑"后台后还一直播放"。
     *   ⇒ 退后台必须当机立断：暂停（存 `pauseTask`）+ 关常亮 + 还焦点 + 停预热 + 挂代理 + 销毁媒体卡。
     *     回前台的快，靠 `reviveSameUrl()`（复用同一个本地 m3u8 URL 重建播放器，跳过 auth/签名/取流）实现。 */
    this.pauseTask = null;
    const p: media.AVPlayer | null = this.avPlayer;
    if (p !== null && p.state === 'playing') {
      this.pauseTask = p.pause().then(() => {
      }).catch((e: BusinessError) => {
        Log.w(`[Index] 退后台暂停失败: ${e.message}`);
      });
    }
    this.pausedByInterrupt = false;
    this.applyKeepScreenOn(false);
    const afHide: AudioFocus | null = this.audioFocus;
    if (afHide !== null) {
      afHide.deactivate();
    }
    this.server.abortPrewarm();
    this.server.setSuspended(true);
    const tsHide: TvSession | null = this.tvSession;
    if (tsHide !== null) {
      tsHide.destroy();
      this.tvSession = null;
    }
    Log.i('[Index] onPageHide ⇒ 立即退后台：已暂停、归还焦点、作废预热、挂起代理、销毁媒体卡');
  }

  /**
   * ★ 恢复播放：优先 `play()`；失败说明直播 URL 已过期 ⇒ 用**当前频道重新取流**。
   *   （直播 m3u8 带 svrtime 时效，后台待久了回来必然失效。）
   */
  private resumePlayback(): void {
    /* ★★ 2026-09-18：先等"退后台的 pause()"结算 —— 快速切回时（往往 <100ms）play() 会先发出、
     *    pause 后结算 ⇒ 播放器停在 paused，表现为"回前台不自动续播/要等很久"。 */
    const task: Promise<void> | null = this.pauseTask;
    this.pauseTask = null;
    if (task !== null) {
      task.then(() => { this.doResumePlayback(); });
      return;
    }
    this.doResumePlayback();
  }

  /** `resumePlayback` 的实际动作（等 pause 落地后调用） */
  private doResumePlayback(): void {
    if (this.hideAt > 0) {
      return;   /* 等待期间又退后台了 ⇒ 不续播（回前台会再走一遍） */
    }
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    const s: string = p.state;
    if (s === 'prepared' || s === 'paused' || s === 'playing') {
      p.play().catch((e: BusinessError) => {
        Log.w(`[Index] 恢复播放失败(${e.message}) ⇒ 重新取流`);
        this.replayOrWait();   // ★ 断网感知：网络刚失败则转 5s 轮询，不硬重拉
      });
    } else if (s === 'idle' || s === 'stopped' || s === 'initialized') {
      this.replayOrWait();
    }
  }

  /**
   * ★★ 2026-09-18（C3）：短离回前台的**轻量恢复** ★★
   *
   * 为什么不是 `play()`：实测（11:40:50）调用成功后播放器**停在旧画面**，要等它下一次轮询 playlist
   *   才继续（2.9~5.8s）—— 这正是用户看到的"卡住不动"。
   * 为什么不是完整重新拉流：那要重跑 auth→签名→取流（≈250~600ms）。这里**复用同一个本地 m3u8 URL**
   *   （远端 token 在 10s 内仍有效 + 明文分片缓存还在）⇒ 只重建播放器，一般 0.4~1.0s 出画。
   * 失败自愈：URL 过期 / 代理报错 ⇒ `prepare` 失败 ⇒ `recoverPlayer` 自动走完整重新拉流（无需额外代码）。
   */
  private reviveSameUrl(): void {
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined || this.videoSrc === '') {
      this.replayActiveChannel();   /* 没有可复用的 URL ⇒ 退回完整重新拉流 */
      return;
    }
    const url: string = this.videoSrc;
    Log.i(`[Index] 轻量恢复 ⇒ 重建播放器（复用同一本地 URL，跳过 auth/签名/取流）`);
    this.bootMsg = `${ch.name} 正在恢复…`;
    this.tClickChannel = Date.now();
    if (isJstvChannel(ch)) {
      /* ★ 江苏台：上游签名由代理现算 ⇒ 用 streamId 让代理把 playlist + 首 2 片重新备好 */
      this.server.prewarmJstv(ch.streamId !== undefined ? ch.streamId : ch.id);
    }
    /* 央视频明文链路：本地 URL 里已经带着上游 playurl（含一次性令牌，30s 内仍有效）
     * ⇒ 直接重建播放器即可，不做额外预热（缓存里的明文分片仍有效）。 */
    this.server.ensureStarted().then(() => {
      this.setupPlayer(url);
      this.armAutoRetry(ch);
      const ts: TvSession | null = this.tvSession;
      if (ts !== null) {
        ts.setChannel(ch.name, ch.id, this.iconMap[ch.id]);
      }
    }).catch((e: Error) => {
      Log.w(`[Index] 轻量恢复失败(${e.message}) ⇒ 完整重新拉流`);
      this.replayActiveChannel();
    });
  }

  /** 用当前选中的频道重新走一遍 playChannel（切台/恢复共用） */
  private replayActiveChannel(): void {
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch !== undefined) {
      /* ★ 内部重取（非用户点选）⇒ byUser=false；**回看/时移状态要沿用**（否则一恢复就跳回直播） */
      this.playChannel(ch, false, this.replayStart, this.replayEnd, this.currentName);
    }
  }

  /** ★ 网络是否处于"刚失败"窗口内（断网期间不必重建播放器 / 不必反复重拉） */
  private isNetDownRecently(): boolean {
    return this.netDownAt > 0 && (Date.now() - this.netDownAt) < NET_DOWN_WINDOW_MS;
  }

  /**
   * ★★ 断网感知的重拉：网络刚失败 ⇒ **不重拉**（避免"重拉风暴"把恢复弄得更慢），
   *   交给 `scheduleNetResume()` 的 5s 轮询；否则正常重拉当前频道。
   */
  private replayOrWait(): void {
    /* ★ 后台不重拉（同 recoverPlayer：后台重拉 = 白下载 + 白解密 + 作废 token）。
     *   当前频道会在回前台时按 `needRecoverOnShow` / `>10s` 规则恢复。 */
    if (this.hideAt > 0) {
      this.needRecoverOnShow = true;
      Log.w('[Index] 已在后台 ⇒ 不重拉流（回前台再恢复）');
      return;
    }
    if (this.isNetDownRecently()) {
      Log.w('[Index] 网络刚失败 ⇒ 暂不重拉流（改为 5s 轮询续播）');
      this.scheduleNetResume();   // 交给轮询：网络一恢复就自动续播
      return;
    }
    this.replayActiveChannel();
  }

  /** 取消"网络恢复自动续播"（换台 / 退后台 / 成功出画时调用） */
  private cancelNetResume(): void {
    if (this.netResumeTimer !== -1) {
      clearTimeout(this.netResumeTimer);
      this.netResumeTimer = -1;
    }
  }

  /** 出画成功 ⇒ 清空网络异常标记与续播计数（下次断网重新计满 24 次） */
  private resetNetResume(): void {
    this.cancelNetResume();
    this.netResumeTries = 0;
    this.netDownAt = 0;
  }

  /**
   * ★★ 网络类失败 ⇒ 安排"网络恢复后自动续播" ★★
   *   用户实测：**断网 → 迅速恢复网络**后 App 停在报错不动（因为失败时 `activeChannelId`
   *   被清空、也没有任何重试在跑）⇒ 这里**保留用户选择的频道**，每 5s 用当前频道重试，
   *   最多 24 次（≈2 分钟）；出画即停。
   */
  private scheduleNetResume(): void {
    this.cancelNetResume();
    const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    if (this.netResumeTries >= NET_RESUME_MAX) {
      this.bootMsg = `${this.currentName} 网络不可用，请检查网络后重新点击频道`;
      Log.w('[Index] 网络恢复续播已达上限 ⇒ 停止自动重试');
      return;
    }
    this.netResumeTries++;
    const sec: number = Math.round(NET_RESUME_GAP_MS / 1000);
    const chId: string = ch.id;
    this.bootMsg = `${this.currentName} 网络异常，${sec}s 后自动重试（${this.netResumeTries}/${NET_RESUME_MAX}）`;
    Log.w(`[Index] 网络异常 ⇒ ${sec}s 后自动重试续播（第 ${this.netResumeTries}/${NET_RESUME_MAX} 次）`);
    this.netResumeTimer = setTimeout(() => {
      this.netResumeTimer = -1;
      if (this.activeChannelId !== chId || this.loading) {
        return;   // 期间换台了 / 已有取流在跑 ⇒ 本次作废
      }
      const c: CctvChannel | undefined = Channels.find((x: CctvChannel) => x.id === chId);
      if (c !== undefined) {
        this.playChannel(c, false);   /* ★ 断网续播重试（非用户点选）⇒ byUser=false */
      }
    }, NET_RESUME_GAP_MS);
  }

  /**
   * 视频区可用宽/高（vp）。
   * ★ 优先用 `playerArea` 里 Stack 的 `onAreaChange` **实测值**（自校正：横竖屏、全屏、
   *   横屏左列宽度、以及上方状态栏/下方节目条占位都会被算进去），
   *   没有实测值时才按窗口推算兜底。
   */
  /**
   * ★ 横屏「分栏」模式 = 横屏 **且非全屏**。
   *   全屏时窗口同样是横的，但布局必须按"整屏"处理（不再左右分栏）；
   *   否则会被误当作横屏分栏 ⇒ 画面还是窗口大小（真机症状，用户报）。
   *   凡"横屏/竖屏决定分栏"的地方都用它，而不是 `isLandscape`。
   */
  private isWide(): boolean {
    return this.isLandscape && !this.isFullscreen;
  }

  /** 读系统安全区（顶部状态栏 / 底部导航栏，vp）。
   *  ★ 旋转、进出全屏后**必须重读**：竖屏读到的 top（如 38.8vp）若直接用到横屏，
   *   顶部会多出一整条黑带（用户实测"横屏上方多出黑屏区"）——横屏系统栏位置与竖屏不同。 */
  private readInsets(w: ohWindow.Window): void {
    try {
      const avoid: ohWindow.AvoidArea = w.getWindowAvoidArea(ohWindow.AvoidAreaType.TYPE_SYSTEM);
      this.insetTop = this.getUIContext().px2vp(avoid.topRect.height);
      this.insetBottom = this.getUIContext().px2vp(avoid.bottomRect.height);
      Log.i(`[Index] 安全区 top=${this.insetTop} bottom=${this.insetBottom}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`[Index] 读安全区失败: ${err.message}`);
    }
  }

  /**
   * ★★ 视频区尺寸必须**解析计算**，不能用 onAreaChange 的量测值：
   *   因为 playerArea 的高度又是按"画面高度"反推的 ⇒ 用量测值会形成
   *   高度→量测→高度 的循环依赖；横屏时还会让左列总高超出屏幕
   *   （真机症状：视频只露出上半部分、下方节目条被挤到屏外）。
   */
  /**
   * ★★ 视频区可用尺寸：**优先用 playerArea 的实测值**（onAreaChange 量出来的）。
   *   现在这样是安全的 —— playerArea 的高度由**布局权重**分配（见 playerArea 的 layoutWeight），
   *   与 XComponent 的尺寸无关 ⇒ 不会出现"高度→量测→高度"的循环；
   *   而画面永远是"contain 适配"，必然 ≤ 容器 ⇒ 不可能溢出、节目条不可能被挤走。
   *   量测值还没到位时才用兜底估算。
   */
  private videoAreaW(): number {
    if (this.videoZoneWidth > 0) {
      return this.videoZoneWidth;
    }
    const w: number = this.winW > 0 ? this.winW : 360;
    if (this.isFullscreen) {
      return w;                             // 全屏：系统栏已隐藏 ⇒ 内容区就是整屏
    }
    return this.isWide() ? w * 0.68 : w;    // 横屏分栏：左列 68%；竖屏：整宽
  }

  private videoAreaH(): number {
    if (this.videoZoneHeight > 0) {
      return this.videoZoneHeight;
    }
    const h: number = this.winH > 0 ? this.winH : 640;
    if (this.isFullscreen) {
      return h;                             // 全屏：整屏高
    }
    if (this.isWide()) {
      /* 兜底估算（只在 playerArea 还没量出尺寸时用一帧）：屏高 − 底部安全区 − 信息栏 − 节目条 − 间距。
       * 用常量而不是"实测栏高"：真正的可用高度由 `playerArea` 的**布局权重**分配、再实测回填，
       * 这里只是首帧兜底 ⇒ 常量足够，也就**不需要**再为信息栏/节目条各挂一个 @State 量测（省两次重建）。
       *（不减 insetTop：窗口内容区本身已避开顶部状态栏，见 Flex padding 处的说明） */
      return Math.max(90, h - this.insetBottom - STATUS_BAR_H0 - EPG_STRIP_H0 - 16);
    }
    return 210;                             // 竖屏：固定 210vp
  }

  /**
   * ★ 视频显示尺寸：按**视频真实宽高比** contain 适配到可用区域。
   *   为什么必须自己算：XComponent 的 surface 尺寸就是显示尺寸，若与视频比例不一致，
   *   真机上会被**拉伸变形**（用户实测"横屏/全屏有拉伸"）。这里算好宽高，配合
   *   `videoScaleType = FIT` 双保险。
   */
  private videoBoxW(): number {
    const av: number[] = this.videoBox();
    return av[0];
  }

  private videoBoxH(): number {
    const av: number[] = this.videoBox();
    return av[1];
  }

  /** 居中用的下边距（Stack 是 Bottom 对齐 ⇒ 用 bottom margin 把画面顶到垂直居中） */
  private videoBoxBottom(): number {
    return Math.max(0, Math.floor((this.videoAreaH() - this.videoBoxH()) / 2));
  }

  private videoBox(): number[] {
    const aw: number = this.videoAreaW();
    const ah: number = this.videoAreaH();
    let vw: number = this.videoW > 0 ? this.videoW : 16;
    let vh: number = this.videoH > 0 ? this.videoH : 9;
    /* ★ 源头标错 PAR 的台：用**已在画面上生效**的修正值（见 videoArFix 注释） */
    if (this.videoArFix > 0) {
      vw = this.videoArFix;
      vh = 1;
    }
    let w: number = aw;
    let h: number = w * vh / vw;
    if (h > ah) {
      h = ah;
      w = h * vw / vh;
    }
    return [Math.floor(w), Math.floor(h)];
  }

  /** ★ 显示控制条；**全屏时** 3 秒后自动隐藏（非全屏常显，方便点全屏）—— 对齐原版 showControls */
  private showControls(): void {
    this.controlsVisible = true;
    if (this.controlsTimer !== -1) {
      clearTimeout(this.controlsTimer);
    }
    this.controlsTimer = setTimeout(() => {
      // ★ 窗口模式与全屏**都要** 3 秒自动隐藏（按用户要求，原来窗口模式常显）
      this.controlsVisible = false;
      this.controlsTimer = -1;
    }, 3000);
  }

  /** ★ 把当前音量应用到播放器（静音 ⇒ 0） */
  private applyVolume(): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    /* ★ 播放器音量：静音时为 0，否则为手势设定的 volRatio（0~1）。
     *   setVolume 只在 prepared/playing/paused/completed 有效（其它状态报 5400102）。 */
    const s: string = p.state;
    if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed') {
      p.setVolume(this.muted ? 0 : this.volRatio);
    }
  }

  /**
   * ★ 手势调音量：改**播放器自身音量**（0~1）。
   *   ⚠️ 曾经试过"直接改系统媒体音量"（`AudioManager.setVolume`，原版就是这么做的），
   *   但那是 **deprecated API**（且要 ACCESS_NOTIFICATION_POLICY 权限），**不符合规范**，
   *   按用户要求改回播放器音量（与系统音量叠加，符合应用侧规范）。
   */
  private setPlayerVolumeByRatio(ratio: number): void {
    this.volRatio = Math.max(0, Math.min(1, ratio));
    if (this.muted && this.volRatio > 0) {
      this.muted = false;   // 调音量即解除静音
    }
    this.applyVolume();
  }

  /**
   * ★★ 播放器容错重建（2026-09-15，用户实测问题）★★
   *   现象：App **长时间后台**后回前台，信息栏一直"正在缓冲…"，且此后**每个频道都失败**。
   *   日志证据：`AVPlayer 已挂载 surface` 之后 **3ms** 就 `prepare 失败: failed to prepare`
   *   —— 比播放器去拉 playlist 还早，**不是网络问题**；而是底层播放引擎/会话已被系统回收，
   *   该 AVPlayer 实例已不可用，而旧代码一直**复用它** ⇒ 每个新频道必然失败 ✗
   *   ⇒ 唯一可靠解法：**销毁并重建 AVPlayer**，然后重新拉流。最多 3 次，出画即归零。
   */
  private recoverPlayer(reason: string): void {
    /* ★★★ 后台**绝不**重建/重拉（2026-09-16 日志实锤）★★★
     *   真机日志：`17:04:18 onPageHide` → `17:04:41 播放器异常(state=error) ⇒ 销毁重建并重拉流（第 1/3 次）`
     *   → `17:05:08 …（第 2/3 次）`：这两次**都发生在后台**。原因很直白 —— 直播流暂停久了播放器会报
     *   error，而旧代码照旧重建 + `replayActiveChannel()` ⇒ 后台完整跑了 auth→取流→解密，
     *   既违背"后台不下载不解密"，又反复作废 token（下一次 get_live_info 就 401）。
     *   ⇒ 后台只**登记**"回前台需要恢复"，什么都不做（`onPageShow` 里处理）。 */
    if (this.hideAt > 0) {
      this.needRecoverOnShow = true;
      Log.w(`[Index] 已在后台 ⇒ 不重建/不重拉，只登记待恢复: ${reason}`);
      return;
    }
    /* ★★ 2026-10-01（与安卓同步，用户要求：**没有播放源马上回退**）★★
     *   直连台（江苏 / IPTV）**没有取流阶段** —— AVPlayer 一报错就说明源本身取不到（清单能拉到、
     *   分片却拿不到，例如"香港卫视"那条代理 m3u8）。此时"重建 3 次 + 重拉"只会让用户干看
     *   "播放异常，正在恢复(1/3)…"⇒ **直接真切回原台**，不重建、也不显示恢复文案。
     *   央视频链路保留重建：那是另一个故障模式（播放器会话被系统回收 ⇒ 此后每个台都失败，只有重建能救，
     *   2026-09-15 实测结论）；而它的"无源"（含 CCTV-10 的 code=12 版权提示）在**取流阶段**就判掉了，
     *   根本走不到这里 ⇒ 两条路径的体验因此统一：**没源就立刻回退，不弹"正在恢复"**。 */
    const cur: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
    if (cur !== undefined && isLocalDirectChannel(cur)) {
      Log.w(`[Index] ${cur.name} 直连源播放器报错(${reason}) ⇒ 立即回退原台（不重建）`);
      if (this.fallbackToPlayingChannel(cur.name, reason)) {
        return;
      }
      /* ★ 2026-10-02：把 id 一起传进去 —— 只有"失败的就是用户亲手点的那个台"才用"请点击其他频道"口径 */
      this.noticeNoSignal(cur.name, cur.id);
      this.destroyPlayer();
      return;
    }
    if (this.playerRebuilds >= 3) {
      Log.e(`[Index] 播放器重建已达上限(3): ${reason}`);
      /* ★★ 2026-09-23：**先回退原台，再谈放弃** ★★
       *   原实现直接把画面留在卡死状态并提示"播放器异常，无法自动恢复，请换台或重新打开应用"
       *   （用户实测：切到无信号的 IPTV 台就是这样死在上面）。现在：只要手上还有"真正出过画的原台"，
       *   就**切回去播**；确无原台可退（如开机后第一次点击就命中坏台）才保留这句最终提示。 */
      if (this.fallbackToPlayingChannel(this.currentName, `重建上限(${reason})`)) {
        return;
      }
      this.playErr = true;
      this.bootMsg = `${this.currentName} 播放异常，请换台或重开应用`;
      this.showVideoNotice('播放器异常，无法自动恢复，请换台或重新打开应用');
      this.applyKeepScreenOn(false);
      const tsFail: TvSession | null = this.tvSession;
      if (tsFail !== null) {
        tsFail.setStopped();
      }
      /* ★ 别把"卡死的画面"留在屏幕上（用户明确抱怨过）：释放播放器 ⇒ 变黑屏 + 保留提示文案 */
      this.destroyPlayer();
      return;
    }
    /* ★★ 断网期间**不要重建播放器**：prepare 必然失败，只会叠加成"重建风暴"
     *   （用户实测断网时日志里 destroy/重建/重拉 反复出现，反而更慢）。
     *   ⇒ 只提示并交给"网络恢复自动续播"轮询。 */
    if (this.isNetDownRecently()) {
      Log.w(`[Index] 网络不可用期间不重建播放器，等待网络恢复续播: ${reason}`);
      this.playErr = false;
      this.bootMsg = `${this.currentName} 网络异常，正在等待网络恢复…`;
      this.scheduleNetResume();
      return;
    }
    this.playerRebuilds++;
    Log.w(`[Index] 播放器异常(${reason}) ⇒ 销毁重建并重拉流（第 ${this.playerRebuilds}/3 次）`);
    this.bootMsg = `${this.currentName} 播放异常，正在恢复（${this.playerRebuilds}/3）…`;
    this.destroyPlayer().then(() => {
      setTimeout(() => { this.replayActiveChannel(); }, 300);
    });
  }

  /** 释放当前 AVPlayer。surfaceId 保留（XComponent 未重建 ⇒ 重建后仍用同一个 surface） */
  private async destroyPlayer(): Promise<void> {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    this.avPlayer = null;
    this.playing = false;
    this.setupGen++;   // ★ 让正在进行的 setupPlayer（若有）失效
    try {
      await p.release();
      Log.i('[Index] 已释放 AVPlayer（下次换台将重建）');
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`[Index] release 失败（忽略）: ${err.message}`);
    }
  }

  /** ★ 新增：setupPlayer 世代号（避免并发创建多个 AVPlayer + 过滤旧实例回调） */
  private setupGen: number = 0;

  /**
   * ★ 原生 AVPlayer：创建/复用实例、挂 surface、设 url；prepare/play 由状态机驱动。
   *
   * ★★ 本次修复（2026-09-16）：
   *   1) 加**世代号**：每次调用 setupPlayer 时 gen++；createAVPlayer 的 await 之后检查
   *      `myGen !== this.setupGen` ⇒ 被新台取代 ⇒ 释放刚创建的实例、直接返回。
   *   2) 每次 setupPlayer 都**销毁旧实例、重建新的**，不复用。
   *      原因：复用时 `reset()` 是异步的，旧实例的 prepared/playing 回调会在新状态下
   *      触发 `onPlayerState`，操作到错误的实例 ⇒ 5400102 大面积刷屏。
   *   3) `stateChange` / `error` / `videoSizeChange` 回调里也检查世代号，
   *      被取代的旧实例不再干扰当前状态机。
   */
  private async setupPlayer(url: string): Promise<void> {
    const myGen: number = ++this.setupGen;
    try {
      this.tSetupStart = Date.now();   // ★ 起播打点：setupPlayer 开始时刻
      Log.i(`[Index] ▶ setupPlayer[gen=${myGen}] 开始 at ${this.tSetupStart}`);

      /* ★★★ release 不 await（关键修复 2026-09-16）★★★
       *   实测：release() 会阻塞 700~1100ms（要等底层解码器/会话回收），
       *   而新 AVPlayer 用的是**同一个 XComponent surface**，可以立即创建，无需等待。
       *   ⇒ 让 release 在后台跑，不阻塞当前流程；旧实例的 stateChange 回调
       *     由世代号（myGen）过滤，不会干扰新实例。 */
      if (this.avPlayer !== null) {
        const old: media.AVPlayer = this.avPlayer;
        this.avPlayer = null;
        this.playing = false;
        Log.i(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 已异步发起（不阻塞）`);
        old.release()
          .then(() => {
            Log.i(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 完成（异步）`);
          })
          .catch((e: BusinessError) => {
            Log.w(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 失败（忽略）: ${e.message}`);
          });
      }

      const p: media.AVPlayer = await media.createAVPlayer();

      /* ★★★ 关键：await 之后如果已被新台取代，立即释放刚创建的实例 ★★★ */
      if (myGen !== this.setupGen) {
        Log.w(`[Index] setupPlayer[gen=${myGen}] 被新台取代（新 gen=${this.setupGen}）⇒ 释放并放弃`);
        try {
          await p.release();
        } catch (e) {
          // ignore
        }
        return;
      }

      p.on('stateChange', (state: string) => {
        /* ★ 世代号过滤：旧实例的回调不再进入状态机 */
        if (myGen !== this.setupGen) {
          Log.i(`[Index] setupPlayer[gen=${myGen}] 旧实例 state=${state} 回调被忽略`);
          return;
        }
        this.onPlayerState(state);
      });
      p.on('error', (err: BusinessError) => {
        if (myGen !== this.setupGen) {
          return;
        }
        Log.e(`[Index] AVPlayer error ${err.code}: ${err.message}`);
        const st: string = this.avPlayer !== null ? this.avPlayer.state : 'idle';
        if (st === 'playing' || st === 'prepared') {
          Log.w(`[Index] 忽略瞬时网络错误（播放器状态 ${st}，仍在播）: ${err.code}`);
          return;
        }
        const now: number = Date.now();
        if (now - this.lastErrReplay < 10000) {
          Log.w('[Index] 距上次自动重连不足 10s，本次只告警');
          this.playErr = true;
          this.bootMsg = `${this.currentName} 播放中断`;
          return;
        }
        this.lastErrReplay = now;
        this.bootMsg = `${this.currentName} 信号中断，正在重连…`;
        this.playErr = false;
        Log.w('[Index] 播放中断 ⇒ 重新取流续播（网络刚失败则转 5s 轮询）');
        this.replayOrWait();
      });
      p.on('videoSizeChange', (w: number, h: number) => {
        if (myGen !== this.setupGen) {
          return;
        }
        if (w > 0 && h > 0) {
          this.videoW = w;
          this.videoH = h;
          Log.i(`[Index] 视频分辨率 ${w}x${h}`);
        }
      });
      /* ★★ 音频打断（来电 / 其它应用抢焦点）—— 原版用 ArkWeb 拿不到 renderer 做不了，
       *   我们用 AVPlayer 有原生回调（`media.AVPlayer.on('audioInterrupt')`，@since 12）：
       *     - hint=PAUSE/STOP：**系统强制暂停**时我们已经自动停了；`INTERRUPT_SHARE`(非强制)
       *       时系统不代劳，需要应用自己暂停；
       *     - hint=RESUME：只有"因打断而暂停"的才自动恢复（用户手动暂停过就不抢回来）。
       *   ⚠️ 直播被打断后若超过 ~10s，URL 可能已过期 ⇒ 走 resumePlayback 的状态分支，
       *     失败时会自动 `replayOrWait()` 重新取流。 */
      p.on('audioInterrupt', (info: audio.InterruptEvent) => {
        if (myGen !== this.setupGen) {
          return;
        }
        const forced: boolean = info.forceType === audio.InterruptForceType.INTERRUPT_FORCE;
        Log.i(`[Index] 音频打断: event=${info.eventType} hint=${info.hintType} force=${info.forceType}`);
        if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
          info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
          /* 只对"暂停"记标记：STOP 语义上不该被我们自动恢复 */
          this.pausedByInterrupt = (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE);
          if (!forced) {
            const cur: media.AVPlayer | null = this.avPlayer;
            if (cur !== null && cur.state === 'playing') {
              cur.pause().catch((e: BusinessError) => {
                Log.w(`[Index] 打断暂停失败: ${e.message}`);
              });
            }
          }
          this.playing = false;
          this.bootMsg = `${this.currentName} 被其他应用中断，稍后自动恢复`;
        } else if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
          if (this.pausedByInterrupt) {
            this.pausedByInterrupt = false;
            Log.i('[Index] 音频打断结束 ⇒ 恢复播放');
            this.bootMsg = `${this.currentName} 正在恢复…`;
            this.resumePlayback();
          }
        }
      });

      this.avPlayer = p;
      Log.i(`[Index] setupPlayer[gen=${myGen}] 原生 AVPlayer 已创建`);

      /* ★ 起播水线改回 2 秒（与 KEEP_SEGMENTS=2 对齐）：1 秒太激进，AVPlayer 会因
       *   无法满足“live 流可连续播放”的内部判定而卡在 prepared 之前。 */
      const strategy: media.PlaybackStrategy = {
        preferredBufferDurationForPlaying: 2,
        showFirstFrameOnPrepare: true
      };
      const src: media.MediaSource = media.createMediaSourceWithUrl(url);
      await p.setMediaSource(src, strategy);
    } catch (e) {
      const err = e as BusinessError;
      this.playErr = true;
      this.bootMsg = `${this.currentName} 播放器初始化失败`;
      Log.e(`[Index] setupPlayer[gen=${myGen}] 失败 ${err.code}: ${err.message}`);
    }
  }

  /** ★ AVPlayer 状态机（由 stateChange 回调驱动） */
  private onPlayerState(state: string): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    if (state === 'initialized') {
      /* ★ surfaceId 只有 initialized 状态允许设置（提前设会报 5400102 ⇒ 有声无画） */
      if (this.surfaceId !== '') {
        p.surfaceId = this.surfaceId;
        Log.i('[Index] AVPlayer 已挂载 surface');
      } else {
        Log.w('[Index] surfaceId 尚未就绪，先 prepare（onLoad 后补挂）');
      }
      /* ★ 再显式设一次起播水线（setMediaSource 已带一份，这里双保险；仅 initialized 允许 ✓），
       *   并**等它生效后再 prepare**（prepare 之后就不能再改了） */
      const st2: media.PlaybackStrategy = {
        preferredBufferDurationForPlaying: 2,
        showFirstFrameOnPrepare: true
      };
      Log.i(`[Index] ▶ prepare 发起 at ${Date.now()}`);
      p.setPlaybackStrategy(st2)
        .catch((e: BusinessError) => {
          Log.w(`[Index] setPlaybackStrategy 失败（忽略，用 setMediaSource 那份）: ${e.message}`);
        })
        .then(() => {
          Log.i(`[Index] ▶ prepare 实际调用 at ${Date.now()}`);
          p.prepare().catch((e: BusinessError) => {
            Log.e(`[Index] prepare 失败: ${e.message}`);
            this.recoverPlayer(`prepare 失败: ${e.message}`);
          });
        });
    } else if (state === 'prepared') {
      /* ★ 2026-09-24：宽高比修正**在这里才切**（新画面即将上屏）—— 见 `videoArFix` 注释 */
      this.videoArFix = this.pendingArFix;
      /* ★ 画面缩放与音量都只能在 prepared 之后设置 */
      p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;   // 保持宽高比、不裁切
      /* ★ 音频打断模式：**SHARE_MODE（默认值，不独占）**——合规要求：不打断其它应用的音频。
       *   ⚠️ 只能在 prepared/playing/paused/completed 设置（提前设会报 5400102）。 */
      p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
      p.setVolume(this.muted ? 0 : this.volRatio);   // 音量大小时手势设定的 volRatio（0~1）
      p.play().catch((e: BusinessError) => { Log.e(`[Index] play 失败: ${e.message}`); });
    } else if (state === 'playing') {
      this.playing = true;
      this.playErr = false;
      /* ★ 2026-09-21：记下"真正出过画"的台 = 后续无信号时可回退的"原台"（见 revertToPlayingChannel） */
      this.lastPlayingId = this.activeChannelId;
      this.bootMsg = `${this.currentName} 播放中`;
      /* ★ 起播全链路耗时汇总 */
      const now: number = Date.now();
      Log.i(`[Index] ◀ AVPlayer 开始播放 at ${now}` +
        (this.tClickChannel > 0 ? `｜点击→出画 ${now - this.tClickChannel}ms` : '') +
        (this.tSetupStart > 0 ? `｜setup→出画 ${now - this.tSetupStart}ms` : ''));
      this.playerRebuilds = 0;   /* ★ 出画成功 ⇒ 重建计数归零（下次异常还能救） */
      this.resetNetResume();     /* ★ 出画成功 ⇒ 网络异常标记/续播轮询一并清零 */
      /* ★ 出画即开始 3 秒自动隐藏计时（原来必须等用户点一次暂停/静音/全屏才会挂计时器） */
      this.showControls();
      /* ★ 播放中禁止熄屏 + 播控卡片置为"播放中"（播控中心/锁屏可见） */
      this.applyKeepScreenOn(true);
      const tsPlay: TvSession | null = this.tvSession;
      if (tsPlay !== null) {
        tsPlay.setPlaying(true);
      }
    } else if (state === 'paused') {
      this.playing = false;
      this.applyKeepScreenOn(false);
      const tsPause: TvSession | null = this.tvSession;
      if (tsPause !== null) {
        tsPause.setPlaying(false);
      }
    } else if (state === 'completed') {
      /* ★★ 2026-11-09（逐条对齐安卓 `Player.STATE_ENDED` 的处理）★★
       *   · **整档回看**（带 endtime 的 VOD，有 `#EXT-X-ENDLIST`）⇒ 自动接下一档，没有就回直播；
       *   · **时移**（滚动窗口）如果真的结束 ⇒ **按"当前延迟"继续播**，绝不跳回直播
       *     （安卓注释原话："时移流播完 ⇒ 按当前位置继续（不跳直播）"；这正是用户上轮看到的 bug）。 */
      this.playing = false;
      if (this.replayStart <= 0) {
        // 直播流不会 completed；真走到这里说明源断了，交给看门狗
        return;
      }
      if (this.replayIsProgram) {
        Log.i(`[Index] 回看播放结束（playbacktime=${this.replayStart}）⇒ 自动接下一档`);
        this.autoNextReplay();
      } else {
        const ch: CctvChannel | undefined = Channels.find((c: CctvChannel) => c.id === this.activeChannelId);
        if (ch === undefined) {
          return;
        }
        const nowSec: number = Math.floor(Date.now() / 1000);
        const target: number = Math.min(nowSec - 2, nowSec - this.replayDelaySec);
        Log.i(`[Index] 时移流结束 ⇒ 按当前位置继续 playbacktime=${target}（延迟 ${this.replayDelaySec}s，不跳直播）`);
        this.playChannel(ch, false, target, 0, this.currentName);
      }
    } else if (state === 'error') {
      this.playErr = true;
      /* ★ 2026-09-21：这个台已进 error ⇒ 不再是"可回退的原台"（否则回退后会谎报"播放中"）。
       * ★★ 2026-09-23 修正：**只有"当前台自己就是原台"时才清空** ★★
       *   原实现无条件 `lastPlayingId = ''` ⇒ 从"正在播的 CCTV-5"切到一个无信号的 IPTV 台时，
       *   播放器一进 error 就把 CCTV-5 也抹掉了 ⇒ 后面 `fallbackToPlayingChannel` 无台可退，
       *   只能落到"播放器异常，无法自动恢复"（用户实测就是这个现象）。 */
      if (this.lastPlayingId === this.activeChannelId) {
        this.lastPlayingId = '';
      }
      this.applyKeepScreenOn(false);
      /* ★ 播放器进 error 态 ⇒ 尝试销毁重建（长后台/被系统回收后常见），而非只把状态标红 */
      this.recoverPlayer('state=error');
    }
  }

  /** ★ 应用屏幕亮度（0~1；退出全屏时恢复系统亮度 -1） */
  private applyBrightness(v: number): void {
    this.curBrightness = v;
    if (this.winObj === null) {
      return;   // 窗口还没取到：只记状态，取到后由后续手势生效
    }
    this.winObj.setWindowBrightness(v).catch((e: BusinessError) => {
      Log.w(`[Index] 设置亮度失败: ${e.message}`);
    });
  }

  // ---------------- UI ----------------
  @Builder
  statusBar() {
    Row({ space: 8 }) {
      /* ★ 状态灯：正常播放=绿；出错=红；未播放=灰。
       *   原来用 proxyOk 判断（本地代理一旦起来就恒为 true）⇒ 永远绿/红不分，看不出真实状态。
       * ★★★ 2026-09-19：**改用 `Image`(SVG) 取代 `Circle` 形状组件** ★★★
       *   华为上架自检命中《视频场景弹幕绘制低功耗规则》："视频画面上的叠加绘制走了 CPU 绘制通路"。
       *   规则要求这类图元用 **GPU 纹理（`Image` / `SymbolGlyph`）**，不要用 ArkUI 形状组件
       *   （`Circle` / `Polygon` / `Path` / `Shape` 一族）。`fillColor` 对 SVG 图源生效
       *   ⇒ 颜色仍随状态变（绿/红/灰），8×8 视觉与原来完全一致。 */
      Image($r('app.media.dot'))
        .width(8)
        .height(8)
        .fillColor(this.playErr ? '#ff3b3b' : (this.playing ? '#3ddc84' : '#888888'))
      Text(this.bootMsg)
        .fontSize(12)
        .fontColor('#888')
        /* ★ 一律 1 行（原来竖屏允许 2 行 ⇒ 长状态文案会把信息栏顶高、高度忽高忽低） */
        .maxLines(1)
        .textAlign(TextAlign.Start)        /* ★ 文案**左对齐**（不做水平居中） */
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)                   /* 占满"状态灯之后"的宽度，长文案尽量少省略 */
      /* ★★★ 2026-09-19：**信息栏"加载中"指示器已整体删除（用户要求）** ★★★
       *   演变：`LoadingProgress`（华为上架自检《视频场景弹幕绘制低功耗规则》指"弹幕绘制走了 CPU 绘制"，
       *   它是视频画面上唯一"持续动画/逐帧重绘"的叠加元素；本地 hitrace 实测确认它会带来逐帧 UI 活动）
       *   → 曾改为 `Image(spinner.png)` + `rotate` 属性动画（预生成纹理 + 变换合成）
       *   → **现在直接去掉**：切台/缓冲进度只用 `bootMsg` 文案（"正在获取播放地址…/正在缓冲…"）表达。
       *   ⚠️ **不要再往视频画面上加任何"逐帧动画"的叠加元素**（形状组件 / 自绘 / 旋转动画都算）。 */

    }
    .width(this.videoBoxW())   /* ★ 与画面同宽 ⇒ 与画面左右边缘对齐（用户要求："在正上方、宽度一致"） */
    /* ★★ 内容**垂直居中** ★★：状态灯 / 文案 都对齐到信息栏的**竖向中线**。
     *   配合下面的固定高度 ⇒ 不管文案多长，文字都稳稳在中间（不会贴顶）。 */
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Start)   /* ★ 水平方向仍从左侧开始（不做水平居中） */
    /* ★ 高度统一压缩：横屏 3、竖屏 5（原来竖屏 8 ⇒ 信息栏偏高，白占画面空间） */
    .padding({ left: 12, right: 12, top: this.isWide() ? 3 : 5, bottom: this.isWide() ? 3 : 5 })
    /* ★ 固定"最小高度"（横屏 22 / 竖屏 26）⇒ 栏高稳定，配合 alignItems(Center) 的垂直居中才看得出来 */
    .constraintSize({ minHeight: this.isWide() ? 22 : 26 })
    .backgroundColor('#101010')
  }

  @Builder
  playerArea() {
    Stack({ alignContent: Alignment.Bottom }) {
      /* ★★★ 原生播放层：XComponent(SURFACE) + media.AVPlayer ★★★
       *   换成自绘 surface 后：音量 = `AVPlayer.setVolume(0.0~1.0)`（手势/静音真正生效）、
       *   画面 = `videoScaleType = VIDEO_SCALE_TYPE_FIT`（保持宽高比、完整显示，不裁切）。
       *   （原来用 ArkUI `Video` 组件：虽是原生组件但不暴露 AVPlayer，只有 muted 没有 volume。） */
      XComponent({ id: 'palm_player', type: XComponentType.SURFACE, controller: this.xcController })
        /* ★ 按视频真实比例显示（不再用 100%/100% 撑满 ⇒ 那会被拉伸变形） */
        .width(this.videoBoxW())
        .height(this.videoBoxH())
        .margin({ bottom: this.videoBoxBottom() })   /* 垂直居中（Stack 为底对齐） */
        .backgroundColor('#000')
        .onLoad(() => {
          const sid: string = this.xcController.getXComponentSurfaceId();
          this.surfaceId = sid;
          Log.i(`[Index] XComponent surface 就绪: ${sid.substring(0, 24)}…`);
          const p: media.AVPlayer | null = this.avPlayer;
          if (p === null) {
            if (this.videoSrc !== '') {
              this.setupPlayer(this.videoSrc);   // 已有地址：起播
            }
          } else if (p.state === 'initialized') {
            /* ★ 只有 initialized 状态允许设 surfaceId（其它状态设置会报 5400102） */
            p.surfaceId = sid;
            Log.i('[Index] surfaceId 已补挂到 AVPlayer');
          }
        })
        /* ★ 单击：显示控制条（3 秒后自动隐藏）；锁屏时也能点出来（解锁入口） */
        .gesture(
          TapGesture({ fingers: 1, count: 1 })
            .onAction(() => { this.showControls(); })
        )
        /* ★ 上下滑（原版手势）：左半屏 = 亮度，右半屏 = 音量；锁屏时只弹控制条、不做调节 */
        .priorityGesture(
          PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
            .onActionStart(() => {
              if (this.screenLocked) {
                this.showControls();
                return;
              }
              this.gestureStartRatio = this.volRatio;    // 系统媒体音量比例 0~1
              this.gestureStartBri = this.curBrightness < 0 ? 0.5 : this.curBrightness;
              this.gestureActive = true;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.screenLocked) {
                this.showControls();
                return;
              }
              if (!this.gestureActive) {
                return;
              }
              const step: number = -event.offsetY / 300;   // 上滑为正（offsetY 向下为正）
              const fx: number = (event.fingerList !== undefined && event.fingerList.length > 0)
                ? event.fingerList[0].localX : 0;
              if (fx > this.videoZoneWidth / 2) {
                const r: number = Math.max(0, Math.min(1, this.gestureStartRatio + step));
                const snap: number = Math.round(r * 20) / 20;   // 5% 一档，与原版一致
                this.setPlayerVolumeByRatio(snap);
                this.gestureHint = `音量 ${Math.round(snap * 100)}%`;
              } else {
                const b: number = Math.max(0, Math.min(1, this.gestureStartBri + step));
                this.applyBrightness(b);
                this.gestureHint = `亮度 ${Math.round(b * 100)}%`;
              }
            })
            .onActionEnd(() => {
              this.gestureActive = false;
              const h: string = this.gestureHint;
              setTimeout(() => {
                if (this.gestureHint === h) {
                  this.gestureHint = '';
                }
              }, 800);
            })
        )
        /* ★★★ 2026-11-09（用户要求，对齐安卓）：**左右滑动 = 时移 ±10 秒** ★★★
         *   与上面的竖滑挂在**两个 priorityGesture** 上 —— ArkUI 按"主方向"仲裁，互不干扰。
         *   约定与主流播放器一致：**右滑 = 前进、左滑 = 后退**；每 40vp ≈ 10 秒（≈ 安卓 120px 的比例）。
         *   滑动期间只更新待结算目标 + OSD（"时移 -30 秒"），**抬手才真正取流**（`applyShift`）。 */
        .priorityGesture(
          PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.shiftPendingSec = 0;
              this.shiftSteps = 0;
              this.shiftAccumSec = 0;   /* ★ 每次手势重新累计（OSD 的"落后秒数"基准） */
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.screenLocked) {
                return;
              }
              /* offsetX = 相对手势起点的累计位移（vp） */
              const steps: number = Math.trunc(event.offsetX / 40);
              while (this.shiftSteps < steps) {
                this.shiftSteps++;
                this.shiftBy(10);
              }
              while (this.shiftSteps > steps) {
                this.shiftSteps--;
                this.shiftBy(-10);
              }
            })
            .onActionEnd(() => {
              this.applyShift();
              const h: string = this.gestureHint;
              setTimeout(() => {
                if (this.gestureHint === h) {
                  this.gestureHint = '';
                }
              }, 800);
            })
        )

      /* ★★★ 播放控制条：改用**原版图片资源**（原来用文字符号）★★★
       *   资源来自原鸿蒙版并已复制到本工程 entry/src/main/resources/base/media/：
       *     plyay.png / pause.png（播放·暂停）  player_sound_off.png / player_sound_on.png（静音·有声）
       *     fullscreen.png / window.png（全屏·退出）  locked.png / unlock.png（锁屏·解锁）
       *   ⚠️ 原版是 WebView 走 evalJs('window.__togglePause')；现在原生 AVPlayer，
       *      暂停/播放改用 VideoController.start()/pause()、静音用 Video.muted 属性。 */
      if (this.controlsVisible && !this.screenLocked) {
        Row({ space: 16 }) {
          Image(this.playing ? $r('app.media.pause') : $r('app.media.plyay'))
            .width(44).height(44).objectFit(ImageFit.Contain)
            .onClick(() => {
              const p: media.AVPlayer | null = this.avPlayer;
              if (p !== null) {
                if (this.playing) {
                  p.pause().catch((e: BusinessError) => { Log.w(`[Index] pause 失败: ${e.message}`); });
                  this.playing = false;
                  this.pausedByInterrupt = false;   /* 用户主动暂停 ⇒ 打断结束后不再自动恢复 */
                } else {
                  p.play().catch((e: BusinessError) => { Log.w(`[Index] play 失败: ${e.message}`); });
                  this.playing = true;
                }
              }
              this.showControls();
            })
          Blank()   /* ★ 按用户要求：不再显示频道名，也不要"停止"按钮（占位把音量/全屏推到右侧） */
          /* ★ 静音按钮移到**右侧**（与全屏同侧，用户要求）：原来在播放键旁边、偏左不好按 */
          Image(this.muted ? $r('app.media.player_sound_off') : $r('app.media.player_sound_on'))
            .width(36).height(36).objectFit(ImageFit.Contain)
            .onClick(() => {
              this.muted = !this.muted;
              this.applyVolume();   // ★ 静音 = AVPlayer.setVolume(0)；取消静音恢复 1（大小由系统音量决定）
              this.showControls();
            })
          Image(this.isFullscreen ? $r('app.media.window') : $r('app.media.fullscreen'))
            .width(44).height(44).objectFit(ImageFit.Contain)
            .onClick(() => {
              this.toggleFullscreen();
              this.showControls();
            })
        }
        .width('100%')
        /* ★ 全屏时两侧边距加大（原来左右各 10vp，太靠屏边不好点；用户要求） */
        .padding({
          left: this.isFullscreen ? 40 : 10,
          right: this.isFullscreen ? 40 : 10,
          top: this.isFullscreen ? 8 : 2,
          bottom: this.isFullscreen ? 8 : 2
        })
        .backgroundColor('#00000088')
      }

      /* ★ 全屏锁屏按钮（只在全屏显示；锁上后控制条与手势都禁用）
       *   位置：**左侧、竖直居中**（原来在左上角） */
      if (this.isFullscreen && this.controlsVisible) {
        Image(this.screenLocked ? $r('app.media.locked') : $r('app.media.unlock'))
          .width(28).height(28).objectFit(ImageFit.Contain)
          /* ★ 左边距与控制条一致（全屏 40vp，原来 12vp 太靠边；用户要求同步） */
          .position({ x: this.isFullscreen ? 40 : 12, y: '50%' })
          .translate({ y: '-50%' })
          .onClick(() => {
            this.screenLocked = !this.screenLocked;
            Log.i(`[Index] ${this.screenLocked ? '已锁屏（仅左上角可解锁）' : '已解锁'}`);
            setTimeout(() => { this.showControls(); }, 0);
          })
      }

      /* ★ 手势提示（音量/亮度百分比） */
      if (this.gestureHint !== '') {
        Text(this.gestureHint)
          .fontSize(13)
          .fontColor('#ffffff')
          .backgroundColor('#99000000')
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .position({ x: '50%', y: '25%' })
          .translate({ x: '-50%' })
          .hitTestBehavior(HitTestMode.None)
      }

      /* ★ 未选择频道时的中央提示
       * ★ 2026-10-01：文案去掉"下方" —— 横屏分栏时频道列表在**右侧**（竖屏才在下方）⇒ 用中性说法。
       *   ⚠️ 三端同步：Android `ui/Strings.kt` 的 `PICK_CHANNEL` 已同步改（桌面端没有这句空态提示）。 */
      if (this.videoSrc === '' && this.videoNotice === '') {
        Column() {
          Text('请选择频道开始观看')
            .fontSize(13)
            .fontColor('#888888')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }

      /* ★ 无流/暂停提供信号提示（原版风格：视频区中央浮层，不拦截触摸，**2 秒自消**） */
      if (this.videoNotice !== '') {
        Column() {
          Text(this.videoNotice)
            .fontSize(14)
            .fontColor('#dddddd')
            .backgroundColor('#b0000000')
            .borderRadius(12)
            .padding({ left: 20, right: 20, top: 14, bottom: 14 })
            .textAlign(TextAlign.Center)
            .margin({ left: 16, right: 16 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    /* ★★ 高度改回"布局权重"驱动：横屏/全屏 = layoutWeight(1) 吃掉剩余空间，竖屏 = 固定 210vp。
     *   这样"信息栏 + 画面 + 节目条"总高**永远等于**容器高 ⇒ 不可能再把节目条挤出屏外。
     *   （前两轮用"推算高度"都失败，根因是推算不准系统栏/栏目实际高度；
     *     而权重由布局引擎自己分配，天然不会溢出。） */
    .layoutWeight(this.isWide() || this.isFullscreen ? 1 : 0)
    .height(this.isWide() || this.isFullscreen ? '100%' : 210)
    /* ★ 实测视频区尺寸（供按比例计算画面大小；比按窗口推算准）。
     *   注意：这两个字段是 @State ⇒ 量到新值会重建画面（旋转/进全屏后画面尺寸才跟着变）；
     *   且只在"真的变了"时赋值，避免 重建→量测→重建 的循环。 */
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const zw: number = Number(newArea.width);
      const zh: number = Number(newArea.height);
      if (Math.abs(zw - this.videoZoneWidth) > 0.5) {
        this.videoZoneWidth = zw;
      }
      if (Math.abs(zh - this.videoZoneHeight) > 0.5) {
        this.videoZoneHeight = zh;
      }
    })
    .backgroundColor('#000')
  }

  @Builder
  channelIconItem(ch: CctvChannel) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.iconMap[ch.id] !== undefined) {
        Image(this.iconMap[ch.id])
          .width('100%')
          .height('100%')
          /* ★ Contain（原为 Cover）：Cover 会把方形台标裁掉一圈，这就是"台标显示不全"的原因 */
          .objectFit(ImageFit.Contain)
      } else {
        /* ★★ 2026-10-02（用户："自定义频道在本地生成文本台标后，要显示全部频道名，而不是现在的一个"）★★
         *   文字台标改**完整频道名**，字号按"圆内可用宽 ≈ 0.85×图标径"反推（三端同一套数，见
         *   安卓 `ChannelTile` 与桌面 `ChannelTile.FallbackFontSize`）：
         *     n ≤ 4 ⇒ 单行，字号 = min(0.85/n, 0.30) × 图标径；
         *     n ≥ 5 ⇒ 两行（每行 ⌈n/2⌉ 字），字号 = min(0.85/⌈n/2⌉, 0.22) × 图标径；最多 2 行、超出省略。
         *   “0.85”是圆内留了边距的可用弦长 ⇒ 将来改图标尺寸不用动这里（全部按比例）。 */
        Text(ch.name)
          .fontSize(this.tileFontSize(ch.name))
          .fontColor('#333333')
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .maxLines(ch.name.length > 4 ? 2 : 1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.iconSize * 0.86)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .borderRadius(this.iconSize / 2)
    .backgroundColor('#ffffff')
    .clip(true)
    .border({
      width: 2,
      color: this.activeChannelId === ch.id ? '#ff3b3b' : '#3a3a3a'
    })
    .onClick(() => {
      /* ★ 用户主动选台 ⇒ 续播计数归零（给这次操作完整的重试额度） */
      this.resetNetResume();
      this.playChannel(ch);
    })
  }

  /** 无台标时，圈内**完整频道名**的字号 —— 依据"圆内可用宽 ≈ 0.85×图标径"反推。
   *  ⚠️ 与安卓 `ChannelTile`、桌面 `ChannelTile.FallbackFontSize` 是**同一套数**，改一处要三端一起改。 */
  private tileFontSize(name: string): number {
    const n: number = name.length;
    const per: number = n <= 4 ? Math.max(n, 1) : Math.ceil(n / 2);   // 每行字数
    const cap: number = n <= 4 ? 0.30 : 0.22;                         // 单行/两行的字号上限
    return Math.min(0.85 / per, cap) * this.iconSize;
  }

  /** 当前分组在 Tab 里的下标（0/1/2），供滑块位移用。
   *  ⚠️ 名字不能叫 `tabIndex`：与 ArkUI `CustomComponent` 自带属性同名会被拒编（同 brightness 那类坑）。 */
  private tabIdx(): number {
    return this.currentTab === TAB_CCTV ? 0 : (this.currentTab === TAB_SAT ? 1 : 2);
  }

  /** 滑块下标（0~3）：三个频道分组 + 「关于」（= 3） */
  private tabSelIdx(): number {
    return this.aboutTab ? 3 : this.tabIdx();
  }

  /** ★ 切到「关于」页：只切 UI，不动播放（当前频道继续播） */
  private switchAbout(): void {
    if (this.aboutTab) {
      return;
    }
    this.aboutTab = true;
    Log.i('[Index] 切到「关于」页');
  }

  /** ★ 分组 Tab 文字层（无底色，滑块在 Stack 底层） */
  @Builder
  tabItem(label: string, tab: ChannelGroup) {
    Text(label)
      .fontSize(this.currentTab === tab ? 15 : 14)
      .fontWeight(this.currentTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.currentTab === tab ? '#ffffff' : '#a8a8a8')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .onClick(() => { this.switchTab(tab); })
  }

  /** ★ 第 4 个 Tab「关于」的文字层（样式与 tabItem 完全一致，仅点击行为不同） */
  @Builder
  tabAboutItem() {
    Text('关于')
      .fontSize(this.aboutTab ? 15 : 14)
      .fontWeight(this.aboutTab ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.aboutTab ? '#ffffff' : '#a8a8a8')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .onClick(() => { this.switchAbout(); })
  }

  @Builder
  channelTabsAndList() {
    /* ★ 苹果式分段控件：灰轨道 + 白色滑块（220ms 滑动） */
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(this.tabBarW > 0 ? this.tabBarW / 4 : 0)
        .height(34)
        .backgroundColor('#2f6bff')
        .borderRadius(8)
        .position({ x: 3 + this.tabSelIdx() * (this.tabBarW / 4), y: 3 })
        .animation({ duration: 220, curve: Curve.EaseInOut })
      Row() {
        this.tabItem('央视', TAB_CCTV);
        this.tabItem('卫视', TAB_SAT);
        this.tabItem('地方', TAB_LOCAL);
        this.tabAboutItem();
      }
      .width('100%')
      .height(40)
      .padding({ left: 3, right: 3 })
    }
    .width('100%')          /* ★ 用户要求：4 个 Tab 后铺满整行 */
    .height(40)
    .backgroundColor('#262626')
    .borderRadius(11)
    .onAreaChange((_old: Area, now: Area) => {
      const w: number = Number(now.width) - 6;
      if (w > 0 && Math.abs(w - this.tabBarW) > 0.5) {
        this.tabBarW = w;
      }
    })
    .margin({ top: 6, bottom: 4 })

    if (this.aboutTab) {
      this.aboutView();
    } else if (this.list.length === 0) {
      Text('该分组暂无频道')
        .fontSize(11)
        .fontColor('#666')
        .padding(12)
    } else {
      /* ★ 改用 Grid（原来 Scroll+Flex 在真机上会被"居中"）：
       *   Grid 的布局是确定的——从**左上角**开始逐行排布，1fr×5 列自动等分宽度，
       *   行数按内容增长、超出才滚动 ⇒ 靠上、留白在下方，与分辨率无关。 */
      Grid() {
        ForEach(this.list, (ch: CctvChannel) => {
          GridItem() {
            this.channelIconItem(ch);
          }
          .padding({ top: 3, bottom: 3 })   /* 上下留白收窄（原来 6 偏大） */
        }, (ch: CctvChannel) => ch.id)
      }
      /* ★ 横屏右侧栏窄 ⇒ 用 3 列；竖屏 5 列（否则 5 列挤在一起放不下） */
      .columnsTemplate(this.isWide() ? '1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr')
      .columnsGap(0)
      .rowsGap(0)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  epgStrip() {
    /* ★ 结构改成「左侧两行文字 + 右侧节目单按钮」：
     *   原来「节目单」放在第一行里 ⇒ 看起来"只对齐第一行中间"；现在它相对**两行整体竖直居中**。 */
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(this.replayStart > 0 ? '回看中' : '正在播出')
            .fontSize(12)
            .fontColor(this.replayStart > 0 ? '#2f6bff' : '#ff4444')
          Text(this.episodeNow)
            .fontSize(13)
            .fontColor('#e0e0e0')
            .fontWeight(FontWeight.Bold)   /* ★ 正在播出的节目用粗体（用户要求） */
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        /* ★ 横屏（分栏）只显示"正在播出"一行：横向空间紧张，且用户明确要求横屏不要"接下来" */
        if (!this.isWide()) {
        Row({ space: 4 }) {
          Text('接下来')
            .fontSize(12)
            .fontColor('#3ddc84')           /* ★ 绿色（与原版一致） */
          /* ★★★ 2026-09-19：右三角改成 **`Image`(SVG) 图源** ★★★
           *   演变史：字符 `'▶'`（被系统按彩色 emoji 渲染、出不来绿色）→ `Polygon` 形状组件（能上色，
           *   但**属 CPU 自绘通路**，被华为功耗审核《视频场景弹幕绘制低功耗规则》判为"弹幕绘制用了 CPU"）。
           *   ⇒ 改用 SVG 图源 + `Image`（GPU 纹理合成，规则推荐的写法），`fillColor` 上绿色，
           *     8×8 尺寸与位置不变，视觉与之前完全一致。 */
          Image($r('app.media.tri_right'))
            .width(8)
            .height(8)
            .fillColor('#3ddc84')
          Text(this.episodeNext)
            .fontSize(12)
            .fontColor('#888888')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        }   /* end if (!this.isWide()) */
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      /* ★★ 2026-11-09（用户要求，与安卓对齐）：**时移只用手势**，节目条上不再放 ±10 秒按钮。
       *   手势 = 视频区左右滑动（右滑前进 / 左滑后退，每 40vp ≈ 10 秒），见 `PanGesture(Horizontal)`。
       *   这里只保留「返回直播」这个出口。 */
      if (this.replayStart > 0) {
        Text('返回直播')
          .fontSize(12)
          .fontColor('#3ddc84')
          .onClick(() => { this.backToLive(); })
      }
      Text('节目单 ☰')                       /* ★ 尾部三横字符（原版同款） */
        .fontSize(12)
        .fontColor('#2f6bff')
        .onClick(() => {
          this.openEpg();   // ★ 打开弹层（默认落在回看那天/今天，并把"正在播出"定位到中间）
        })
    }
    .width(this.videoBoxW())   /* ★ 与画面同宽 ⇒ 与画面左右边缘对齐（用户要求） */
    .alignItems(VerticalAlign.Center)       /* ★ 右侧按钮相对两行竖直居中 */
    /* ★ 横屏压缩高度（10 → 5）：节目条横屏只有一行，不需要那么高 */
    .padding({ left: 10, right: 10, top: this.isWide() ? 5 : 10, bottom: this.isWide() ? 5 : 10 })
    .backgroundColor('#181818')
    .borderRadius(8)
  }

  /** ★ 小节标题（关于页用） */
  @Builder
  aboutTitle(t: string) {
    Text(t)
      .fontSize(12)
      .fontColor('#2f6bff')
      .width('100%')
      .margin({ top: 6 })
  }

  /** ★★ 2026-09-24：第 4 个 Tab「关于」页（占满中间区域；**不影响正在播放的频道**） */
  @Builder
  aboutView() {
    Scroll() {
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          /* ★★ 2026-10-02（用户要求：三端一致）★★ 品牌区左侧改成**应用图标**（原来是版权图标）。
           *   应用图标 = 仓库根 `app_icon.png` 转出的 `app.media.app_icon`（192×192）；
           *   版权图标改到「版权人：飘渺峰」那一行后面（16dp 圆角矩形），与安卓/桌面同位置同尺寸。 */
          Image($r('app.media.app_icon'))
            .width(48)
            .height(48)
            .borderRadius(10)
            .interpolation(ImageInterpolation.High)
          Column({ space: 3 }) {
            Text('掌上电视').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#ffffff')
            Text(`版本 ${this.appVersion}`).fontSize(12).fontColor('#8a8a8a')
            Text('鸿蒙版 · com.RickyOne.PalmTV').fontSize(11).fontColor('#666666')
            /* ★ 2026-10-02（用户要求：三端一致）：版权图标放到「版权人」文字**之后**，
             *   16dp、**圆角矩形**（不要圆形），与安卓/桌面一致。 */
            Row({ space: 5 }) {
              Text('版权人：飘渺峰').fontSize(11).fontColor('#666666')
              Image($r('app.media.copyright'))
                .width(16)
                .height(16)
                .borderRadius(4)
                .clip(true)
                .interpolation(ImageInterpolation.High)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        this.aboutTitle('技术说明');
        Text('· 客户端：ArkTS（界面与取流编排）\n' +
          '· 播放器：系统 AVPlayer（Surface 原生渲染）\n' +
          '· 数据来源：各电视台/内容方公开发布的直播地址')
          .fontSize(12)
          .fontColor('#bbbbbb')
          .textAlign(TextAlign.Start)
          .width('100%')
        /* ★★ 2026-10-02（用户要求：与桌面端**同位置**）★★
         *   「自定义 IPTV 源」是**技术说明的第 4 条**，行内跟「添加 / 编辑」按钮 ——
         *   桌面端 `MainWindow.xaml` 就是这个结构（`· 支持自定义 IPTV 源` + 按钮）。 */
        Row({ space: 8 }) {
          Text('· 支持自定义 IPTV 源').fontSize(12).fontColor('#bbbbbb')
          Text('添加 / 编辑')
            .fontSize(11)
            .fontColor('#ffffff')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(6)
            .backgroundColor('#2f6bff')
            .onClick(() => { this.openIptvEditor(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        /* 对应桌面端挂在按钮 ToolTip 上的信息（手机/鸿蒙没 ToolTip，直接显示一行小字） */
        Text(`已载入 ${this.iptvLocalCount()} 个地方台（自定义 ${this.iptvUserCount()} 条）`)
          .fontSize(11)
          .fontColor('#8a8a8a')
          .width('100%')

        this.aboutTitle('账号与登录');
        /* ★ 2026-10-02（用户要求：两个登录按钮**并排等大**）：原来只按内容宽度排 ⇒
         *   各加 `.layoutWeight(1)` + 文字居中 ⇒ 两个按钮等宽等高的两栏（与安卓 `weight(1f)` 同口径）。 */
        Row({ space: 10 }) {
          Text('微信登录')
            .fontSize(13)
            .fontColor('#ffffff')
            .backgroundColor('#07c160')
            .borderRadius(18)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => { this.notImplemented('微信登录'); })
          Text('华为账号登录')
            .fontSize(13)
            .fontColor('#ffffff')
            .backgroundColor('#cf0a2c')
            .borderRadius(18)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => { this.notImplemented('华为账号登录'); })
        }
        .width('100%')
        Text('· 登录用于跨设备同步「收藏」与偏好；未登录也可正常观看\n' +
          '· 收藏、登录同步将在后续版本提供')
          .fontSize(11)
          .fontColor('#8a8a8a')
          .textAlign(TextAlign.Start)
          .width('100%')

        this.aboutTitle('内容来源与免责');
        Text('查看完整声明 >')
          .fontSize(12)
          .fontColor('#2f6bff')
          .padding({ top: 2, bottom: 2 })
          /* ★ 2026-09-29：**再次查看** ⇒ 置 readOnly：弹窗里不再出现"不同意并退出"（见 disclaimerModal） */
          .onClick(() => { this.disclaimerReadOnly = true; this.showDisclaimer = true; })

        this.aboutTitle('举报 / 联系');
        Text(CONTACT_EMAIL)
          .fontSize(13)
          .fontColor('#8ab4ff')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  // ==================================================================
  // ★★ 2026-10-02：自定义 IPTV 源（与桌面端 `IptvSourceWindow` 同交互、同规则、同文件）
  // ==================================================================

  /** 读文件 → 并入频道表 → 刷新当前分组列表。
   *  （启动时调一次；保存后也调它 ⇒ "保存后立即生效、无需重启"，与桌面 `ReloadIptvChannels()` 同语义） */
  private reloadCustomIptv(): void {
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    if (ctx === undefined) {
      Log.w('[iptv] 拿不到 UIAbilityContext ⇒ 跳过自定义源载入');
      return;
    }
    const entries: IptvEntry[] = iptvLoadFile(ctx);
    const n: number = mergeIntoChannels(entries);
    this.list = channelsByGroup(this.currentTab);   // 追加/移除用户台后刷新（与 switchTab 里同一句）
    Log.i(`[iptv] 自定义源：文件 ${entries.length} 条 ⇒ 并表 ${n} 条（内置优先去重）｜${iptvFilePath(ctx)}`);
  }

  /** 地方台总数（关于页"已载入 N 个地方台"） */
  private iptvLocalCount(): number {
    return Channels.filter((c: CctvChannel) => c.group === 'local').length;
  }

  /** 已并表的自定义条数（与桌面 `LastUserCount` 同口径） */
  private iptvUserCount(): number {
    return userChannelCount();
  }

  /** 打开编辑窗（每次都从文件重读，保证与磁盘一致） */
  private openIptvEditor(): void {
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    this.iptvRows = ctx === undefined ? [] : iptvLoadFile(ctx);
    this.iptvSel = -1;
    this.iptvName = '';
    this.iptvUrl = '';
    this.iptvErr = '';
    this.iptvHint = '';
    this.iptvImportText = '';
    this.iptvShowImport = false;
    this.showIptv = true;
  }

  /** 校验两个输入框（桌面 `Validate()`）；通过返回条目，否则把错误写进 iptvErr 并返回 undefined */
  private readIptvInputs(): IptvEntry | undefined {
    const url: string = this.iptvUrl.trim();
    const bad: string | null = iptvValidate(url);
    if (bad !== null) {
      this.iptvErr = bad;
      return undefined;
    }
    return { name: iptvNameOrHost(iptvStripQuality(this.iptvName), url), url: url } as IptvEntry;
  }

  private iptvAdd(): void {
    const e: IptvEntry | undefined = this.readIptvInputs();
    if (e === undefined) {
      return;
    }
    const key: string = e.url.toLowerCase();
    for (let i = 0; i < this.iptvRows.length; i++) {
      if (this.iptvRows[i].url.toLowerCase() === key) {
        this.iptvErr = '该地址已在列表里。';
        return;
      }
    }
    const next: IptvEntry[] = this.iptvRows.slice();
    next.push(e);
    this.iptvRows = next;
    this.iptvSel = next.length - 1;
    this.iptvName = '';
    this.iptvUrl = '';
    this.iptvErr = '';
    /* ★ 2026-10-02（用户："操作后要马上更新列表，让用户知道"）：操作成功给一句回执。
       ⚠️ 鸿蒙侧列表本来就是**整表替换**（`this.iptvRows = next`）+ ForEach 键里含 url ⇒ 当场刷新；
          这里补的是"用户看得见"的那一半（与安卓 `hint` 同口径）。 */
    this.iptvHint = `✓ 已添加第 ${next.length} 条：${e.name}（共 ${next.length} 条，未保存）`;
  }

  private iptvUpdate(): void {
    if (this.iptvSel < 0 || this.iptvSel >= this.iptvRows.length) {
      this.iptvErr = '请先在列表里选中要修改的那条。';
      return;
    }
    const e: IptvEntry | undefined = this.readIptvInputs();
    if (e === undefined) {
      return;
    }
    const key: string = e.url.toLowerCase();
    for (let i = 0; i < this.iptvRows.length; i++) {
      if (i !== this.iptvSel && this.iptvRows[i].url.toLowerCase() === key) {
        this.iptvErr = '该地址已在列表里。';
        return;
      }
    }
    const next: IptvEntry[] = this.iptvRows.slice();
    next[this.iptvSel] = e;
    this.iptvRows = next;
    this.iptvErr = '';
    this.iptvHint = `✓ 已更新第 ${this.iptvSel + 1} 条：${e.name}（共 ${next.length} 条，未保存）`;
  }

  private iptvRemove(): void {
    if (this.iptvSel < 0 || this.iptvSel >= this.iptvRows.length) {
      this.iptvErr = '请先在列表里选中要删除的那条。';
      return;
    }
    const no: number = this.iptvSel + 1;
    const who: string = this.iptvRows[this.iptvSel].name.length > 0
      ? this.iptvRows[this.iptvSel].name : '(未命名)';
    const next: IptvEntry[] = this.iptvRows.slice();
    next.splice(this.iptvSel, 1);
    this.iptvRows = next;
    this.iptvSel = -1;
    this.iptvName = '';
    this.iptvUrl = '';
    this.iptvErr = '';
    this.iptvHint = `✓ 已删除第 ${no} 条：${who}（剩 ${next.length} 条，未保存）`;
  }

  /** 粘贴 m3u 文本导入（手机/鸿蒙特有：桌面端是让你用记事本改文件） */
  private iptvImport(): void {
    const parsed: IptvEntry[] = parseM3u(this.iptvImportText);
    if (parsed.length === 0) {
      this.iptvErr = '没解析到条目（需要 #EXTINF:-1,频道名 与地址各占一行）';
      return;
    }
    const next: IptvEntry[] = this.iptvRows.slice();
    for (let i = 0; i < parsed.length; i++) {
      let dup: boolean = false;
      for (let j = 0; j < next.length; j++) {
        if (next[j].url.toLowerCase() === parsed[i].url.toLowerCase()) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        next.push(parsed[i]);
      }
    }
    this.iptvRows = next;
    this.iptvImportText = '';
    this.iptvShowImport = false;
    this.iptvErr = '';
    this.iptvHint = `已导入 ${parsed.length} 条`;
  }

  /** 保存并生效（写 m3u 文件 → 立即并入频道表，不重启） */
  private iptvSave(): void {
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    if (ctx === undefined) {
      this.iptvErr = '无法获取应用上下文';
      return;
    }
    const count: number = this.iptvRows.length;
    if (!iptvSaveFile(ctx, this.iptvRows)) {
      this.iptvErr = `保存失败（目录不可写？）：${iptvFilePath(ctx)}`;
      return;
    }
    this.reloadCustomIptv();
    this.showIptv = false;
    this.showVideoNotice(`已保存自定义 IPTV 源（自定义 ${count} 条）`);
    Log.i(`[iptv] 自定义源已保存：${count} 条`);
  }

  /** 编辑窗里的小按钮 —— **按职责分三档配色**（2026-10-02 用户反馈"几个按钮不要全是蓝色背景啊，
   *  要专业点以示区分"）。kind 用普通字符串（避开 ArkTS 字面量联合类型的写法风险）：
   *    · 'primary' 实心蓝 + 蓝描边 + 白字  = **主操作**（同屏尽量只出现一个）：添加到列表 / 保存并生效 / 导入到列表
   *    · 'ghost'   透明 + 灰描边 + 浅灰字  = 次要操作：更新选中 / 取消 / 关闭
   *    · 'danger'  透明 + 暗红描边 + 红字  = 破坏性操作：删除选中
   *  与安卓 `DlgBtn(kind)` 同分层（三端观感一致）。 */
  @Builder
  iptvBtn(label: string, cb: () => void, kind: string) {
    Text(label)
      .fontSize(12)
      .fontColor(kind === 'primary' ? '#ffffff' : (kind === 'danger' ? '#ff6b6b' : '#cfcfcf'))
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(6)
      .backgroundColor(kind === 'primary' ? '#2f6bff' : '#00000000')
      .border({
        width: 1,
        color: kind === 'primary' ? '#2f6bff' : (kind === 'danger' ? '#5c2a2a' : '#3a3a3a')
      })
      .onClick(() => { cb(); })
  }

  /** 自定义 IPTV 源编辑窗 —— 结构照桌面端 `IptvSourceWindow.xaml`：
   *  说明 → 列表 → 频道名/播放地址 → 添加到列表/更新选中/删除选中 → 取消/保存并生效 → 灰字提示。
   *
   * ★★ 2026-10-02（用户实测：**横屏窗口**里鸿蒙端最下面的「取消 / 保存并生效」完全看不见，
   *   而且整个窗体不能滑动 ⇒ 根本没法操作；安卓端因"底栏钉住 + 中段可滚"只是稍挤，桌面端无影响）★★
   *   根因：原来弹窗**只有 `width('90%')`、高度无上限** ⇒ 内容多高它多高，矮窗口（横屏）里必然顶出屏幕，
   *        底部按钮被挤到屏幕外，而且**没有任何一处可以滚动**。
   *   修法与安卓弹窗**同结构**（那边用户反馈可用）：
   *     ① 弹窗整体给**确定高度** `.height('92%')` ⇒ 它永远在屏幕内；
   *     ② **中段（输入 + 三个操作 + 导入 + 提示）包一层 `Scroll` 并 `layoutWeight(1)`**
   *        ⇒ 窗口矮时**中段自己滚**，而底部「取消 / 保存并生效」**钉在弹窗底部**，永远可见可点 ✓；
   *     ③ 频道列表在**横屏**时收窄到 90vp（竖屏 140vp）⇒ 把高度让给输入区（列表是"看"的，输入区是"填"的）。
   *   ⚠️ 三端口径：桌面是独立窗口（MinHeight 460）不受影响；安卓 `IptvEditorDialog` 同结构同高度策略。 */
  @Builder
  iptvModal() {
    Column({ space: 8 }) {
      /* ★★ 2026-10-02 三次修正（用户实测：**竖屏**下弹窗"有点拉夸、不紧凑" —— 上一版固定 92% 高，
       *   内容只有 ~520vp，下面白白空一大块）★★
       *   现在高度策略 = **内容自适应 + 上限兜底**（见弹窗末尾的 `.constraintSize` 与中段的 `maxHeight`）：
       *     · 竖屏：按内容高度 ⇒ 紧凑 ✓；
       *     · 横屏：矮窗口 ⇒ 由中段 `maxHeight` 上限兜住，超出部分让**中段自己滚**，底栏钉住不动 ✓
       *       （横屏已被用户确认 OK，不许退化）。
       *   横屏时**整段隐藏说明文字**：横屏高度极紧张，这句只是引导语 ⇒ 省下的 ~40vp 全给输入区。 */
      Text('自定义 IPTV 源').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#ffffff')
        .flexShrink(0)
      if (!this.isWide()) {
        Text('填写电视台/运营方公开发布的直播直链（.m3u8 或 .ts）。支持多路，保存后立即生效、无需重启。')
          .fontSize(11)
          .fontColor('#bbbbbb')
          .textAlign(TextAlign.Start)
          .width('100%')
          .flexShrink(0)
      }

      /* 列表：点一条即选中 + 回填输入框（桌面 `SourceList` + `SelectionChanged` 同款）
       * ★ 横屏窗口矮 ⇒ 列表降到 90vp（竖屏仍 140vp），把高度让给下面的输入区 */
      List({ space: 0 }) {
        ForEach(this.iptvRows, (e: IptvEntry, i: number) => {
          ListItem() {
            Text(`${i + 1}. ${e.name.length > 0 ? e.name : '(未命名)'}    ${e.url}`)
              .fontSize(11)
              .fontColor(this.iptvSel === i ? '#ffffff' : '#bbbbbb')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 6, right: 6, top: 7, bottom: 7 })
              .borderRadius(4)
              .backgroundColor(this.iptvSel === i ? '#2f6bff' : '#00000000')
              .onClick(() => {
                this.iptvSel = i;
                this.iptvName = e.name;
                this.iptvUrl = e.url;
                this.iptvErr = '';
                this.iptvHint = '';
              })
          }
        /* ⚠️ 键里**必须带 `name`**（2026-10-02 用户实测："只有鸿蒙端点更新不会立即在表格中体现"）：
         *   ArkUI 的 `ForEach` 按 key 做 diff —— **key 不变就复用旧组件、不再执行 item 构建函数**
         *   ⇒ 只改名字（地址没变）时，列表文本会停在旧值 ✗（点「更新选中」看着像没生效）。
         *   把 `name` 放进 key 后：改名 ⇒ key 变 ⇒ 重建该项 ⇒ **当场刷新** ✓。
         *   另：增/删/导入本来就刷新（新增项的 key 是新的；删除会让后面各项下标位移）——
         *   这正好解释了"只有『更新』这一个操作出问题"。 */
        }, (e: IptvEntry, i: number) => `${i}-${e.name}-${e.url}`)
      }
      .height(this.isWide() ? 90 : 140)
      .width('100%')
      .scrollBar(BarState.Auto)
      .backgroundColor('#0a0a0a')
      .borderRadius(6)
      .padding(4)
      .flexShrink(0)      /* 列表高度不让步（矮窗口靠中段让步） */

      /* ★★ 中段：输入 + 操作 + 导入 + 提示 —— **独立滚动 + 吃掉剩余高度** ★★
       *   ⚠️ 这是"矮窗口（横屏）也能操作"的关键：它自己滚，底栏那两个按钮留在原地不动。 */
      Scroll() {
        Column({ space: 8 }) {
          /* 输入区（桌面 `NameBox` / `UrlBox`）——
           * ★ 2026-10-02（用户要求"输入框里的文字调小、与「频道名」标签文字大小一致"）：
           *   ① 标签**固定 52vp 宽** ⇒ 两行输入框左边界对齐（原来两个标签宽度不同 ⇒ 输入框左右错开，看着不齐）；
           *   ② `.fontSize(12)` 与标签**同为 12**；
           *   ③ ⚠️ 关键：ArkUI 里 **placeholder 不跟随 `.fontSize()`**，必须单独 `.placeholderFont({ size: 12 })`，
           *      否则占位符按默认 16fp 渲染 ⇒ 看起来比左侧标签大一圈（用户说的"输入框文字偏大"就是它）。 */
          Row({ space: 8 }) {
            Text('频道名').fontSize(12).fontColor('#bbbbbb').width(52)
            TextInput({ text: $$this.iptvName, placeholder: '留空则自动取域名' })
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .placeholderFont({ size: 12 })
              .backgroundColor('#0f3460')
              .fontColor('#eeeeee')
              .placeholderColor('#7a7a7a')
              .borderRadius(6)
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('播放地址').fontSize(12).fontColor('#bbbbbb').width(52)
            TextInput({ text: $$this.iptvUrl, placeholder: 'http:// 或 https:// 开头的 m3u8 / ts' })
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .placeholderFont({ size: 12 })
              .backgroundColor('#0f3460')
              .fontColor('#eeeeee')
              .placeholderColor('#7a7a7a')
              .borderRadius(6)
          }
          .width('100%')

          /* 三个操作按钮（桌面同款顺序；配色分层：主操作=实心蓝、次要=描边、删除=危险红） */
          Row({ space: 8 }) {
            this.iptvBtn('添加到列表', () => { this.iptvAdd(); }, 'primary')
            this.iptvBtn('更新选中', () => { this.iptvUpdate(); }, 'ghost')
            this.iptvBtn('删除选中', () => { this.iptvRemove(); }, 'danger')
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)

          /* 手机/鸿蒙特有：粘贴 m3u 文本导入 */
          Text(this.iptvShowImport ? '粘贴 m3u 文本（#EXTINF:-1,频道名 换行 地址）' : '从 m3u 文本导入 ▾')
            .fontSize(11)
            .fontColor('#2f6bff')
            .width('100%')
            .onClick(() => { this.iptvShowImport = !this.iptvShowImport; })
          if (this.iptvShowImport) {
            TextArea({ text: $$this.iptvImportText, placeholder: '把 m3u 内容粘到这里' })
              .height(72)
              .width('100%')
              .fontSize(11)
              .placeholderFont({ size: 11 })
              .backgroundColor('#0f3460')
              .fontColor('#eeeeee')
              .placeholderColor('#7a7a7a')
              .borderRadius(6)
              .margin({ bottom: 8 })
            Row({ space: 8 }) {
              this.iptvBtn('导入到列表', () => { this.iptvImport(); }, 'primary')
              this.iptvBtn('关闭', () => { this.iptvShowImport = false; }, 'ghost')
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }

          /* 提示（错误红 / 说明灰；都留在窗内） */
          Text(this.iptvErr.length > 0
            ? this.iptvErr
            : (this.iptvHint.length > 0
              ? this.iptvHint
              : `当前 ${this.iptvRows.length} 条自定义源。\n· 支持 m3u8 / ts 直播直链；保存后立即生效，无需重启\n· 也可用文本编辑器直接编辑：${this.iptvPathText()}`))
            .fontSize(10)
            .fontColor(this.iptvErr.length > 0 ? '#ff3b3b' : '#8a8a8a')
            .textAlign(TextAlign.Start)
            .width('100%')
        }
        .width('100%')
      }
      /* ★ 高度：**不再用 `layoutWeight(1)`**（那会把中段强行撑满剩余空间 ⇒ 竖屏下面一大片空白 ✗）。
       *   改成"上限 + 可压缩"：
       *     · 竖屏：上限 420vp（足够放"两个输入框 + 三个按钮 + 导入 + 提示"）⇒ 内容不到就按内容高 ⇒ 紧凑 ✓；
       *     · 横屏：上限 110vp ⇒ 固定部分（标题 24 + 列表 90 + 底栏 32 + 内边距/间距 ~64）≈ 210，
       *       合计 ≈ 320vp < 0.92×屏高（≈331vp）⇒ 底栏绝不会被顶出屏幕 ✓；
       *     · `flexShrink(1)`：极端矮屏时只有中段继续让步（其余都是 flexShrink(0)）。 */
      .flexShrink(1)
      .constraintSize({ maxHeight: this.isWide() ? 110 : 420 })
      .width('100%')
      .scrollBar(BarState.Auto)

      /* 取消 / 保存并生效 —— **钉在弹窗底部**（矮窗口里也永远可见）；取消 = 描边次要档、保存 = 实心蓝主档 */
      Row({ space: 10 }) {
        Blank()
        this.iptvBtn('取消', () => { this.showIptv = false; }, 'ghost')
        this.iptvBtn('保存并生效', () => { this.iptvSave(); }, 'primary')
      }
      .width('100%')
      .flexShrink(0)      /* 底栏高度不让步 */
    }
    .width('90%')
    /* ★★ 高度策略（2026-10-02 三次修正）★★
     *   上一版 `.height('92%')` 是**固定**高度 ⇒ 横屏修好了，但**竖屏**内容不多时下面空一大块（用户实测"不紧凑"）。
     *   改成 `.constraintSize({ maxHeight: '92%' })` = **只设上限、不设高度** ⇒ 弹窗按内容高度自适应（竖屏紧凑 ✓），
     *   内容真的超出时才被上限裁住 —— 那时由中段（`flexShrink(1)` + 自己的 maxHeight）让步并滚动，
     *   底栏仍钉在底部 ⇒ 横屏也点得到「取消 / 保存并生效」✓。 */
    .constraintSize({ maxHeight: '92%' })
    .padding(16)
    .borderRadius(14)
    .backgroundColor('#161616')
  }

  /** 自定义源文件路径文案（拿不到上下文时给个占位，别让提示显示 "undefined"） */
  private iptvPathText(): string {
    const ctx: common.UIAbilityContext | undefined = this.hostContext();
    return ctx === undefined ? 'iptv-local.m3u' : iptvFilePath(ctx);
  }

  /** 未实现功能的统一提示（别静默——用户会以为点坏了） */
  private notImplemented(name: string): void {
    this.getUIContext().getPromptAction().showToast({ message: `${name}：后续版本开放`, duration: 1500 });
    Log.i(`[Index] 点击未实现功能: ${name}`);
  }

  /** ★ 2026-09-24：首次启动的「内容来源与免责声明」弹窗（**必须主动点"同意"才能继续**，点空白处不关闭） */
  @Builder
  disclaimerModal() {
    Column({ space: 10 }) {
      Text('内容来源与免责声明')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#ffffff')
      Scroll() {
        Text(DISCLAIMER_TEXT)
          .fontSize(12)
          .fontColor('#cccccc')
          .textAlign(TextAlign.Start)
          .width('100%')
      }
      .height(250)
      .width('100%')
      .scrollBar(BarState.Auto)
      /* ★ 举报/联系渠道：**长按可复制**（`.copyOption`），便于用户把邮箱抄走 */
      Text(`${CONTACT_LABEL}${CONTACT_EMAIL}`)
        .fontSize(12)
        .fontColor('#8ab4ff')
        .copyOption(CopyOptions.LocalDevice)
      Text(this.disclaimerReadOnly ? '以上为当前生效的声明内容' : '继续使用即表示您已阅读并同意以上说明')
        .fontSize(10)
        .fontColor('#777777')
      Row({ space: 10 }) {
        /* ★ 2026-09-29：**再次查看**时不出现"不同意并退出" —— 用户早已同意过，逻辑上不该再问一次
           （与桌面端 `DisclaimerWindow(firstRun:false)` 同口径）。 */
        if (!this.disclaimerReadOnly) {
          Text('不同意并退出')
            .fontSize(13)
            .fontColor('#999999')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor('#2a2a2a')
            .onClick(() => { this.refuseDisclaimer(); })
        }
        Text(this.disclaimerReadOnly ? '关闭' : '我已阅读并同意')
          .fontSize(13)
          .fontColor('#ffffff')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor('#2f6bff')
          .onClick(() => { this.agreeDisclaimer(); })
      }
      .margin({ top: 2 })
    }
    .width('86%')
    .padding(16)
    .borderRadius(14)
    .backgroundColor('#161616')
  }

  @Builder
  epgModal() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(`${this.currentName} · 节目单`).fontSize(14).fontColor('#e0e0e0').layoutWeight(1)
        Text('关闭').fontSize(13).fontColor('#2f6bff')
          .onClick(() => { this.showEpg = false; })
      }
      .width('100%')
      /* ★★ 2026-11-09（用户要求）：**日期选择行**
       *   ① 星期与日期**分两行**；② 不显示滚动条但仍可滑；
       *   ③ 打开弹窗时把「当前节目所在那天」滚到**弹窗中间**（`scrollEpgDayToSel`，与安卓 `dayRowState` 同义）。 */
      List({ space: 6, scroller: this.epgDayScroller }) {
        ForEach(this.epgDays(), (d: string) => {
          ListItem() {
            Column({ space: 1 }) {
              Text(dayHead(d))
                .fontSize(12)
                .fontColor(this.epgDayColor(d))
                .fontWeight(this.epgDayBold(d) ? FontWeight.Bold : FontWeight.Normal)
              Text(dayDate(d))
                .fontSize(11)
                .fontColor(this.epgDayColor(d))
            }
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor(this.epgDayBg(d))
            .onClick(() => {
              this.epgSelDay = d;
              this.scrollEpgToNow();
              this.logEpgDayStats('切日', d);
            })
          }
        }, (d: string) => d)
      }
      .width('100%')
      .height(46)
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)

      /* ★ List + ListScroller：支持 scrollToIndex(..., ScrollAlign.CENTER) 把"正在播出"定位到中间
       * ★★ 2026-11-10：数据源换成 `epgRows()`（整行视图模型），key 用 `row.key`
       *   —— 键里带 ymd+startMs+状态，切换日期/跨点/回看状态变化时该行必定重建，
       *   不会再出现"上一天的红粗/回看残留"（详见 `EpgRow` / `epgRows` 注释）。 */
      List({ space: 0, scroller: this.epgListScroller }) {
        ForEach(this.epgRows(), (row: EpgRow) => {
          ListItem() {
            /* ★ 条目**不再各自带背景**（原来深浅相间、"像斑马纹"，与弹窗底色不协调）：
             *   直接在弹窗窗体上显示，靠"细分隔线 + 正在播出用红色文字"区分。 */
            Column() {
              Row({ space: 8 }) {
                /* ★ 2026-11-09（对齐安卓 `EpgModal`）：
                 *   正在回看 → 红字加粗；**直播中那条在回看时降为绿字**（用户要求，与回看区分）；
                 *   其余灰字。颜色/字重均由 `epgRows()` 预计算。 */
                Text(row.startText)
                  .fontSize(11)
                  .fontColor(row.color)
                  .width(84)
                Text(row.title)
                  .fontSize(12)
                  .fontColor(row.color)
                  .fontWeight(row.bold ? FontWeight.Bold : FontWeight.Normal)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                /* ★ 右侧状态标记（与安卓 `EpgModal` 同一套判据与文案），全部由 `epgRowState` 决定：
                 *   1 回看中（红粗）· 2 直播中（回看时绿）· 3 回看（蓝，可点）·
                 *   4 不可回看（灰，不可点）· 0 未来节目 ⇒ **不加任何标记** */
                if (row.label.length > 0) {
                  Text(row.label)
                    .fontSize(row.labelSize)
                    .fontColor(row.labelColor)
                    .fontWeight(row.labelBold ? FontWeight.Bold : FontWeight.Normal)
                }
              }
              .width('100%')
              .padding({ left: 2, right: 2, top: 7, bottom: 7 })
              Divider().color('#2f2f2f').strokeWidth(0.5)
            }
            .width('100%')
            .onClick(() => {
              /* 只有 1/2/3 可点（4 = 官方不让回看，0 = 未来节目/无时间戳） */
              if (row.state === 1 || row.state === 2 || row.state === 3) {
                this.startReplay(row.item);
              }
            })
          }
        }, (row: EpgRow) => row.key)
      }
      .width('100%')
      .layoutWeight(1)
      /* ★ 2026-11-09（用户要求）：**不显示滚动条**（原来它压住右侧「回看」按钮），但仍可滚动 */
      .scrollBar(BarState.Off)
    }
    /* ★ 横屏：弹窗宽度与**画面宽**一致（原 92% 是整个横屏宽 ⇒ 太宽、与视频不协调）；
     *   高度也顺势用足（86%），否则窄而矮不成比例。 */
    .width(this.isWide() ? this.videoBoxW() : '92%')
    .height(this.isWide() ? '86%' : '72%')
    .padding(14)
    .backgroundColor('#1e1e1e')
    .borderRadius(12)
  }

  build() {
    Stack() {
      /* ★★ 只用**同一个 Flex 容器**切换方向，不再 `if(横屏) Row{} else Column{}` ★★
       *   原因（真机黑屏根因）：切换 Row/Column 会让 XComponent **被重建** ⇒ 生成新 surfaceId，
       *   而 AVPlayer 仍指向旧 surface ⇒ 立刻黑屏。日志证据：每次旋转/退出全屏都多打印一条
       *   `[Index] XComponent surface 就绪: …`（…2746/2747/2748… 每次都是新的）。
       *   Flex 只改 direction ⇒ 组件实例不重建 ⇒ surfaceId 不变 ⇒ 旋转/进出全屏不再黑屏。 */
      Flex({
        direction: this.isWide() ? FlexDirection.Row : FlexDirection.Column,
        justifyContent: FlexAlign.Start
      }) {
        /* ★ 横屏时间距 8 → 4：把省下的高度让给画面（用户要求"横屏尽量压缩上下信息区"） */
        Column({ space: this.isWide() ? 4 : 8 }) {
          if (!this.isFullscreen) {
            this.statusBar();
          }
          this.playerArea();
          if (!this.isFullscreen) {
            this.epgStrip();   /* ★ 视频下方显示"正在播出/接下来"（横屏同样保留） */
          }
        }
        .width('100%')
        /* ★ 子项按"画面宽度"居中 ⇒ 信息栏/节目条与画面左右边缘对齐（画面本身也是居中的） */
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(this.isWide() ? 68 : (this.isFullscreen ? 1 : 0))
        .backgroundColor('#0a0a0a')

        if (!this.isFullscreen) {
          Column() {
            this.channelTabsAndList();
          }
          .width('100%')
          .layoutWeight(this.isWide() ? 32 : 1)
          .backgroundColor('#0d0d0d')
        }
      }
      /* ★★ 横屏窗口模式**不要再让出顶部状态栏** ★★
       *   截图证据（2026-09-15）：系统状态栏是系统自己画的**白色**条（占 0~34vp），
       *   而 App 内容从 ~77vp 才开始 —— 中间那条空黑带正好 ≈ insetTop(38.9vp)。
       *   ⇒ 窗口内容区本身就已经避开了状态栏，此处再加 top:insetTop 属于**重复让位**，
       *     凭空多出一条黑带，还把下方节目条顶出屏外（用户实测截图：节目条只露出一小截）。
       *   底部仍保留 insetBottom：部分机型横屏时导航栏会压在内容上（本机上报 0 ⇒ 无影响）。 */
      .padding({ bottom: this.isWide() ? this.insetBottom : 0 })
      .width('100%')
      .height('100%')
      .backgroundColor('#0a0a0a')

      if (this.showEpg) {
        Column() {
          this.epgModal();
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000aa')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => { this.showEpg = false; })
      }

      /* ★ 首启免责声明（最上层；**不挂 onClick** ⇒ 点空白处关不掉，必须点按钮） */
      if (this.showDisclaimer) {
        Column() {
          this.disclaimerModal();
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000cc')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      /* ★ 2026-10-02：自定义 IPTV 源编辑弹窗（同桌面端 `IptvSourceWindow` 的交互） */
      if (this.showIptv) {
        Column() {
          this.iptvModal();
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000cc')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 拉 EPG（capi 直连 + protobuf 解码）。
 * 接口：GET https://capi.yangshipin.cn/api/yspepg/program/{pid}/{yyyyMMdd}
 * 返回为 protobuf 二进制 → `decodeEpgProtobuf` 解成 JSON 数组（字段 title/start/end）。
 */
async function fetchEpgItems(url: string, ymd: string = ''): Promise<EpgItem[]> {
  const client = http.createHttp();
  try {
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': Ua,
        'yspappid': YspAppId,
        'Accept': '*/*'
      },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 8000,
      readTimeout: 8000
    });
    const r = resp.result;
    let bytes: Uint8Array = new Uint8Array(0);
    if (r instanceof ArrayBuffer) {
      bytes = new Uint8Array(r);
    }
    const json: string = decodeEpgProtobuf(bytes);
    const raw = JSON.parse(json) as Array<Record<string, Object>>;
    const out: EpgItem[] = [];
    for (const x of raw) {
      const s: string = String(x['start'] ?? '');
      const e: string = String(x['end'] ?? '');
      const sm: number = toMs(s);
      out.push({
        title: String(x['title'] ?? ''),
        /* ★ 与安卓 `Epg.hhmm()` 同规则：有 epoch 秒就按它格式化；否则退回字段 [5]/[6] 的
         *   "HH:mm" 原文（原来一律 `hhmm()` 会把 "06:00" 变成 "--:--"）。 */
        start: sm > 0 ? hhmm(s) : (s.indexOf(':') >= 0 ? s : '--:--'),
        end: toMs(e) > 0 ? hhmm(e) : (e.indexOf(':') >= 0 ? e : '--:--'),
        now: isNow(s, e),
        /* ★ 保留原始毫秒时间戳：节目跨点时在本地重新判定"正在播出"（无需再请求） */
        startMs: sm,
        endMs: toMs(e),
        /* ★ rp=0 表示官方明确"不可回看"（版权等原因）；缺字段一律按可回看处理 */
        replayable: (x['rp'] as number) !== 0,
        /* ★ 2026-11-10：**所属日期以 start 时间戳为准**（没有时间戳才退回请求参数里的日期）。
         *   抓包实测每台每天只给 06:00(4K)/07:00(8K) → 当天 23:59 的节目，凌晨那段没有数据；
         *   以时间戳归天可保证"日期 TAB ↔ 节目时刻"永远自洽，
         *   服务端若给错（请求未来日却返回今天的时刻），也不会出现"未来日期全是回看"。 */
        ymd: sm > 0 ? ymdOfMs(sm) : ymd
      } as EpgItem);
    }
    return out;
  } finally {
    client.destroy();
  }
}

/** `yyyyMMdd`（带天数偏移；0 = 今天） */
function ymdOf(offsetDays: number): string {
  const d: Date = new Date(Date.now() + offsetDays * 86400000);
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
}

/** 某个 epoch **毫秒**（本地时区）属于哪一天：`yyyyMMdd`（节目按 start 归天用） */
function ymdOfMs(ms: number): string {
  const d: Date = new Date(ms);
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
}

/** 某个 epoch 秒（本地时区）属于哪一天：`yyyyMMdd`（回看节目按"同一天"匹配要用它） */
function ymdOfSec(sec: number): string {
  return ymdOfMs(sec * 1000);
}

/**
 * 去重 + 按开始时间升序（与安卓 `fetchRange` 的 `sortedBy { it.start }` 一致）。
 * 10 天的响应之间理论上不该重叠，但"今日 30s 对齐"与"10 天全量"两次结果合并时可能出现
 * 同一档（同 ymd + 同时刻）两份 ⇒ 弹窗里会显示成两行，这里统一收口。
 * 判重键用 `ymd + start + end + title`：同一天同一档才算重复，短节目挤在同一分钟也不会被误删。
 */
function epgDedupe(items: EpgItem[]): EpgItem[] {
  const seen: Set<string> = new Set<string>();
  const out: EpgItem[] = [];
  for (const it of items) {
    const k: string = `${it.ymd}#${it.startMs}#${it.endMs}#${it.title}`;
    if (seen.has(k)) {
      continue;
    }
    seen.add(k);
    out.push(it);
  }
  out.sort((a: EpgItem, b: EpgItem) => a.startMs - b.startMs);
  return out;
}

/**
 * ★ 2026-11-08：拉「**前 6 天 + 今天 + 后 3 天**」共 10 天的节目单（与安卓 `Epg.fetchRange(pid, 6, 3)` 一致）。
 *   · 过去的天用于**回看**（服务端回看窗口 7 天），未来的天用于"预告"；
 *   · 单天失败只跳过该天（过去太久时服务端可能没数据），不整段失败；
 *   · 结果按开始时间升序，每条带 `ymd` 供弹窗按天分组。
 */
async function fetchEpgRange(pid: string): Promise<EpgItem[]> {
  const out: EpgItem[] = [];
  for (let d = -6; d <= 3; d++) {
    const ymd: string = ymdOf(d);
    const url: string = `https://capi.yangshipin.cn/api/yspepg/program/${pid}/${ymd}`;
    try {
      const one: EpgItem[] = await fetchEpgItems(url, ymd);
      for (const it of one) {
        out.push(it);
      }
    } catch (e) {
      /* 单天失败忽略（过去太久的日期服务端可能无数据） */
    }
  }
  return epgDedupe(out);
}

/** 日期行的**第一行**：`今日` / `星期一`…（与安卓 `EpgModal` 的日期行一致） */
function dayHead(ymd: string): string {
  if (ymd.length !== 8) {
    return ymd;
  }
  const y: number = Number(ymd.substring(0, 4));
  const m: number = Number(ymd.substring(4, 6));
  const d: number = Number(ymd.substring(6, 8));
  if (ymd === ymdOf(0)) {
    return '今日';
  }
  const w: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
  return w[new Date(y, m - 1, d).getDay()];
}

/** 日期行的**第二行**：`11/8` */
function dayDate(ymd: string): string {
  if (ymd.length !== 8) {
    return '';
  }
  return `${Number(ymd.substring(4, 6))}/${Number(ymd.substring(6, 8))}`;
}

/**
 * ★★ 2026-09-23 新增：IPTV 外部明文直链的**起播前预检**（带超时）★★
 *
 * 语义与桌面端 `windows/MainWindow.xaml.cs` 的 `IptvSourceAliveAsync` **保持一致**：
 *   · 超时 / 连不上 / URL 非法 ⇒ **判不可用**（false）—— 外部源慢/失效是常态，
 *     把死链路交给 AVPlayer 只会让它卡在网络读上（真机症状：**画面卡死**，只能"重开应用"）；
 *   · 非 2xx（403/404…）⇒ **不拦**（true）—— 外部源常因缺 Referer/其它头而回 403，且这类响应
 *     秒回、不会挂住界面；拦下会**误杀可用源**（实测：广州电视 403）。真不能播时，
 *     播放器自己的 error 路径 + `fallbackToPlayingChannel` 依旧会兜底；
 *   · 2xx 但**响应体为空** ⇒ 判无信号（原版鸿蒙所谓的 `no-playurl`）。
 * ⇒ 判不可用时调用方**根本不换播放器**，只把 UI 退回原台（与 CCTV-10 版权那条路径同款）。
 */
async function probeIptvSource(url: string): Promise<boolean> {
  if (url.length === 0) {
    return false;
  }
  const client = http.createHttp();
  try {
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': Ua,
        'Accept': '*/*'
      },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: IPTV_PROBE_TIMEOUT_MS,
      readTimeout: IPTV_PROBE_TIMEOUT_MS
    });
    const code: number = resp.responseCode;
    if (code < 200 || code >= 300) {
      Log.w(`[Index] IPTV 预检 HTTP ${code}（不拦，交播放器试播）`);
      return true;
    }
    const r = resp.result;
    let len: number = 0;
    if (r instanceof ArrayBuffer) {
      len = r.byteLength;
    }
    return len > 0;
  } catch (e) {
    Log.w(`[Index] IPTV 预检失败（超时/不可达）: ${(e as Error).message}`);
    return false;
  } finally {
    client.destroy();
  }
}

/** 时间戳（秒或毫秒）→ HH:mm */
function hhmm(v: string): string {
  let n: number = Number(v);
  if (!Number.isFinite(n) || n <= 0) {
    return '--:--';
  }
  if (n < 100000000000) {
    n = n * 1000;
  }
  const d = new Date(n);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** 时间戳（秒或毫秒）→ 毫秒；非法或缺失返回 0 */
function toMs(v: string): number {
  let n: number = Number(v);
  if (!Number.isFinite(n) || n <= 0) {
    return 0;
  }
  if (n < 100000000000) {
    n = n * 1000;
  }
  return n;
}

/** 当前时间是否落在 [start, end) */
function isNow(s: string, e: string): boolean {
  const a: number = toMs(s);
  const b: number = toMs(e);
  if (a <= 0 || b <= 0) {
    return false;
  }
  const now: number = Date.now();
  return now >= a && now < b;
}

/**
 * ★ 判断是否为"网络类"取流错误（用于自动重试 + 给用户中文提示）。
 *   真机见过的原文：`Failed to resolve the host name`、`Failed to connect to the server`、
 *   `timeout`、`Net`/`network` 相关文案；这些多为瞬时抖动，值得自动重试而不是直接报错。
 *
 * 2026-11-07：**"鉴权失效"这一档已随 Web/PC 链路删除**（新链路没有 token 概念），
 *   所以这里只看网络特征；`YspLive` 的内部错误文案（"取流请求失败"、"响应解析失败"）也一并覆盖。
 */
function isNetErr(msg: string): boolean {
  const m: string = msg.toLowerCase();
  return m.indexOf('resolve the host') >= 0 || m.indexOf('failed to connect') >= 0 ||
    m.indexOf('timeout') >= 0 || m.indexOf('timed out') >= 0 || m.indexOf('network') >= 0 ||
    m.indexOf('socket') >= 0 || m.indexOf('unreachable') >= 0 || m.indexOf('econn') >= 0 ||
    m.indexOf('网络无响应') >= 0 || m.indexOf('网络响应异常') >= 0 || m.indexOf('http 0') >= 0 ||
    m.indexOf('network is down') >= 0 || m.indexOf('connection') >= 0 ||
    m.indexOf('取流请求失败') >= 0 || m.indexOf('http ') >= 0;
}
