/**
 * NativeSigner.ets —— 取流签名的**原生**实现（gate3）
 *
 * 对应 native：`native/src/ysp_keygen.c`（keygen_bg.wasm）+ `ysp_rjq.c`（RJq7sO71JF.wasm）
 * 两个 wasm 用 wabt wasm2c 转成 C 后随 libcmg_napi.so 一起编进应用 ⇒ **不再需要任何隐藏 Web/JS 兜底**。
 *
 * 与官方逐字符对拍（`tools/native_dec/_ysp_ref.cjs` 是 JS 参考实现，同一组固定输入）：
 *   TOKENRND  = 77ac34ef697788be1fa0ae2fd82cb8fc
 *   SIGNATURE = c3ec1b8748f073e735e8069996e3ddf6
 *   YSPTICKET = 5c40d99c…c6b1（124 hex，可复现）
 *
 * ★ 4 个签名函数**全部已原生化**，无任何 JS/Web 兜底：
 *   tokenRnd / yspTicket / signature → 两个 wasm（wasm2c 转 C）
 *   cKey                            → `ckey_core.ts`（纯计算，无 DOM/无网络）
 */
import cmgNapi from 'libcmg_napi.so';
import { WasmSigner } from './StreamResolver';
import { BusinessError } from '@kit.BasicServicesKit';
/** cKey：官方模块体（webpack fb15）已由脚本编译进应用，纯计算、无 DOM/无网络 */
import { ckeyCompute } from './ckey_core';

export class NativeSigner implements WasmSigner {
  private static inited: boolean = false;
  private static failed: boolean = false;
  private static err: string = '';

  /** 幂等初始化（装载 keygen_bg / RJq7sO71JF 两个 wasm 实例） */
  static ensureInit(): boolean {
    if (NativeSigner.inited) {
      return true;
    }
    if (NativeSigner.failed) {
      return false;
    }
    try {
      const r: number = cmgNapi.yspSignInit();
      if (r === 0) {
        NativeSigner.inited = true;
        console.info(`[YspSign] 原生签名器就绪: ${cmgNapi.yspSignVersion()}`);
        return true;
      }
      NativeSigner.failed = true;
      NativeSigner.err = cmgNapi.yspSignLastError();
      console.error(`[YspSign] 初始化失败 r=${r}: ${NativeSigner.err}`);
    } catch (e) {
      const err = e as BusinessError;
      NativeSigner.failed = true;
      NativeSigner.err = `${err.code} ${err.message}`;
      console.error(`[YspSign] 初始化异常: ${NativeSigner.err}`);
    }
    return false;
  }

  static isReady(): boolean {
    return NativeSigner.ensureInit();
  }

  static lastError(): string {
    return NativeSigner.err.length > 0 ? NativeSigner.err : cmgNapi.yspSignLastError();
  }

  async genTokenRnd(guid: string, token: string, tsMs: string): Promise<string> {
    NativeSigner.ensureInit();
    const v: string = cmgNapi.yspGenTokenRnd(guid, token, tsMs);
    if (v.length === 0) {
      throw new Error(`tokenRnd 生成失败: ${NativeSigner.lastError()}`);
    }
    return v;
  }

  /**
   * cKey ← 官方模块体（webpack fb15）**编译进应用**（`common/ckey_core.ts`，脚本生成）。
   *
   * 为什么不是 native C：
   *   实测该模块里**没有** AES/MD5/CryptoJS/Base64 任何字面量（连前缀 `--01` 都是运行时拼的），
   *   是一段混淆过的自制实现；逆成 C 要数小时~数天，而它本身是**纯计算**（无 DOM、无 eval、无网络，
   *   只读 URL/UA/referrer 三个常量）⇒ 原样编译进应用是与官方等价的稳妥做法。
   *   已用黄金向量验证：同输入 → `--018B524144FCDC…`（324 字符），`MATCH_GOLD=1`、可复现、对 tsSec 敏感。
   *   三个 wasm 签名（tokenRnd/signature/yspticket）**仍是 native**。
   */
  async genCKey(cnlId: string, tsSec: string, appVer: string, guid: string,
    platform: string, docUrl: string): Promise<string> {
    try {
      const v: string = ckeyCompute(cnlId, tsSec, appVer, guid, platform, docUrl);
      if (v.length === 0) {
        throw new Error('cKey 结果为空');
      }
      return v;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[YspSign] cKey 计算失败: ${err.message}`);
      throw new Error(`cKey 计算失败: ${err.message}`);
    }
  }

  async genYspTicket(pid: string, authTs: string, cnlId: string, guid: string,
    yspAppId: string, appVer: string): Promise<string> {
    NativeSigner.ensureInit();
    const v: string = cmgNapi.yspGenYspTicket(pid, authTs, cnlId, guid, yspAppId, appVer);
    if (v.length === 0) {
      throw new Error(`yspticket 生成失败: ${NativeSigner.lastError()}`);
    }
    return v;
  }

  async genSignature(pid: string, guid: string, seqId: string, reqId: string,
    sessionToken: string, tsMs: string, yspSdkInput: string): Promise<string> {
    NativeSigner.ensureInit();
    const v: string = cmgNapi.yspGenSignature(pid, guid, seqId, reqId, sessionToken, tsMs, yspSdkInput);
    if (v.length === 0) {
      throw new Error(`signature 生成失败: ${NativeSigner.lastError()}`);
    }
    return v;
  }
}
