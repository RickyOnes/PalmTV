/**
 * Log.ets —— 全工程统一的日志出口（2026-09-17 新增）
 *
 * 目的：**发布包里不留 info 级日志，只留 warn/error**；调试包里日志照旧全量。
 *
 * 为什么不用 ArkGuard 的 `-remove-log`：
 *   它是"全删"（连 `console.error` 一起删，且要求返回值未被使用），
 *   而我们的诉求是"保留 warn/error 便于线上定位" ⇒ 只能自己做一层按级别的封装。
 *
 * 实现：级别开关取自 **`BuildProfile.DEBUG`**（Hvigor 生成的编译期常量：
 *   debug 构建 = true，release 构建 = false，见 `entry/build/default/generated/profile/<mode>/BuildProfile.ets`）。
 *   ⚠️⚠️ 写注释时**绝不能出现"星号紧接斜杠"**（如通配路径 `profile/星/xxx` 那种写法）——
 *       它会**提前闭合块注释**，其后所有注释文本被当代码解析，整个文件语法崩掉：
 *       2026-09-17 就是这么踩的（本文件原第 11 行写了那个通配路径 ⇒ 全工程 54 个编译错误、
 *       debug/release 都构建失败，且 `read_lints` 报 0 error 完全没提示）。
 *   ArkTS 对 `static readonly` 常量会做常量折叠 ⇒ release 版里 `Log.i` 体是
 *   `if (false) {…}`，`console.info` 调用连同其**参数字符串**都会被摇掉。
 *
 * 用法（全工程已迁移完，禁止再直接调 console.*）：
 *   Log.i(`[Index] xxx ${v}`);   // 调试信息：release 不输出
 *   Log.w(`[Index] xxx 失败: ${e.message}`);   // 警告：release 保留
 *   Log.e(`[Index] xxx 异常: ${e.message}`);   // 错误：release 保留
 *
 * ⚠️ 两点纪律：
 *   1. **不要在 Log.i 里做重活**（如 `JSON.stringify(大对象)`）：release 下会被摇掉没问题，
 *      但 debug 下会拖慢热路径；热路径（每个分片）只打一行统计即可。
 *   2. native 侧日志（hilog tag `CMGDec`，由 `cmg_log()` 输出）**不受本开关控制**，
 *      需要静默时见 `cmg_napi.c` 的 `cmgSetQuiet()`（发布版由 App 调一次）。
 */
import BuildProfile from 'BuildProfile';

export class Log {
  /** debug 构建 = true；release = false（编译期常量，可被静态折叠） */
  static readonly verbose: boolean = BuildProfile.DEBUG;

  /** 调试信息：release 版不输出（连同参数字符串一起被摇掉） */
  static i(msg: string): void {
    if (Log.verbose) {
      console.info(msg);
    }
  }

  /** 警告：release 版保留（线上问题定位用） */
  static w(msg: string): void {
    console.warn(msg);
  }

  /** 错误：release 版保留 */
  static e(msg: string): void {
    console.error(msg);
  }
}
