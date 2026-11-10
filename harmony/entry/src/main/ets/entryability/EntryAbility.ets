import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Log } from '../common/Log';

/**
 * EntryAbility - 掌上电视 主 Ability
 *
 * 职责：
 *  - 管理应用生命周期（前台/后台），通过 eventHub 通知页面（tvpForeground/tvpBackground）
 *  - 播控中心/音频焦点都由**页面侧**负责（`common/TvSession.ets` = AVSession 卡片、
 *    `common/AudioFocus.ets` = AudioSession 焦点）；本 Ability 只保证进程与
 *    `backgroundModes.audioPlayback` 声明生效（对齐原版 CctvPoC 的分工）。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      Log.e(`[Ability] setColorMode 失败: ${JSON.stringify(err)}`);
    }
    Log.i('[Ability] onCreate');
  }

  onDestroy(): void {
    Log.i('[Ability] onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    Log.i('[Ability] onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Log.e(`[Ability] 加载 pages/Index 失败: ${JSON.stringify(err)}`);
        return;
      }
      Log.i('[Ability] pages/Index 加载完成');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    Log.i('[Ability] onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    Log.i('[Ability] onForeground');
    // ★ 直播≠音乐：后台已暂停并隐藏媒体卡；回前台由 Index.ets 决定「短离续播」还是
    //   「超过10s 重新鉴权起播」。通过 EventHub 通知页面（同一 UIAbilityContext）。
    try {
      this.context.eventHub.emit('tvpForeground');
    } catch (err) {
      Log.e(`[Ability] emit tvpForeground 失败: ${JSON.stringify(err)}`);
    }
  }

  onBackground(): void {
    // Ability has back to background
    Log.i('[Ability] onBackground');
    // ★ 直播流时效性极强，后台继续拉流毫无意义（m3u8/TS 会过期）：
    //   退后台 → 通知 Index.ets 执行"暂停 + 停止下载/解密 + **销毁媒体卡** + 归还音频焦点"，
    //   回前台再重建卡片（离开 <10s 续播，≥10s 重新鉴权取流）。
    //   ★ 2026-09-16 定稿（对齐原版 CctvPoC）：**后台不留卡片** —— 直播在后台"卡片在、按了没反应"
    //   是必然的（取流 + 解密在后台都不可靠），原版注释原话即"避免卡片一直显示、按钮无响应"。
    //   `backgroundModes.audioPlayback` + `KEEP_BACKGROUND_RUNNING` 保留仅用于防止进程被秒杀（原版亦如此）。
    try {
      this.context.eventHub.emit('tvpBackground');
    } catch (err) {
      Log.e(`[Ability] emit tvpBackground 失败: ${JSON.stringify(err)}`);
    }
  }
}