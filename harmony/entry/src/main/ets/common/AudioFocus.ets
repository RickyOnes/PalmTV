/**
 * AudioFocus.ets —— 应用音频会话（焦点）管理（2026-09-16 新增，对齐原版 旧 ArkWeb 版 的口径）
 *
 * 原版（`D:\TV\CCTV\旧 ArkWeb 版\...\pages\Index.ets:225-271`）的做法与结论：
 *   「无论静音还是有声播放，都必须使用 **CONCURRENCY_MIX_WITH_OTHERS（share）** 策略，
 *     与其他应用音频混合播放；**绝不使用 PAUSE/STOP 独占策略**打断其他音频」
 *   —— 这是官方审核口径（音频独占会打断别人播放）。
 *
 * 本模块就做这三件事：
 *   1) `init()`     拿 `AudioSessionManager` 并监听"会话被系统停用"（`audioSessionDeactivated`）；
 *   2) `activate()` 起播/回前台时激活会话（**恒为 SHARE/MIX，不独占**）；
 *   3) `deactivate()` 退后台/退出页面时归还焦点（让其它应用恢复）。
 *
 * ⚠️ 与 AVSession 是两回事：
 *   - **AudioSession** = 音频焦点（能否出声、会不会打断别人）；
 *   - **AVSession**   = 播控中心/锁屏的媒体卡片（展示与控制）。
 *   原版注释也明确："AVSession 只负责播控中心展示，不参与音频焦点"。
 *
 * 来电/其它应用抢占的**逐事件**处理在 AVPlayer 侧（`media.AVPlayer.on('audioInterrupt')` +
 * `audioInterruptMode = SHARE_MODE`），见 `Index.ets` 的 `setupPlayer`；
 * 这里只兜"整会话被系统停用"这种粗粒度的情况。
 */
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class AudioFocus {
  private mgr: audio.AudioSessionManager | null = null;
  private active: boolean = false;
  private bound: boolean = false;
  /** 会话被系统停用时回调（页面据此暂停播放；不自动恢复） */
  private onDeactivated: (reason: string) => void;

  constructor(onDeactivated: (reason: string) => void) {
    this.onDeactivated = onDeactivated;
  }

  isActive(): boolean {
    return this.active;
  }

  /** 初始化（幂等）：拿管理器 + 监听"会话被停用" */
  init(): void {
    if (this.bound) {
      return;
    }
    try {
      this.mgr = audio.getAudioManager().getSessionManager();
      this.mgr.on('audioSessionDeactivated', (e: audio.AudioSessionDeactivatedEvent) => {
        const reason: string = `${e.reason}`;
        this.active = false;
        console.warn(`[AudioFocus] 音频会话被系统停用（reason=${reason}）⇒ 通知页面暂停`);
        this.onDeactivated(reason);
      });
      this.bound = true;
      console.info('[AudioFocus] AudioSessionManager 就绪');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[AudioFocus] 初始化失败（不影响播放）: ${err.code} ${err.message}`);
    }
  }

  /**
   * 激活会话：**恒为 SHARE/MIX**（合规：不独占、不打断其它应用）。
   * 起播前与"回前台"时调用；重复调用无害（幂等）。
   */
  activate(): void {
    if (this.mgr === null) {
      this.init();
    }
    const m: audio.AudioSessionManager | null = this.mgr;
    if (m === null || this.active) {
      return;
    }
    const strategy: audio.AudioSessionStrategy = {
      concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
    };
    m.activateAudioSession(strategy).then(() => {
      this.active = true;
      console.info('[AudioFocus] 已激活音频会话（SHARE/MIX，不独占）');
    }).catch((e: BusinessError) => {
      console.warn(`[AudioFocus] 激活失败（不影响播放）: ${e.code} ${e.message}`);
    });
  }

  /** 归还音频焦点（退后台 / 退出页面）：让其它应用恢复正常输出 */
  deactivate(): void {
    const m: audio.AudioSessionManager | null = this.mgr;
    if (m === null || !this.active) {
      return;
    }
    this.active = false;
    m.deactivateAudioSession().then(() => {
      console.info('[AudioFocus] 已停用音频会话（焦点已归还）');
    }).catch((e: BusinessError) => {
      console.warn(`[AudioFocus] 停用失败（忽略）: ${e.code} ${e.message}`);
    });
  }
}
