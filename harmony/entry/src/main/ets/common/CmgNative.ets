/**
 * CmgNative.ets —— CMG 解密 N-API 模块的 ArkTS 封装（方案 B：native 解密 + AVPlayer）
 *
 * 对应 native 源码：D:\TV\hmnative\native\（gate1，桌面验收 MATCH 57/57）
 * 编译产物：libcmg_napi.so（由 entry/src/main/cpp/CMakeLists.txt 引用 hmnative/native 生成）
 *
 * ★ 三条必须遵守（否则解密静默失效）：
 *   1. url 必须是**完整 43 字符 activeURL**（种子三要素之一）
 *   2. 首帧必须先跑前缀序列再解密，后续帧只解密 —— 由 native 侧 firstPending 自动处理
 *   3. **必须用真实墙钟**（`setClockReal()`，直播必需）：虚拟钟对实时流会解错字节 ⇒ 大面积马赛克。
 *      （历史上"日志会改变时序导致 ma 提前返回"的结论属于虚拟钟时代，现用真实钟 + 逐帧自愈，
 *       日志只影响耗时、不影响结果；但仍不要在**每帧**级别打印，避免无谓开销。）
 *
 * 诊断指纹：stat().lastMaPcs 正常在 5 万 ~ 200 万；**恒为 2094 ⇒ 该帧解密未生效**（只会是末帧）。
 */
import cmgNapi from 'libcmg_napi.so';
import type { CmgStat } from 'libcmg_napi.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** CMG 解密入口签名常量（官方导航 URL，是密钥派生的一部分，**禁止**改成 127.0.0.1） */
export const CMG_ACTIVE_URL = 'https://yangshipin.cn/tv/home?pid=600001859';

export class CmgNative {
  private static inited: boolean = false;
  private static initErr: string = '';

  /**
   * 初始化（会从 assetsDir 读 eb_prog.bin / reloc_table.bin / CMGPlayer.json）
   * @returns 0 成功
   */
  static init(tag: string, url: string, assetsDir: string): number {
    if (CmgNative.inited) {
      return 0;
    }
    const r: number = cmgNapi.cmgInit(tag, url, assetsDir);
    if (r === 0) {
      CmgNative.inited = true;
      console.info(`[CmgNative] init ok, version=${cmgNapi.cmgVersion()}`);
    } else {
      CmgNative.initErr = cmgNapi.cmgLastError();
      console.error(`[CmgNative] init 失败 r=${r}: ${CmgNative.initErr}`);
    }
    return r;
  }

  /**
   * ★ 诊断抓取（临时开启，排查"大面积马赛克"用）：滚动保留最近 ring 片的**密文+明文+元信息**
   * 到 `filesDir/cmgcap/`（`cap_<k>_in.ts` / `cap_<k>_out.ts` / `cap_<k>.txt`）。
   *
   * 为什么需要：桌面已用 `fc /b` 证明"提取+解密+回写"与官方**逐字节一致**，真机各项计数也全 0，
   * 但仍有马赛克 ⇒ 唯一没做过的对照是"**设备实际解出来的字节** vs **官方解同一份密文**"。
   * 拿到 `cap_*_in.ts` 后，在 PC 上用 `reference/gold3_trace.cjs` 解它，再与 `cap_*_out.ts`
   * 逐字节 `fc /b`，即可一次性给出确定答案。
   *
   * 排查完把调用处的 ring 设为 0 即可关闭（省 IO）。
   */
  /**
   * ★★★ 时钟模式：**直播必须用真实墙钟**（与官方 `Date.now()` 行为一致）★★★
   *
   * 实测证据（真机抓取的直播分片 + 官方 gold 逐帧逐字节对拍）：
   *   - 真实时钟：我们与官方 **0 字节差异**（完全一致）
   *   - 原默认的"确定性虚拟钟"（起点 1788873740818、每调用 +3ms，取值是为 2026-09-08 那批
   *     fixture 调出来的）⇒ 首帧(IDR) 与官方 **差 1464 字节**
   * ⇒ 原因：CMG 的密钥流**依赖时间**，官方用真实墙钟；虚拟钟对**当前**的直播流是错的时间，
   *   于是每个 GOP 里必然有若干字节解错 ⇒ 解码器出错 ⇒ **大面积马赛克**。
   * （历史结论"真实时钟会走 decoy"是在资产还错 + fixture 是旧流的条件下得到的，对实时流不成立。）
   */
  static setClockReal(): void {
    try {
      cmgNapi.cmgSetClockMode(1);
      console.info('[CmgNative] 时钟模式 = 真实墙钟（直播必需，与官方一致）');
    } catch (e) {
      console.warn(`[CmgNative] cmgSetClockMode 失败: ${(e as BusinessError).message}`);
    }
  }

  /**
   * ★ 服务器时间对齐（**当前未启用**，保留 native 能力与说明）
   *
   * 官方页面确实持续请求 `csapi.yangshipin.cn/voapi/omsot/serverTime`，native 侧
   * `cmgSetServerTime(ms)` 也仍然可用（±1 天保护）。但实测该接口返回的是**二进制**响应、
   * 拿不到 13/10 位时间戳（日志一直是"没找到时间戳"⇒ 回落本机钟），而
   * `setClockReal()` 的真实墙钟已与官方 gold **逐字节一致**（开发笔记 §7 末尾、§11）
   * ⇒ 本轮按"少一次无用的网络往返"处理：**不调用**。
   * 若将来设备时间不可信的机型出现马赛克，这里就是第一个要打开的实验开关：
   *   解析出 ms 后 `cmgNapi.cmgSetServerTime(ms)`。
   */


  static async enableCapture(ctx: common.UIAbilityContext, ring: number): Promise<string> {
    const dir: string = ctx.filesDir + '/cmgcap';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      // 已存在即可
    }
    try {
      cmgNapi.cmgSetCapture(dir, ring);
    } catch (e) {
      console.warn(`[CmgNative] cmgSetCapture 失败: ${(e as BusinessError).message}`);
    }
    console.info(`[CmgNative] 分片抓取: ${dir} ring=${ring}`);
    return dir;
  }

  static isInited(): boolean {
    return CmgNative.inited;
  }

  static lastInitError(): string {
    return CmgNative.initErr;
  }

  /** 解密串行队列尾（保证"进入 native 的顺序 == 调用顺序"，与旧的同步语义一致） */
  private static decTail: Promise<void> = Promise.resolve();

  /**
   * ★★ 原地解密一整段 TS —— **异步版**（App 现行唯一解密入口）★★
   *
   * 为什么异步（2026-09-16）：native 侧 `cmgDecryptTs` 是同步调用，单分片 0.3~0.7s，
   * 期间 **JS 线程完全停摆**：UI 不重绘、本地 HTTP 服务不收发、AVPlayer 的分片请求排队
   * （历史日志里"预热解密把播放器首片堵住 1.2s"就是它）。
   * 现在改走 `cmgDecryptTsAsync`（N-API work 线程 + native 内部单锁串行）：
   *   - **语义不变**：CMG 会话有状态，native 用互斥锁把解密串起来；
   *   - 这里再串一层 JS 队列，保证**调用顺序**（下载并发到达时的顺序）可预测；
   *   - 起播总耗时不变（临界路径的解密总量不变），但**不再有周期性卡顿**。
   *
   * @param buf ArrayBuffer（**原地修改**，长度不变；Promise 落地前不要复用这个缓冲）
   * @returns 已解密 NALU 数，<0 失败
   */
  static decryptTsAsync(buf: ArrayBuffer): Promise<number> {
    const run = (): Promise<number> => {
      if (!CmgNative.inited) {
        return Promise.resolve(-1);
      }
      return cmgNapi.cmgDecryptTsAsync(buf);
    };
    const p: Promise<number> = CmgNative.decTail.then(run, run);
    /* 队列尾吞掉异常：一次失败不能卡死后续所有解密 */
    CmgNative.decTail = p.then((): void => { }, (): void => { });
    return p;
  }

  static stat(): CmgStat {
    return cmgNapi.cmgGetStat();
  }

  /**
   * 把 rawfile 里的三件解密资产落到沙箱目录，返回该目录路径。
   *
   * ⚠️ 必须在 `init()` 之前调用；三件缺一不可（eb_prog.bin / reloc_table.bin / CMGPlayer.json）。
   */
  static async prepareAssets(ctx: common.UIAbilityContext, subDir: string = 'cmg_assets'): Promise<string> {
    const dir: string = ctx.filesDir + '/' + subDir;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      console.warn(`[CmgNative] mkdirSync 失败（可能已存在）: ${(e as BusinessError).message}`);
    }
    const files: string[] = ['eb_prog.bin', 'reloc_table.bin', 'CMGPlayer.json'];
    for (const name of files) {
      // ★★ 必须**每次覆盖**，不要"存在就跳过" ★★
      //   踩过的坑：rawfile 里的 eb_prog.bin 曾经是「已重定位」的错误版本，
      //   修好资产后重装，设备沙箱 files/cmg_assets/eb_prog.bin 里的旧文件仍在，
      //   而这里是 `if (exists) continue` ⇒ 新资产永远不生效，真机表现一直是
      //   native 初始化阶段越界 trap，白白多排查一轮。
      //   三件资产合计仅 ~420KB，每次覆盖成本可忽略。
      const dst: string = dir + '/' + name;
      // eb_prog.bin / reloc_table.bin 在 rawfile/sapi_cache 下，CMGPlayer.json 在 rawfile 根
      const rfPath: string = (name === 'CMGPlayer.json') ? name : ('sapi_cache/' + name);
      await CmgNative.copyRawfile(ctx, rfPath, dst);
    }
    console.info(`[CmgNative] 资产就绪: ${dir}`);
    return dir;
  }

  private static async copyRawfile(ctx: common.UIAbilityContext, rawName: string, dstPath: string): Promise<void> {
    const data: Uint8Array = await ctx.resourceManager.getRawFileContent(rawName);
    const file = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer as ArrayBuffer);
      console.info(`[CmgNative] 已落盘 ${rawName} -> ${dstPath} (${data.length} B)`);
    } catch (e) {
      console.error(`[CmgNative] 写入失败 ${dstPath}: ${(e as BusinessError).message}`);
      throw e as Error;
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 忽略关闭异常
      }
    }
  }
}
