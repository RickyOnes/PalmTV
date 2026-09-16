/**
 * TvSession.ets —— 播控中心 / 锁屏的媒体会话（AVSession，2026-09-16 新增）
 *
 * 为什么需要：
 *   `module.json5` 早就声明了 `backgroundModes:["audioPlayback"]`、`KEEP_BACKGROUND_RUNNING`
 *   以及"后台音频模式保持 AVSession 活跃"，但**工程里一行 AVSession 代码都没有** ⇒
 *     ① 播控中心/锁屏没有媒体卡片，耳机与锁屏的播放/暂停按不动（用户实测"点不动"）；
 *     ② 声明了权限却没有对应能力，上架审核容易被问。
 *   ⇒ 本模块补上"应用侧唯一的媒体会话出口"，与 `media.AVPlayer` 的状态手工同步。
 *
 * 设计要点（2026-09-16 对齐原版 `D:\TV\CCTV\旧 ArkWeb 版`）：
 *   - **不新增任何权限**（AVSession 不需要权限）；只把已有声明用起来。
 *   - 封面 = **白底正方形 + alpha 混合**（原版同款做法，见 `buildSquareCover`）——
 *     直接把透明台标丢给系统会显得又小又脏。
 *   - **退后台/退出页面即 `destroy()`**：直播在后台拉流+解密不可靠，卡片留着只会出现
 *     "按了没反应"的失效按钮（原版注释："避免卡片一直显示、按钮无响应"）；回前台重建。
 *   - 会话**只创建一次**，换台只更新 metadata（title/assetId/封面，封面按频道缓存）；
 *   - 播放状态由 Index 在状态机里同步（playing/paused/stopped）；
 *   - 播控中心的 play/pause/stop/上一台/下一台 通过回调交给 Index 处理
 *     （**仅前台有效**，因为这正是卡片存在的时机）。
 *   - 全部失败都只告警：**播控能力缺失绝不能影响播放主链路**。
 */
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 播控中心命令 → 交给页面处理（页面才知道播放器与频道列表） */
export interface TvSessionHandlers {
  onPlay: () => void;
  onPause: () => void;
  onStop: () => void;
  onNextChannel: () => void;
  onPrevChannel: () => void;
}

export class TvSession {
  private static readonly TAG: string = 'PalmTV';
  /** 白底方形封面缓存上限（超过就释放最旧的，避免又攒一堆 PixelMap） */
  private static readonly COVER_MAX: number = 3;
  private session: AVSessionManager.AVSession | null = null;
  private ready: boolean = false;
  private handlers: TvSessionHandlers;
  /** 封面缓存（key = assetId = 频道 id） */
  private coverCache: Map<string, image.PixelMap> = new Map();
  private coverOrder: string[] = [];

  constructor(handlers: TvSessionHandlers) {
    this.handlers = handlers;
  }

  isReady(): boolean {
    return this.ready;
  }

  /** 创建并激活会话（幂等）。ctx 用 UIAbilityContext（同一 App 只允许一个同 tag 的会话）。 */
  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      const s: AVSessionManager.AVSession = await AVSessionManager.createAVSession(ctx, TvSession.TAG, 'video');
      /* 注册即表示"支持该命令"（不注册的按钮在播控中心是灰的） */
      s.on('play', () => {
        console.info('[TvSession] 播控中心 ⇒ play');
        this.handlers.onPlay();
      });
      s.on('pause', () => {
        console.info('[TvSession] 播控中心 ⇒ pause');
        this.handlers.onPause();
      });
      s.on('stop', () => {
        console.info('[TvSession] 播控中心 ⇒ stop');
        this.handlers.onStop();
      });
      s.on('playNext', () => {
        console.info('[TvSession] 播控中心 ⇒ 下一台');
        this.handlers.onNextChannel();
      });
      s.on('playPrevious', () => {
        console.info('[TvSession] 播控中心 ⇒ 上一台');
        this.handlers.onPrevChannel();
      });
      await s.activate();
      this.session = s;
      this.ready = true;
      console.info('[TvSession] AVSession 已创建并激活（播控中心 / 锁屏可见且可控制）');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] 创建/激活失败（不影响播放）: ${err.code} ${err.message}`);
    }
  }

  /**
   * ★★ 生成"白底正方形"封面（对齐原版 旧 ArkWeb 版 的做法）★★
   *
   * 为什么不能直接把台标 PixelMap 丢给系统：台标是**透明背景**的方形 logo，
   * 直接当 `mediaImage` 时系统会用透明底渲染 ⇒ 深色卡片上显得又小又脏（用户反馈"太难看"）。
   * 原版（`旧 ArkWeb 版/.../Index.ets:362-464`）的做法是：先读原图 RGBA，再按长边 ×1.1 建一张
   * **不透明白底正方形画布**，逐像素做 **alpha 混合**后放进去 ⇒ 播控中心/锁屏上就是
   * "白色方块 + 居中台标"，观感与官方一致。
   *
   * 只在源图**更大**的尺寸下工作（我们的台标已经在 `loadIcons` 里按显示像素夹过尺寸）。
   * 失败返回 null（调用方退回用原始台标，不影响功能）。
   */
  private async buildSquareCover(src: image.PixelMap): Promise<image.PixelMap | null> {
    try {
      const info: image.ImageInfo = await src.getImageInfo();
      const sw: number = info.size.width;
      const sh: number = info.size.height;
      if (sw <= 0 || sh <= 0) {
        return null;
      }
      const canvasSize: number = Math.max(64, Math.round(Math.max(sw, sh) * 1.1));  /* 1.1 = 留白边距（同原版） */
      const offX: number = Math.floor((canvasSize - sw) / 2);
      const offY: number = Math.floor((canvasSize - sh) / 2);

      /* 1) 读源图像素（RGBA_8888，4B/px —— 必须与解码时的像素格式一致） */
      const srcRowBytes: number = sw * 4;
      const srcBuf: ArrayBuffer = new ArrayBuffer(sh * srcRowBytes);
      const area: image.PositionArea = {
        pixels: srcBuf,
        offset: 0,
        stride: srcRowBytes,
        region: {
          size: { width: sw, height: sh } as image.Size,
          x: 0,
          y: 0
        }
      };
      await src.readPixels(area);
      const srcU8: Uint8Array = new Uint8Array(srcBuf);

      /* 2) 建白底不透明画布（全 255） */
      const dstRowBytes: number = canvasSize * 4;
      const dstU8: Uint8Array = new Uint8Array(canvasSize * dstRowBytes);
      dstU8.fill(255);

      /* 3) 逐像素 alpha 混合：透明像素与白底融合（关键：直接拷 RGBA 会留下半透明黑边） */
      for (let row = 0; row < sh; row++) {
        const sOff: number = row * srcRowBytes;
        const dOff: number = (offY + row) * dstRowBytes + offX * 4;
        for (let col = 0; col < sw; col++) {
          const s: number = sOff + col * 4;
          const d: number = dOff + col * 4;
          const a: number = srcU8[s + 3] / 255.0;
          dstU8[d] = Math.round(srcU8[s] * a + 255 * (1 - a));          /* R */
          dstU8[d + 1] = Math.round(srcU8[s + 1] * a + 255 * (1 - a));  /* G */
          dstU8[d + 2] = Math.round(srcU8[s + 2] * a + 255 * (1 - a));  /* B */
          dstU8[d + 3] = 255;                                           /* A = 不透明 */
        }
      }

      const opts: image.InitializationOptions = {
        size: { width: canvasSize, height: canvasSize } as image.Size,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      const cover: image.PixelMap = await image.createPixelMap(dstU8.buffer, opts);
      console.info(`[TvSession] 已生成白底方形封面 ${canvasSize}x${canvasSize}（源图 ${sw}x${sh}）`);
      return cover;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] 生成封面失败（改用原始台标）: ${err.message}`);
      return null;
    }
  }

  /** 取（必要时生成）封面：同一频道只合成一次，超出上限释放最旧的 */
  private async coverFor(assetId: string, icon: image.PixelMap | undefined): Promise<image.PixelMap | undefined> {
    const cached: image.PixelMap | undefined = this.coverCache.get(assetId);
    if (cached !== undefined) {
      return cached;
    }
    if (icon === undefined) {
      return undefined;
    }
    const cover: image.PixelMap | null = await this.buildSquareCover(icon);
    if (cover === null) {
      return undefined;   /* 合成失败：退回让调用方直接用原台标 */
    }
    this.coverCache.set(assetId, cover);
    this.coverOrder.push(assetId);
    while (this.coverOrder.length > TvSession.COVER_MAX) {
      const old: string = this.coverOrder.shift() as string;
      const pm: image.PixelMap | undefined = this.coverCache.get(old);
      this.coverCache.delete(old);
      if (pm !== undefined) {
        pm.release().catch((e: BusinessError) => {
          console.warn(`[TvSession] 释放旧封面失败（忽略）: ${e.message}`);
        });
      }
    }
    return cover;
  }

  /** 换台/起播时更新卡片信息；icon 传该频道台标（可能还没加载出来 ⇒ 允许 undefined） */
  async setChannel(title: string, assetId: string, icon: image.PixelMap | undefined): Promise<void> {
    const s: AVSessionManager.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    try {
      const md: AVSessionManager.AVMetadata = {
        assetId: assetId,
        title: title,
        artist: '掌上电视',
        album: '源站直播·直播流'
      };
      const cover: image.PixelMap | undefined = await this.coverFor(assetId, icon);
      if (cover !== undefined) {
        md.mediaImage = cover;              /* 白底方形封面（原版同款观感） */
      } else if (icon !== undefined) {
        md.mediaImage = icon;               /* 合成失败时的兜底 */
      }
      await s.setAVMetadata(md);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] setAVMetadata 失败（忽略）: ${err.message}`);
    }
  }

  /** 同步播放状态（播控中心的按钮显示/进度都靠它） */
  async setPlaying(playing: boolean): Promise<void> {
    const s: AVSessionManager.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    const st: AVSessionManager.AVPlaybackState = {
      state: playing
        ? AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY
        : AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1.0,
      /* 直播没有总时长 ⇒ duration 不设（设 -1 反而可能让卡片显示异常进度） */
      isFavorite: false
    };
    try {
      await s.setAVPlaybackState(st);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] setAVPlaybackState 失败（忽略）: ${err.message}`);
    }
  }

  /** 停止（如无选中频道/取流失败到底）：把卡片置为停止态，而不是留在"播放中" */
  async setStopped(): Promise<void> {
    const s: AVSessionManager.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    const st: AVSessionManager.AVPlaybackState = {
      state: AVSessionManager.PlaybackState.PLAYBACK_STATE_STOP,
      speed: 1.0
    };
    try {
      await s.setAVPlaybackState(st);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] setAVPlaybackState(stop) 失败（忽略）: ${err.message}`);
    }
  }

  /**
   * 销毁会话（**退后台**与**退出页面**都必须调）：
   *   直播流在后台/锁屏下"卡片可点但点了不生效"（取流+解密在后台不可靠）⇒ 原版的做法就是
   *   退后台即销毁卡片（`旧 ArkWeb 版` 注释原话："避免卡片一直显示、按钮无响应"）。
   *   回前台会重建（见 `Index.onPageShow` → `initTvSession`）。
   */
  async destroy(): Promise<void> {
    /* 封面缓存一并释放（PixelMap 是常驻内存的，不释放会越攒越多） */
    this.coverOrder.forEach((k: string) => {
      const pm: image.PixelMap | undefined = this.coverCache.get(k);
      if (pm !== undefined) {
        pm.release().catch((e: BusinessError) => {
          console.warn(`[TvSession] 释放封面失败（忽略）: ${e.message}`);
        });
      }
    });
    this.coverCache.clear();
    this.coverOrder = [];
    const s: AVSessionManager.AVSession | null = this.session;
    if (s === null) {
      return;
    }
    this.session = null;
    this.ready = false;
    try {
      await s.destroy();
      console.info('[TvSession] AVSession 已销毁');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[TvSession] destroy 失败（忽略）: ${err.message}`);
    }
  }
}
