/**
 * Index.ets —— 掌上电视（gate4：频道列表 → 自动取流 → 明文播放）
 *
 * ★ 界面/交互**照搬原鸿蒙版**（`D:\TV\CCTV\旧 ArkWeb 版\...\pages\Index.ets`）：
 *   深色主题（底 #0a0a0a / 卡 #1e1e1e / 主蓝 #2f6bff / 当前台红 #ff3b3b / 当前节目红 #ff4444）
 *   状态栏（圆点 + 状态文字 + LoadingProgress）
 *   播放区（原生 AVPlayer + XComponent surface，明文由本地代理产出）
 *   胶囊 Tab（CCTV / 卫视 / 本地）+ 圆形台标网格（竖屏 5 列、横屏 3 列）
 *   当前/下一节目条 + 「接下来精彩内容」8 小时节目单 + EPG 弹层
 *
 * ★ 与原版的核心差异：**不再需要 ArkWeb / hls.js / /sapi 脚本注入**（相关遗留模块已全部删除）
 *   - 解密：native（libcmg_napi.so，原地解密成明文 TS）
 *   - 播放：media.AVPlayer + XComponent(SURFACE)（真正的原生 AVPlayer，音量可控）
 *   - 取流：`StreamResolver`（直连官方域名 + 本地 MD5 签名）
 *
 * 数据流：频道 → StreamResolver.resolve() → 远端 m3u8（含令牌）
 *        → LocalDecryptServer.localPlaylistUrl() → Video 播放（分片已是明文）
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
/** 全屏 / 横竖屏（沿用原鸿蒙版 旧 ArkWeb 版/Index.ets 的实现方式） */
import { window as ohWindow, display } from '@kit.ArkUI';
/** ★ 原生播放层：media.AVPlayer（配 XComponent surface 渲染）——真正的原生 AVPlayer */
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { CmgNative, CMG_ACTIVE_URL } from '../common/CmgNative';
import { LocalDecryptServer, SegStat } from '../common/LocalDecryptServer';
import { Channels, TvChannel, channelsByGroup, channelIcon } from '../common/ChannelList';
import { StreamResolver, ResolvePhase, genRandStr, warmDns } from '../common/StreamResolver';
import { NativeSigner } from '../common/NativeSigner';
import { decodeEpgProtobuf } from '../common/ProxyEpg';
import { YspAppId, Ua } from '../common/TvConfig';
/** ★ 播控中心/锁屏的媒体会话（2026-09-16 补齐；module.json5 早已声明 audioPlayback 但没有对应代码） */
import { TvSession } from '../common/TvSession';
/** ★ 音频焦点（AudioSession，恒 SHARE/MIX 不独占）+ 来电/其它应用打断（AVPlayer.on('audioInterrupt')） */
import { AudioFocus } from '../common/AudioFocus';
import { audio } from '@kit.AudioKit';

interface EpgItem {
  title: string;
  start: string;   // HH:mm
  end: string;
  now: boolean;
  /** ★ 原始时间戳（ms）：节目跨点时用它**在本地重新判定**"正在播出"，无需重新请求接口 */
  startMs: number;
  endMs: number;
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
const EPG_REFRESH_MS: number = 60000;

/**
 * ★★ 网络恢复自动续播参数（2026-09-15）★★
 *   用户实测：断网 → 立刻恢复网络后，App 停在"播放出错"不动了。
 *   ⇒ 网络类失败后按 5s 间隔自动重试，最多 24 次（≈2 分钟）；一旦出画就归零。
 */
const NET_RESUME_GAP_MS: number = 5000;
const NET_RESUME_MAX: number = 24;
/** 断网判定窗口（ms）：此窗口内的播放器 error/异常只告警、不重建播放器（重建也没用，纯浪费） */
const NET_DOWN_WINDOW_MS: number = 15000;

/* 取流签名已改为**原生实现**（gate3）：见 common/NativeSigner.ets
 * （keygen_bg.wasm + RJq7sO71JF.wasm 经 wasm2c 转 C，随 libcmg_napi.so 编入，
 *   已与官方 wasm 逐字符对拍一致；仅 cKey 待移植，见该文件注释） */

@Entry
@Component
struct Index {
  // ---------------- 状态 ----------------
  @State bootMsg: string = '正在初始化…';
  @State loading: boolean = false;
  @State videoSrc: string = '';
  @State playing: boolean = false;

  @State currentTab: ChannelGroup = TAB_CCTV;
  @State list: TvChannel[] = [];
  @State activeChannelId: string = '';
  @State currentName: string = '未选择频道';
  @State iconMap: Record<string, image.PixelMap> = {};
  @State iconSize: number = 46;

  @State episodeNow: string = '-';
  @State episodeNext: string = '-';
  @State epgItems: EpgItem[] = [];
  @State showEpg: boolean = false;
  /** ★ 状态灯：true = 播放出错（红点）；false = 正常播放（绿点）/待机（灰点） */
  @State playErr: boolean = false;
  /** ★ 全屏（横屏）模式：只显示视频，隐藏状态栏/节目条/频道栏 */
  @State isFullscreen: boolean = false;
  /** EPG 弹层滚动控制器（List 的 scrollToIndex 才支持 ScrollAlign.CENTER 精确定位） */
  private epgListScroller: ListScroller = new ListScroller();
  /** ★ 视频区中央提示（无流/暂停提供信号等，原版风格浮层），5 秒自消 */
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
  /** ★ 解密失败累计值的"已打印水位"（只在增加时打日志，避免每 5 秒重复刷同一行） */
  private lastFailedSeen: number = 0;

  private server: LocalDecryptServer = new LocalDecryptServer();
  private resolver: StreamResolver = new StreamResolver(new NativeSigner());
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
  private playRequestId: number = 0;
  /** 首播看门狗：本轮是否已自动重试过（成功出片后复位，见 armAutoRetry） */
  private retried: boolean = false;
  /** 首播看门狗定时器句柄（-1 = 未挂） */
  private retryTimer: number = -1;
  /** 上次因 AVPlayer 网络错误自动重连的时间戳（节流，避免重连风暴） */
  private lastErrReplay: number = 0;
  /** 进入后台的时间戳（0 = 当前在前台）；回前台超过 10s 需重新拉流 */
  private hideAt: number = 0;
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
      console.info(`[Index] 台标尺寸=${this.iconSize}vp（屏宽 ${Math.round(vpW)}vp）`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[Index] 取屏幕尺寸失败，用默认台标尺寸: ${err.message}`);
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
      console.warn(`[Index] 停止本地代理失败: ${e.message}`);
    });
  }

  /**
   * ★ 音频会话被系统停用（另一个应用抢占了焦点 / 系统策略）⇒ 暂停播放，**不自动恢复**。
   *   直播没有"续播点"的概念，等用户自己回来点更符合直觉；否则容易出现"声音自己又响了"。
   */
  private onAudioSessionLost(reason: string): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p !== null && (p.state === 'playing' || p.state === 'prepared')) {
      p.pause().catch((e: BusinessError) => {
        console.warn(`[Index] 音频会话失效后暂停失败: ${e.message}`);
      });
    }
    this.playing = false;
    this.bootMsg = `${this.currentName} 音频被其他应用占用，已暂停`;
    console.warn(`[Index] 音频会话被停用（reason=${reason}）⇒ 已暂停（不自动恢复）`);
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
      console.warn(`[Index] getHostContext 异常: ${(e as Error).message}`);
    }
    try {
      return getContext(this) as common.UIAbilityContext;
    } catch (e) {
      console.error(`[Index] getContext 兜底失败: ${(e as Error).message}`);
      return undefined;
    }
  }

  /** 启动序列：落资产 → native 初始化 → 真实墙钟 → 本地解密代理 → AVSession → 台标 → 起步热机 */
  private async bootSequence(): Promise<void> {
    const ctx = this.hostContext();
    if (!ctx) {
      this.bootMsg = '无法获取 UIAbilityContext';
      return;
    }
    try {
      const dir: string = await CmgNative.prepareAssets(ctx);
      const r: number = CmgNative.init('1788255533974', CMG_ACTIVE_URL, dir);
      if (r !== 0) {
        this.bootMsg = `native 初始化失败: ${CmgNative.lastInitError()}`;
        return;
      }
      // ★ 直播必须用**真实墙钟**（否则密钥流错 ⇒ 大面积马赛克）
      CmgNative.setClockReal();
      /* ★ 2026-09-16 定稿：**不调用** syncServerTime()
       *   该接口返回**二进制**（不是 JSON），拿不到 13/10 位时间戳（真机日志一直是"没找到时间戳"⇒ 回落本机钟）；
       *   而真实墙钟已用真机抓取分片 + 官方 gold 逐字节证明"0 字节差异"
       *   ⇒ 这个请求对 App 无实际作用，白耗一次网络往返。
       *   native 侧的 `cmgSetServerTime` 仍保留（设备时间被篡改的机型出马赛克时，这是第一个要打开的开关）。 */
      await CmgNative.enableCapture(ctx, 0);   // 诊断抓取：0 = 关

      // ★ gate3：原生签名器（keygen_bg.wasm + RJq7sO71JF.wasm，已在 native 内）
      if (!NativeSigner.ensureInit()) {
        console.error(`[Index] 原生签名器初始化失败: ${NativeSigner.lastError()}`);
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
            console.info(`[Index] 窗口 ${size.width}x${size.height} ⇒ ${land ? '横屏' : '竖屏'}`);
          }
        });
        w.setPreferredOrientation(ohWindow.Orientation.AUTO_ROTATION).catch((e: BusinessError) => {
          console.warn(`[Index] 设置自动旋转失败: ${e.message}`);
        });
        w.setWindowSystemBarEnable(['status', 'navigation']).catch((e: BusinessError) => {
          console.warn(`[Index] 系统栏设置失败: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        console.warn(`[Index] 获取窗口失败: ${e.message}`);
      });

      await this.server.start();
      /* ★ 播控中心/锁屏媒体会话（AVSession）：只建一次，失败只告警（不影响播放） */
      await this.initTvSession(ctx);
      this.bootMsg = '就绪';

      // 台标（动态名必须走 resourceManager，$r 不支持动态名）
      await this.loadIcons(ctx);
      // 统计
      this.statTimer = setInterval(() => {
        const st: SegStat = this.server.getStat();
        /* ★ 只在"失败数**增加**"时打印（2026-09-16 去噪）：`failed` 是累计值，
         *   旧写法每 5 秒把同一个数字重复打一遍（真机日志里刷了十几行，看着像持续故障）。 */
        if (st.failed > this.lastFailedSeen) {
          console.warn(`[Index] 解密失败累计 ${st.failed} 个分片（新增 ${st.failed - this.lastFailedSeen}），lastMaPcs=${st.lastMaPcs}`);
          this.lastFailedSeen = st.failed;
        }
      }, 5000);
    } catch (e) {
      const err = e as BusinessError;
      this.bootMsg = `启动异常: ${err.message}`;
      console.error(`[Index] bootSequence 异常: ${err.message}`);
    }
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
            console.warn(`[Index] 播控 play 失败 ⇒ 重新取流: ${e.message}`);
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
            console.warn(`[Index] 播控 pause 失败: ${e.message}`);
          });
        }
        this.pausedByInterrupt = false;   /* 用户主动暂停 ⇒ 不自动恢复 */
      },
      onStop: () => {
        const p: media.AVPlayer | null = this.avPlayer;
        if (p !== null) {
          p.stop().catch((e: BusinessError) => {
            console.warn(`[Index] 播控 stop 失败: ${e.message}`);
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
    const list: TvChannel[] = this.list;
    if (list.length === 0) {
      return;
    }
    let idx: number = list.findIndex((c: TvChannel) => c.id === this.activeChannelId);
    if (idx < 0) {
      idx = 0;
    }
    const n: number = (idx + offset + list.length) % list.length;
    console.info(`[Index] 播控切台 ⇒ ${list[n].name}`);
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
      console.warn(`[Index] keepScreenOn(${on}) 失败: ${e.message}`);
    });
  }

  /** 台标加载：getMediaByName → createImageSource → createPixelMap（照搬原版，并行加载） */
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
          const u8: Uint8Array = await ctx.resourceManager.getMediaByName(name);
          const src: image.ImageSource = image.createImageSource(u8.buffer.slice(0, u8.buffer.byteLength));
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
          console.info('[Index] 台标加载失败: ' + ch.id + ' ' + (e as Error).message);
        }
      })());
    }
    await Promise.all(tasks);
    this.iconMap = next;
    console.info(`[Index] 台标加载完成 ${Object.keys(next).length} 个（解码上限 ${wantPx}px）`);
    /* ★★ 起步热机（对齐原版 旧 ArkWeb 版 `warmupAuth`）：后台先把"上次看的台/第一个台"的 auth 做掉，
     *   首次点击就省掉一次外网往返（~150ms）。只发 1 个请求、不建播放器、不 await ⇒
     *   对启动速度几乎无影响（auth 缓存 120s 内对同一 pid 都有效）。 */
    this.warmupAuth();
    /* ★★ DNS/TLS 预热（对齐原版 `[warmDns]`）：不 await、失败忽略 ⇒ 首次取流少一次 DNS+TLS */
    warmDns();
  }

  /**
   * 起步热机：只预热 **auth**（原版 warmupAuth 的等价物，但取最省的一步）。
   * ★ 为什么不连 openToken/sessionToken 一起预热：原版注释明确
   *   "sessionToken 每次现取，不可缓存"，预热了也用不上；而 auth 是会话级的、可复用。
   */
  private warmupAuth(): void {
    let ch: TvChannel | undefined = Channels.find((c: TvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      ch = this.list.length > 0 ? this.list[0] : undefined;
    }
    if (ch === undefined) {
      return;
    }
    const target: TvChannel = ch;
    this.resolver.auth(target.pid, genRandStr(10))
      .then(() => { console.info(`[Index] 起步热机完成：auth ${target.name}`); })
      .catch((e: Error) => { console.warn(`[Index] 起步热机失败（不影响播放）: ${e.message}`); });
  }

  /** 切 Tab */
  private switchTab(t: ChannelGroup): void {
    this.currentTab = t;
    this.list = channelsByGroup(t);
  }

  // ---------------- 取流 + 播放 ----------------
  private async playChannel(ch: TvChannel): Promise<void> {
    this.playRequestId++;
    const requestId: number = this.playRequestId;
    this.activeChannelId = ch.id;
    this.currentName = ch.name;
    this.loading = true;
    this.playErr = false;
    /* ★ 新的一轮取流开始 ⇒ 取消"待续播"安排（失败时会重新安排，见 scheduleNetResume） */
    this.cancelNetResume();
    /* ★ 换台耗时打点：t0 = 点击；resolve 完成 / 首次出画 各打一次（用于定位慢在哪一段） */
    const t0: number = Date.now();
    /* ★ 新增：记录点击时刻，供 onPlayerState('playing') 计算全链路耗时 */
    this.tClickChannel = t0;   // ★ 记录点击时刻，供 onPlayerState('playing') 汇总
    this.bootMsg = `${ch.name} 正在获取播放地址…`;
    console.info(`[Index] 切台 ${ch.name} pid=${ch.pid} t0`);
    /* ★ 本地解密服务是播放链路的**单点**：起不来就必然播不了（端口被占/网络栈重启后
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
      let lastErr: Error = new Error('取流失败');
      let started: boolean = false;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const one = await this.resolver.resolve(ch, {
            onPhase: (p: ResolvePhase) => {
              if (requestId !== this.playRequestId) {
                return;
              }
              this.bootMsg = `${ch.name} ${p === 'auth' ? '鉴权中…' : (p === 'sign' ? '签名中…' : (p === 'token' ? '换取会话…' : '取流中…'))}`;
            }
          });
          if (requestId !== this.playRequestId) {
            return;   // 取流期间用户又换台 ⇒ 本次作废（结果直接丢弃）
          }
          /* ★ 成功分支就放在这里起播（不再先存变量、循环外再处理）：
           *   1) 少一个中间变量，流程更直观；
           *   2) 不必给中间变量写类型注解（曾经因为漏导入其类型而报 `Cannot find name` ✗）。 */
          // ★ 关键：喂给播放器的是**本地**地址；AVPlayer 取到的分片已是明文
          /* ★ 第二个参数是频道标识（cnlId）：作为**缓存键兜底**（万一远端 m3u8 的 query
           *   里没有 pid，就退用它，否则缓存键会退化成 URL ⇒ 永不命中/可能错片）。 */
          this.videoSrc = LocalDecryptServer.localPlaylistUrl(one.m3u8, ch.cnlId);
          console.info(`[Index] play -> ${this.videoSrc}`);
          this.bootMsg = `${ch.name} 正在缓冲…`;
          /* ★★ 换台提速：立刻预热 playlist + **头部 2 片**（与播放器 prepare 并行，只下载不解密）。
           *   不 await：预热在后台跑，命中缓存时播放器起播可省 0.6~1.2s。
           *   ⚠️ cnlId 必须传，保证与播放器请求用同一个缓存键。 */
          this.server.prewarm(one.m3u8, ch.cnlId);
          this.setupPlayer(this.videoSrc);   // ★ 交给原生 AVPlayer（surface 渲染）
          this.armAutoRetry(ch);   // ★ 首播看门狗：8 秒无分片则自动重取一次
          this.fetchEpg(ch.pid);
          /* ★ 播控中心/锁屏卡片：换台即更新标题与封面（台标 PixelMap） */
          const ts: TvSession | null = this.tvSession;
          if (ts !== null) {
            ts.setChannel(ch.name, ch.id, this.iconMap[ch.id]);
          }
          console.info(`[Index] resolve 完成 用时=${Date.now() - t0}ms（auth+签名+取流，之后交播放器）`);
          started = true;
          break;
        } catch (e) {
          const err = e as Error;
          lastErr = err;
          if (err.message.indexOf('版权') >= 0) {
            throw err;                 // 版权类不是网络问题 ⇒ 直接走下面的友好提示
          }
          if (attempt >= 3) {
            break;                     // 三次都失败 ⇒ 交给下面统一提示
          }
          /* ★★ 重试间隔按错误类型区分（2026-09-16）★★
           *   **鉴权失效（HTTP 401/403）不是网络问题** —— 是服务端把 token 作废了
           *   （我们的缓存比它的生命周期长；见 `StreamResolver.AUTH_TTL_MS`）。
           *   这种错下一次必然成功（会重新 auth），所以**不该等 1.5s**、也不该提示"网络信号差"。 */
          const authErr: boolean = isAuthErr(err.message);
          const waitMs: number = authErr ? 300 : 1500;
          console.warn(`[Index] 取流失败(第 ${attempt}/3 次) ⇒ ${waitMs}ms 后自动重试` +
            `${authErr ? '（鉴权失效：token 已作废，缓存已清，立即重新鉴权）' : ''}: ${err.message}`);
          this.bootMsg = authErr
            ? `${ch.name} 登录态过期，正在重新鉴权（${attempt}/3）…`
            : `${ch.name} 网络信号差，正在重试（${attempt}/3）…`;
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
      if (err.message.indexOf('版权') >= 0) {
        this.bootMsg = `${ch.name} 暂无直播信号`;
        // ★ 原版风格：视频区中央浮层提示 + 5 秒自消（与早期 ArkWeb 版 videoNotice 同款做法）
        this.showVideoNotice(`${ch.name} 应版权方要求，暂停提供直播信号，请点击其他频道观看`);
        this.activeChannelId = '';    // 版权限制：重试无意义 ⇒ 清选中态
        const ts1: TvSession | null = this.tvSession;
        if (ts1 !== null) {
          ts1.setStopped();
        }
      } else if (isAuthErr(err.message)) {
        /* ★ 鉴权类兜底（3 次都拿不到 token，很罕见）：保留选中态、稍后重试；
         *   提示与"网络信号差"区分，别让用户去查网络。 */
        console.error(`[Index] 鉴权失败（已重试 3 次）: ${err.message}`);
        this.bootMsg = `${ch.name} 登录态异常，稍后自动重试…`;
        this.playErr = false;
        this.scheduleNetResume();
      } else if (isNetErr(err.message)) {
        /* ★★ 网络类失败（重试 3 次仍失败）★★
         *   - 不把英文错误甩给用户：中文提示 + 中央浮层（只提示一次，后续静默重试）；
         *   - **保留 activeChannelId**（用户选中的频道）⇒ 才可能"网络恢复后自动续播"；
         *   - 记 netDownAt ⇒ 断网期间抑制播放器重建/重拉风暴；
         *   - scheduleNetResume() 每 5s 用当前频道重试（用户实测：断网→迅速恢复网络
         *     后 App 卡在报错不动，就是缺这一步）。 */
        console.error(`[Index] 取流失败（已重试 3 次）: ${err.message}`);
        this.netDownAt = Date.now();
        this.playErr = false;         // 正在自动重试，不是"播放出错"（避免信息栏变红误导）
        if (this.netResumeTries === 0) {
          this.showVideoNotice('网络信号差，暂时无法播放，正在自动重试…');
        }
        this.scheduleNetResume();
      } else {
        this.bootMsg = `${ch.name} 取流失败：${err.message}`;
        this.activeChannelId = '';
      }
      console.error(`[Index] playChannel 失败: ${err.message}`);
    } finally {
      if (requestId === this.playRequestId) {
        this.loading = false;
      }
    }
  }

  /** ★ 视频区中央提示（原版做法：浮层 + 5 秒自消，不打断当前播放） */
  private showVideoNotice(msg: string): void {
    this.videoNotice = msg;
    if (this.noticeTimer !== -1) {
      clearTimeout(this.noticeTimer);
    }
    this.noticeTimer = setTimeout(() => {
      this.videoNotice = '';
      this.noticeTimer = -1;
    }, 5000);
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
  private armAutoRetry(ch: TvChannel): void {
    /* ★ 网络刚失败时不挂看门狗：必然拉不到分片，只会与"网络恢复续播"轮询撞车 */
    if (this.isNetDownRecently()) {
      return;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    /* ★ 用 `total`（= 真正返回给播放器的分片数，含缓存命中/明文直通）判断"有没有出片"：
     *   2026-09-16 之前用的是 `decrypted`，而缓存命中曾错误地计入它、明文直通也计入它
     *   ⇒ 判据不纯；现已把 `decrypted` 修正为"真正解密过"，这里同步改用 total。 */
    const before: number = this.server.getStat().total;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      /* ★ 触发时已在后台 ⇒ 不重取（后台不下载不解密；回前台 onPageShow 会自己恢复） */
      if (this.hideAt > 0) {
        this.needRecoverOnShow = true;
        console.info('[Index] 看门狗触发时已在后台 ⇒ 跳过重取（回前台再处理）');
        return;
      }
      const after: number = this.server.getStat().total;
      if (after > before) {
        this.retried = false;   // 这轮正常，允许下一轮再救
        return;
      }
      if (this.retried) {
        console.warn('[Index] 自动重试后仍无分片，停止重试');
        return;
      }
      this.retried = true;
      console.warn('[Index] 8 秒内无分片解出 ⇒ 自动重取一次（首播连不上 CDN 节点的兜底）');
      this.playChannel(ch);
    }, 8000);
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
      console.info(`[Index] EPG ${pid} 拉取进行中 ⇒ 跳过重复请求`);
      return;
    }
    this.epgInflightPid = pid;
    try {
      const d = new Date();
      const ymd: string = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
      const url: string = `https://capi.yangshipin.cn/api/yspepg/program/${pid}/${ymd}`;
      const items: EpgItem[] = await fetchEpgItems(url);
      this.lastEpgDay = ymd;          /* 记录已拉取日期（跨天自动重拉用） */
      this.lastEpgFetchAt = Date.now(); /* ★ 记录"上次成功拿到"的时间（≥60s 才允许再走网络） */
      this.epgItems = items;
      const nowIdx: number = items.findIndex((it: EpgItem) => it.now);
      if (nowIdx >= 0) {
        this.episodeNow = `${items[nowIdx].start} ${items[nowIdx].title}`;
        this.episodeNext = (nowIdx + 1 < items.length)
          ? `${items[nowIdx + 1].start} ${items[nowIdx + 1].title}` : '暂无';
      } else {
        this.episodeNow = '暂无节目单';
        this.episodeNext = '-';
      }
      console.info(`[Index] EPG ${pid} 共 ${items.length} 条${attempt > 1 ? `（第 ${attempt} 次尝试成功）` : ''}`);
      /* ★ 启动"跨点自动刷新"：否则节目播完了，"正在播出/接下来"还停在旧节目（用户报的 BUG） */
      this.startEpgTicker();
    } catch (e) {
      const err = e as Error;
      console.warn(`[Index] EPG 失败(第 ${attempt}/3 次): ${err.message}`);
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
    this.epgTimer = setInterval(() => { this.refreshEpgNow(); }, 20000);
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
      const chRefresh: TvChannel | undefined =
        Channels.find((c: TvChannel) => c.id === this.activeChannelId);
      if (chRefresh !== undefined) {
        console.info('[Index] EPG 距上次网络刷新 ≥60s ⇒ 重新拉取');
        this.fetchEpg(chRefresh.pid);
      }
    }
    const nowMs: number = Date.now();
    let nowIdx: number = -1;
    let changed: boolean = false;
    const next: EpgItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: EpgItem = items[i];
      const cur: boolean = it.startMs > 0 && nowMs >= it.startMs && nowMs < it.endMs;
      if (cur) {
        nowIdx = i;
      }
      if (it.now !== cur) {
        changed = true;
      }
      next.push({
        title: it.title, start: it.start, end: it.end, now: cur,
        startMs: it.startMs, endMs: it.endMs
      } as EpgItem);
    }
    if (nowIdx >= 0) {
      const n: string = `${next[nowIdx].start} ${next[nowIdx].title}`;
      const nx: string = (nowIdx + 1 < next.length)
        ? `${next[nowIdx + 1].start} ${next[nowIdx + 1].title}` : '暂无';
      if (n !== this.episodeNow || nx !== this.episodeNext) {
        this.episodeNow = n;
        this.episodeNext = nx;
        console.info(`[Index] 节目单跨点 ⇒ 正在播出: ${n}`);
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
        const ch: TvChannel | undefined = Channels.find((c: TvChannel) => c.id === this.activeChannelId);
        if (ch !== undefined) {
          console.info('[Index] 当天节目单已播完（跨天）⇒ 重新拉取 EPG');
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
        console.info('[Index] 进入全屏（横屏自动旋转）');
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
          console.warn('[Index] 恢复系统亮度失败');
        }
        this.curBrightness = -1;
        console.info('[Index] 退出全屏');
      }
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[Index] 全屏切换失败: ${err.message}`);
    }
  }

  /**
   * ★ 打开节目单后，把"正在播出"那条**定位到弹层竖直中间**。
   *   直接调用会因为 Scroll 还没完成布局而失败 ⇒ 延迟 60ms 再滚（找不到当前节目就滚到第一条）。
   */
  private scrollEpgToNow(): void {
    let idx: number = this.epgItems.findIndex((it: EpgItem) => it.now);
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
        console.info(`[Index] EPG 定位到第 ${idx + 1} 条（正在播出，居中）`);
      } catch (e) {
        const err = e as Error;
        console.warn(`[Index] EPG 定位到当前节目失败: ${err.message}`);
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
    /* ★ 打点复位：否则"点击→出画 / setup→出画"会拿上一次的起点算出十几秒的假数字 */
    this.tClickChannel = 0;
    this.tSetupStart = 0;
    /* ★ 冷启动：onPageShow 会在 `aboutToAppear` 的 `bootSequence()` 之前触发，
     *   这时没有任何频道/播放器，**初始化一律交给 bootSequence**（否则日志里会出现
     *   `onPageShow ⇒ 恢复播放（后台 0s）` 这种误导行，而且会白建一次媒体卡）。 */
    if (!wasHidden && this.avPlayer === null && this.activeChannelId === '') {
      console.info('[Index] onPageShow ⇒ 冷启动（初始化由 bootSequence 负责）');
      return;
    }
    /* ★ 回前台：网络状态未知 ⇒ 清掉"断网标记 + 续播计数"，给这次恢复完整的重试额度 */
    this.resetNetResume();
    /* ★ 音频焦点：回前台重新激活（SHARE/MIX） */
    const afShow: AudioFocus | null = this.audioFocus;
    if (afShow !== null) {
      afShow.activate();
    }
    /* ★ 重建媒体卡（退后台时销毁过）+ 用当前频道刷新标题/台标 */
    const ctxShow: common.UIAbilityContext | undefined = this.hostContext();
    if (ctxShow !== undefined) {
      this.initTvSession(ctxShow).then(() => {
        const chShow: TvChannel | undefined =
          Channels.find((c: TvChannel) => c.id === this.activeChannelId);
        const tsShow: TvSession | null = this.tvSession;
        if (tsShow !== null && chShow !== undefined) {
          tsShow.setChannel(chShow.name, chShow.id, this.iconMap[chShow.id]);
        }
      }).catch((e: Error) => {
        console.warn(`[Index] 回前台重建媒体卡失败（忽略）: ${e.message}`);
      });
    }
    /* ★ 后台期间定时器被停掉 ⇒ 先补一次节目单刷新并重启（后台可能已跨点） */
    if (this.epgItems.length > 0) {
      this.refreshEpgNow();
      this.startEpgTicker();
    }
    if (away > 10000 && this.activeChannelId !== '') {
      /* ★★ 长后台回前台：**先主动作废该频道的 auth 缓存**（2026-09-16）★★
       *   日志实测：用 >~60s 前的 token 去取流，服务端必回 `get_live_info HTTP 401`（空 body）
       *   ⇒ 每次都白等一次重试。既然已经知道它多半失效，就直接作废、一次做对（auth ~150ms）。 */
      const chLong: TvChannel | undefined =
        Channels.find((c: TvChannel) => c.id === this.activeChannelId);
      if (chLong !== undefined) {
        this.resolver.invalidateAuth(chLong.pid);
      }
      this.needRecoverOnShow = false;
      console.info(`[Index] onPageShow ⇒ 后台 ${Math.round(away / 1000)}s（>10s）⇒ 当前频道重新拉流`);
      this.replayActiveChannel();
      return;
    }
    /* ★ 短离（≤10s）但后台报过播放器错误 ⇒ 先销毁重建再恢复（后台我们故意没处理） */
    if (this.needRecoverOnShow) {
      this.needRecoverOnShow = false;
      console.info(`[Index] onPageShow ⇒ 后台 ${Math.round(away / 1000)}s，恢复播放器（后台曾报错，未在后台重建）`);
      this.destroyPlayer().then(() => {
        setTimeout(() => { this.replayActiveChannel(); }, 300);
      });
      return;
    }
    console.info(`[Index] onPageShow ⇒ 恢复播放（后台 ${Math.round(away / 1000)}s）`);
    this.resumePlayback();
  }

  /**
   * ★★ 退后台（对齐原版 `旧 ArkWeb 版` 的直播后台策略）★★
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
    /* 1) **停止一切主动下载/解密**：作废进行中的预热（播放器自身的分片请求随 pause 停止） */
    this.server.abortPrewarm();
    /* 2) 暂停播放（省电，也避免系统掐断后状态错乱） */
    const p: media.AVPlayer | null = this.avPlayer;
    if (p !== null && p.state === 'playing') {
      p.pause().catch((e: BusinessError) => { console.warn(`[Index] 退后台暂停失败: ${e.message}`); });
    }
    this.pausedByInterrupt = false;
    /* 3) 不再需要常亮 */
    this.applyKeepScreenOn(false);
    /* 4) 销毁媒体卡（避免"卡片在、按钮点了不生效"；回前台 onPageShow 重建） */
    const tsHide: TvSession | null = this.tvSession;
    if (tsHide !== null) {
      tsHide.destroy();
      this.tvSession = null;
    }
    /* 5) 归还音频焦点（让其它应用恢复；合规且省电） */
    const afHide: AudioFocus | null = this.audioFocus;
    if (afHide !== null) {
      afHide.deactivate();
    }
    console.info('[Index] onPageHide ⇒ 已暂停、停止下载/解密、销毁媒体卡、归还音频焦点');
  }

  /**
   * ★ 恢复播放：优先 `play()`；失败说明直播 URL 已过期 ⇒ 用**当前频道重新取流**。
   *   （直播 m3u8 带 svrtime 时效，后台待久了回来必然失效。）
   */
  private resumePlayback(): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    const s: string = p.state;
    if (s === 'prepared' || s === 'paused' || s === 'playing') {
      p.play().catch((e: BusinessError) => {
        console.warn(`[Index] 恢复播放失败(${e.message}) ⇒ 重新取流`);
        this.replayOrWait();   // ★ 断网感知：网络刚失败则转 5s 轮询，不硬重拉
      });
    } else if (s === 'idle' || s === 'stopped' || s === 'initialized') {
      this.replayOrWait();
    }
  }

  /** 用当前选中的频道重新走一遍 playChannel（切台/恢复共用） */
  private replayActiveChannel(): void {
    const ch: TvChannel | undefined = Channels.find((c: TvChannel) => c.id === this.activeChannelId);
    if (ch !== undefined) {
      this.playChannel(ch);
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
      console.warn('[Index] 已在后台 ⇒ 不重拉流（回前台再恢复）');
      return;
    }
    if (this.isNetDownRecently()) {
      console.warn('[Index] 网络刚失败 ⇒ 暂不重拉流（改为 5s 轮询续播）');
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
    const ch: TvChannel | undefined = Channels.find((c: TvChannel) => c.id === this.activeChannelId);
    if (ch === undefined) {
      return;
    }
    if (this.netResumeTries >= NET_RESUME_MAX) {
      this.bootMsg = `${this.currentName} 网络不可用，请检查网络后重新点击频道`;
      console.warn('[Index] 网络恢复续播已达上限 ⇒ 停止自动重试');
      return;
    }
    this.netResumeTries++;
    const sec: number = Math.round(NET_RESUME_GAP_MS / 1000);
    const chId: string = ch.id;
    this.bootMsg = `${this.currentName} 网络异常，${sec}s 后自动重试（${this.netResumeTries}/${NET_RESUME_MAX}）`;
    console.warn(`[Index] 网络异常 ⇒ ${sec}s 后自动重试续播（第 ${this.netResumeTries}/${NET_RESUME_MAX} 次）`);
    this.netResumeTimer = setTimeout(() => {
      this.netResumeTimer = -1;
      if (this.activeChannelId !== chId || this.loading) {
        return;   // 期间换台了 / 已有取流在跑 ⇒ 本次作废
      }
      const c: TvChannel | undefined = Channels.find((x: TvChannel) => x.id === chId);
      if (c !== undefined) {
        this.playChannel(c);
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
      console.info(`[Index] 安全区 top=${this.insetTop} bottom=${this.insetBottom}`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[Index] 读安全区失败: ${err.message}`);
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
    const vw: number = this.videoW > 0 ? this.videoW : 16;
    const vh: number = this.videoH > 0 ? this.videoH : 9;
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
      console.warn(`[Index] 已在后台 ⇒ 不重建/不重拉，只登记待恢复: ${reason}`);
      return;
    }
    if (this.playerRebuilds >= 3) {
      this.playErr = true;
      this.bootMsg = `${this.currentName} 播放异常，请换台或重开应用`;
      this.showVideoNotice('播放器异常，无法自动恢复，请换台或重新打开应用');
      console.error(`[Index] 播放器重建已达上限(3) ⇒ 放弃: ${reason}`);
      this.applyKeepScreenOn(false);
      const tsFail: TvSession | null = this.tvSession;
      if (tsFail !== null) {
        tsFail.setStopped();
      }
      return;
    }
    /* ★★ 断网期间**不要重建播放器**：prepare 必然失败，只会叠加成"重建风暴"
     *   （用户实测断网时日志里 destroy/重建/重拉 反复出现，反而更慢）。
     *   ⇒ 只提示并交给"网络恢复自动续播"轮询。 */
    if (this.isNetDownRecently()) {
      console.warn(`[Index] 网络不可用期间不重建播放器，等待网络恢复续播: ${reason}`);
      this.playErr = false;
      this.bootMsg = `${this.currentName} 网络异常，正在等待网络恢复…`;
      this.scheduleNetResume();
      return;
    }
    this.playerRebuilds++;
    console.warn(`[Index] 播放器异常(${reason}) ⇒ 销毁重建并重拉流（第 ${this.playerRebuilds}/3 次）`);
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
      console.info('[Index] 已释放 AVPlayer（下次换台将重建）');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[Index] release 失败（忽略）: ${err.message}`);
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
      console.info(`[Index] ▶ setupPlayer[gen=${myGen}] 开始 at ${this.tSetupStart}`);

      /* ★★★ release 不 await（关键修复 2026-09-16）★★★
       *   实测：release() 会阻塞 700~1100ms（要等底层解码器/会话回收），
       *   而新 AVPlayer 用的是**同一个 XComponent surface**，可以立即创建，无需等待。
       *   ⇒ 让 release 在后台跑，不阻塞当前流程；旧实例的 stateChange 回调
       *     由世代号（myGen）过滤，不会干扰新实例。 */
      if (this.avPlayer !== null) {
        const old: media.AVPlayer = this.avPlayer;
        this.avPlayer = null;
        this.playing = false;
        console.info(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 已异步发起（不阻塞）`);
        old.release()
          .then(() => {
            console.info(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 完成（异步）`);
          })
          .catch((e: BusinessError) => {
            console.warn(`[Index] setupPlayer[gen=${myGen}] 旧实例 release 失败（忽略）: ${e.message}`);
          });
      }

      const p: media.AVPlayer = await media.createAVPlayer();

      /* ★★★ 关键：await 之后如果已被新台取代，立即释放刚创建的实例 ★★★ */
      if (myGen !== this.setupGen) {
        console.warn(`[Index] setupPlayer[gen=${myGen}] 被新台取代（新 gen=${this.setupGen}）⇒ 释放并放弃`);
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
          console.info(`[Index] setupPlayer[gen=${myGen}] 旧实例 state=${state} 回调被忽略`);
          return;
        }
        this.onPlayerState(state);
      });
      p.on('error', (err: BusinessError) => {
        if (myGen !== this.setupGen) {
          return;
        }
        console.error(`[Index] AVPlayer error ${err.code}: ${err.message}`);
        const st: string = this.avPlayer !== null ? this.avPlayer.state : 'idle';
        if (st === 'playing' || st === 'prepared') {
          console.warn(`[Index] 忽略瞬时网络错误（播放器状态 ${st}，仍在播）: ${err.code}`);
          return;
        }
        const now: number = Date.now();
        if (now - this.lastErrReplay < 10000) {
          console.warn('[Index] 距上次自动重连不足 10s，本次只告警');
          this.playErr = true;
          this.bootMsg = `${this.currentName} 播放中断`;
          return;
        }
        this.lastErrReplay = now;
        this.bootMsg = `${this.currentName} 信号中断，正在重连…`;
        this.playErr = false;
        console.warn('[Index] 播放中断 ⇒ 重新取流续播（网络刚失败则转 5s 轮询）');
        this.replayOrWait();
      });
      p.on('videoSizeChange', (w: number, h: number) => {
        if (myGen !== this.setupGen) {
          return;
        }
        if (w > 0 && h > 0) {
          this.videoW = w;
          this.videoH = h;
          console.info(`[Index] 视频分辨率 ${w}x${h}`);
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
        console.info(`[Index] 音频打断: event=${info.eventType} hint=${info.hintType} force=${info.forceType}`);
        if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
          info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
          /* 只对"暂停"记标记：STOP 语义上不该被我们自动恢复 */
          this.pausedByInterrupt = (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE);
          if (!forced) {
            const cur: media.AVPlayer | null = this.avPlayer;
            if (cur !== null && cur.state === 'playing') {
              cur.pause().catch((e: BusinessError) => {
                console.warn(`[Index] 打断暂停失败: ${e.message}`);
              });
            }
          }
          this.playing = false;
          this.bootMsg = `${this.currentName} 被其他应用中断，稍后自动恢复`;
        } else if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
          if (this.pausedByInterrupt) {
            this.pausedByInterrupt = false;
            console.info('[Index] 音频打断结束 ⇒ 恢复播放');
            this.bootMsg = `${this.currentName} 正在恢复…`;
            this.resumePlayback();
          }
        }
      });

      this.avPlayer = p;
      console.info(`[Index] setupPlayer[gen=${myGen}] 原生 AVPlayer 已创建`);

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
      console.error(`[Index] setupPlayer[gen=${myGen}] 失败 ${err.code}: ${err.message}`);
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
        console.info('[Index] AVPlayer 已挂载 surface');
      } else {
        console.warn('[Index] surfaceId 尚未就绪，先 prepare（onLoad 后补挂）');
      }
      /* ★ 再显式设一次起播水线（setMediaSource 已带一份，这里双保险；仅 initialized 允许 ✓），
       *   并**等它生效后再 prepare**（prepare 之后就不能再改了） */
      const st2: media.PlaybackStrategy = {
        preferredBufferDurationForPlaying: 2,
        showFirstFrameOnPrepare: true
      };
      console.info(`[Index] ▶ prepare 发起 at ${Date.now()}`);
      p.setPlaybackStrategy(st2)
        .catch((e: BusinessError) => {
          console.warn(`[Index] setPlaybackStrategy 失败（忽略，用 setMediaSource 那份）: ${e.message}`);
        })
        .then(() => {
          console.info(`[Index] ▶ prepare 实际调用 at ${Date.now()}`);
          p.prepare().catch((e: BusinessError) => {
            console.error(`[Index] prepare 失败: ${e.message}`);
            this.recoverPlayer(`prepare 失败: ${e.message}`);
          });
        });
    } else if (state === 'prepared') {
      /* ★ 画面缩放与音量都只能在 prepared 之后设置 */
      p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;   // 保持宽高比、不裁切
      /* ★ 音频打断模式：**SHARE_MODE（默认值，不独占）**——合规要求：不打断其它应用的音频。
       *   ⚠️ 只能在 prepared/playing/paused/completed 设置（提前设会报 5400102）。 */
      p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
      p.setVolume(this.muted ? 0 : this.volRatio);   // 音量大小时手势设定的 volRatio（0~1）
      p.play().catch((e: BusinessError) => { console.error(`[Index] play 失败: ${e.message}`); });
    } else if (state === 'playing') {
      this.playing = true;
      this.playErr = false;
      this.bootMsg = `${this.currentName} 播放中`;
      /* ★ 起播全链路耗时汇总 */
      const now: number = Date.now();
      console.info(`[Index] ◀ AVPlayer 开始播放 at ${now}` +
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
    } else if (state === 'error') {
      this.playErr = true;
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
      console.warn(`[Index] 设置亮度失败: ${e.message}`);
    });
  }

  // ---------------- UI ----------------
  @Builder
  statusBar() {
    Row({ space: 8 }) {
      /* ★ 状态灯：正常播放=绿；出错=红；未播放=灰。
       *   原来用 proxyOk 判断（本地代理一旦起来就恒为 true）⇒ 永远绿/红不分，看不出真实状态。 */
      Circle({ width: 8, height: 8 })
        .fill(this.playErr ? '#ff3b3b' : (this.playing ? '#3ddc84' : '#888888'))
      Text(this.bootMsg)
        .fontSize(12)
        .fontColor('#888')
        /* ★ 一律 1 行（原来竖屏允许 2 行 ⇒ 长状态文案会把信息栏顶高、高度忽高忽低） */
        .maxLines(1)
        .textAlign(TextAlign.Start)        /* ★ 文案**左对齐**（不做水平居中） */
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)                   /* 占满"状态灯之后"的宽度，长文案尽量少省略 */
      if (this.loading) {
        LoadingProgress().width(16).height(16).color('#2f6bff')
      }
    }
    .width(this.videoBoxW())   /* ★ 与画面同宽 ⇒ 与画面左右边缘对齐（用户要求："在正上方、宽度一致"） */
    /* ★★ 内容**垂直居中** ★★：状态灯 / 文案 / 菊花 三者都对齐到信息栏的**竖向中线**。
     *   配合下面的固定高度 ⇒ 不管文案多长、有没有菊花，文字都稳稳在中间（不会贴顶）。 */
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
          console.info(`[Index] XComponent surface 就绪: ${sid.substring(0, 24)}…`);
          const p: media.AVPlayer | null = this.avPlayer;
          if (p === null) {
            if (this.videoSrc !== '') {
              this.setupPlayer(this.videoSrc);   // 已有地址：起播
            }
          } else if (p.state === 'initialized') {
            /* ★ 只有 initialized 状态允许设 surfaceId（其它状态设置会报 5400102） */
            p.surfaceId = sid;
            console.info('[Index] surfaceId 已补挂到 AVPlayer');
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
                  p.pause().catch((e: BusinessError) => { console.warn(`[Index] pause 失败: ${e.message}`); });
                  this.playing = false;
                  this.pausedByInterrupt = false;   /* 用户主动暂停 ⇒ 打断结束后不再自动恢复 */
                } else {
                  p.play().catch((e: BusinessError) => { console.warn(`[Index] play 失败: ${e.message}`); });
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
            console.info(`[Index] ${this.screenLocked ? '已锁屏（仅左上角可解锁）' : '已解锁'}`);
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

      /* ★ 未选择频道时的中央提示 */
      if (this.videoSrc === '' && this.videoNotice === '') {
        Column() {
          Text('请选择下方频道开始观看')
            .fontSize(13)
            .fontColor('#888888')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }

      /* ★ 无流/暂停提供信号提示（原版风格：视频区中央浮层，不拦截触摸，5 秒自消） */
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
  channelIconItem(ch: TvChannel) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.iconMap[ch.id] !== undefined) {
        Image(this.iconMap[ch.id])
          .width('100%')
          .height('100%')
          /* ★ Contain（原为 Cover）：Cover 会把方形台标裁掉一圈，这就是"台标显示不全"的原因 */
          .objectFit(ImageFit.Contain)
      } else {
        Text(ch.name.substring(0, 1))
          .fontSize(this.iconSize * 0.45)
          .fontColor('#333333')
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

  @Builder
  channelTabsAndList() {
    Row({ space: 8 }) {
      Text('源站').fontSize(12)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .borderRadius(16)
        .backgroundColor(this.currentTab === TAB_CCTV ? '#2f6bff' : '#262626')
        .fontColor(this.currentTab === TAB_CCTV ? '#ffffff' : '#999999')
        .onClick(() => { this.switchTab(TAB_CCTV); })
      Text('卫视').fontSize(12)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .borderRadius(16)
        .backgroundColor(this.currentTab === TAB_SAT ? '#2f6bff' : '#262626')
        .fontColor(this.currentTab === TAB_SAT ? '#ffffff' : '#999999')
        .onClick(() => { this.switchTab(TAB_SAT); })
      Text('本地').fontSize(12)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .borderRadius(16)
        .backgroundColor(this.currentTab === TAB_LOCAL ? '#2f6bff' : '#262626')
        .fontColor(this.currentTab === TAB_LOCAL ? '#ffffff' : '#999999')
        .onClick(() => { this.switchTab(TAB_LOCAL); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })

    if (this.list.length === 0) {
      Text('该分组暂无频道')
        .fontSize(11)
        .fontColor('#666')
        .padding(12)
    } else {
      /* ★ 改用 Grid（原来 Scroll+Flex 在真机上会被"居中"）：
       *   Grid 的布局是确定的——从**左上角**开始逐行排布，1fr×5 列自动等分宽度，
       *   行数按内容增长、超出才滚动 ⇒ 靠上、留白在下方，与分辨率无关。 */
      Grid() {
        ForEach(this.list, (ch: TvChannel) => {
          GridItem() {
            this.channelIconItem(ch);
          }
          .padding({ top: 3, bottom: 3 })   /* 上下留白收窄（原来 6 偏大） */
        }, (ch: TvChannel) => ch.id)
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
          Text('正在播出')
            .fontSize(12)
            .fontColor('#ff4444')
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
          /* ★ 手绘右三角（原版做法）：用 Polygon 填充绿色。
           *   之前用字符 '▶' 会被系统按彩色 emoji 渲染 ⇒ 出不来绿色。 */
          Polygon({ width: 8, height: 8 })
            .points([[0, 0], [8, 4], [0, 8]])
            .fill('#3ddc84')
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

      Text('节目单 ☰')                       /* ★ 尾部三横字符（原版同款） */
        .fontSize(12)
        .fontColor('#2f6bff')
        .onClick(() => {
          this.showEpg = true;
          this.scrollEpgToNow();   // ★ 弹层打开后把"正在播出"定位到中间
        })
    }
    .width(this.videoBoxW())   /* ★ 与画面同宽 ⇒ 与画面左右边缘对齐（用户要求） */
    .alignItems(VerticalAlign.Center)       /* ★ 右侧按钮相对两行竖直居中 */
    /* ★ 横屏压缩高度（10 → 5）：节目条横屏只有一行，不需要那么高 */
    .padding({ left: 10, right: 10, top: this.isWide() ? 5 : 10, bottom: this.isWide() ? 5 : 10 })
    .backgroundColor('#181818')
    .borderRadius(8)
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
      /* ★ List + ListScroller：支持 scrollToIndex(..., ScrollAlign.CENTER) 把"正在播出"定位到中间 */
      List({ space: 0, scroller: this.epgListScroller }) {
        ForEach(this.epgItems, (it: EpgItem) => {
          ListItem() {
            /* ★ 条目**不再各自带背景**（原来深浅相间、"像斑马纹"，与弹窗底色不协调）：
             *   直接在弹窗窗体上显示，靠"细分隔线 + 正在播出用红色文字"区分。 */
            Column() {
              Row({ space: 8 }) {
                Text(`${it.start}-${it.end}`)
                  .fontSize(11)
                  .fontColor(it.now ? '#ff7b7b' : '#888')
                  .width(84)
                Text(it.title)
                  .fontSize(12)
                  .fontColor(it.now ? '#ff4444' : '#e0e0e0')
                  /* ★ 弹窗里"正在播出"那条也加粗，与节目条一致（用户要求） */
                  .fontWeight(it.now ? FontWeight.Bold : FontWeight.Normal)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 2, right: 2, top: 7, bottom: 7 })
              Divider().color('#2f2f2f').strokeWidth(0.5)
            }
            .width('100%')
          }
        }, (it: EpgItem, idx: number) => `${idx}-${it.start}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
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
async function fetchEpgItems(url: string): Promise<EpgItem[]> {
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
      out.push({
        title: String(x['title'] ?? ''),
        start: hhmm(s),
        end: hhmm(e),
        now: isNow(s, e),
        /* ★ 保留原始毫秒时间戳：节目跨点时在本地重新判定"正在播出"（无需再请求） */
        startMs: toMs(s),
        endMs: toMs(e)
      } as EpgItem);
    }
    return out;
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
 * ★ 判断是否为"鉴权失效"类取流错误（**不是网络问题**）。
 *
 * 真机日志（2026-09-16，长后台回前台第一次取流）：
 *   `get-live-info 请求失败: 网络无响应（HTTP 401，响应为空）` —— 服务端把 token 作废了。
 * 处理方式与网络类**不同**：立即重试（不走 1.5s 退避）、提示文案用"登录态过期"，
 * 且 `StreamResolver` 已经清掉该频道的 auth 缓存 ⇒ 下一次必然走全新 auth。
 */
function isAuthErr(msg: string): boolean {
  const m: string = msg.toLowerCase();
  /* StreamResolver.reqText 抛的「鉴权失效（HTTP 401/403…）」是首选判据；
   * 其余几条是它在业务层的等价表现（无 playurl / yspplayertoken 相关）。 */
  return m.indexOf('鉴权失效') >= 0 || m.indexOf('http 401') >= 0 || m.indexOf('http 403') >= 0 ||
    m.indexOf('无 playurl') >= 0 || m.indexOf('yspplayertoken') >= 0 || m.indexOf('登录态') >= 0;
}

/**
 * ★ 判断是否为"网络类"取流错误（用于自动重试 + 给用户中文提示）。
 *   真机见过的原文：`Failed to resolve the host name`、`Failed to connect to the server`、
 *   `timeout`、`Net`/`network` 相关文案；这些多为瞬时抖动，值得自动重试而不是直接报错。
 *
 * ⚠️ **鉴权类（401/403）不归这里**（见上面的 `isAuthErr`）：`reqText` 现在先把 4xx 抛成
 *   「鉴权失效（HTTP 401…）」，因此"网络无响应（…空响应）"这条只剩**非 4xx** 的真实空响应。
 */
function isNetErr(msg: string): boolean {
  const m: string = msg.toLowerCase();
  /* ★ 新增「网络无响应（…响应为空）」与「网络响应异常（非 JSON…）」两类
   *   —— 由 StreamResolver.reqText / jsonAsObj 抛出（切网瞬间 http 栈会给空 body，
   *   旧代码直接 JSON.parse ⇒ `Unexpected Text in JSON: Empty Text` 无法归类 ✗） */
  return m.indexOf('resolve the host') >= 0 || m.indexOf('failed to connect') >= 0 ||
    m.indexOf('timeout') >= 0 || m.indexOf('timed out') >= 0 || m.indexOf('network') >= 0 ||
    m.indexOf('socket') >= 0 || m.indexOf('unreachable') >= 0 || m.indexOf('econn') >= 0 ||
    m.indexOf('网络无响应') >= 0 || m.indexOf('网络响应异常') >= 0 || m.indexOf('http 0') >= 0 ||
    m.indexOf('network is down') >= 0 || m.indexOf('connection') >= 0;
}
