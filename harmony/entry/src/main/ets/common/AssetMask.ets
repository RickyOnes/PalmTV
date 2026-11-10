/**
 * AssetMask.ets —— rawfile 里"去明文"资产的 XOR 掩码（**对称**：编码/解码同一函数）
 *
 * 背景：`resources/rawfile/**` 会**原样打进 HAP**（且不压缩）—— 明文文件名 + 明文内容
 * 等于把"我们用了什么资产"摊开给解包者看。现在 rawfile 里放的是 XOR 后的 `.dat`
 * （台标包 `logos.dat` 内的 `lNN` 条目），读取时用本函数解回。
 *
 * ⚠️ 诚实定位：**这不是加密级保护**（密钥就在 .abc 里），只挡住"随手翻包 / strings 快筛"。
 * ⚠️ 密钥必须与打包工具里的 KEY 逐字节一致（`tools/hide_assets.cjs` / `.codebuddy/tmp/mask_logos.cjs`）。
 *
 * 2026-11-07：从已删除的 `CmgNative.ets` 搬出来（它只剩这一个用途，而 CMG 链路已移除）。
 */

/** 掩码密钥（必须与打包工具一致；对照脚本也用它） */
export const MASK_KEY: string = 'PalmTV-rs-2026';

/** 原地 XOR 掩码（返回同一个 Uint8Array，便于链式调用） */
export function unmask(data: Uint8Array): Uint8Array {
  const k: string = MASK_KEY;
  for (let i = 0; i < data.length; i++) {
    data[i] = data[i] ^ (k.charCodeAt(i % k.length) & 0xff);
  }
  return data;
}
