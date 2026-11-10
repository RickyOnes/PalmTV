using System;
using System.Runtime.InteropServices;
using System.Text;

namespace PalmTVDesktop;

/// <summary>
/// 原生核（<c>PalmTVCore.dll</c>）门面 —— **2026-11-05 起只剩两件事**：
///
/// | 导出 | 用途 |
/// |---|---|
/// | <c>ysp_self_gen_ckey</c> | **安卓格式** cKey（`--01` + base64url），给 <see cref="YspAndroidLive"/> 取流 |
/// | <c>jstv_sign_query</c> | 江苏荔枝 `txSecret`（给 <see cref="JstvLive"/> 拼上游地址） |
///
/// **已移除的两大块**（别再往里加）：
///   · CMG 解密核（`cmg_rt_*`）—— 桌面改 sm4c，见 <see cref="Sm4C"/>；
///   · PC 格式签名/票据（`ysp_gen_ckey` / `ysp_gen_yspticket` / `ysp_gen_signature` / `ysp_gen_token_rnd`）——
///     它们只服务 Web/PC 取流链（auth → open-token → get_live_info），那条链已整体删除；
///     桌面只做**直播 / 时移 / 回看**，没有点播，用不到 PC 票据。
///
/// ⚠️ 改 DLL 接口时先看 `common/build/build-palmtv-core.ps1` 的源清单。
/// </summary>
internal static class PalmTVCore
{
    const string Dll = "PalmTVCore.dll";

    /// <summary>最近一次原生调用失败的原因（日志用）。</summary>
    internal static string LastSignError { get; private set; } = "";

    // ==================================================================
    // 1) 安卓格式 cKey（自研，与 Android 的 libpalmtv.so 同一份源）
    // ==================================================================

    const int CkeyCap = 1024;   // 安卓 cKey 实测 682 字符，留足

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int ysp_self_gen_ckey(
        byte[] outBuf, int cap, long tsSec,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string cnlid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string guid);

    /// <summary>
    /// 生成**安卓格式** cKey（供 <see cref="YspAndroidLive"/> 取流）。
    /// </summary>
    /// <param name="cnlid">频道 cnlId（进载荷，服务端会核）</param>
    /// <param name="tsSec">秒级时间戳；**必须与请求参数 `fntick` 同一秒**</param>
    /// <param name="guid">设备标识；**必须与请求参数 `guid` 完全一致**（服务端交叉校验载荷内那份）</param>
    internal static string? GenCKeyAndroid(string cnlid, long tsSec, string guid)
    {
        try
        {
            var b = new byte[CkeyCap];
            int n = ysp_self_gen_ckey(b, b.Length, tsSec, cnlid, guid);
            if (n <= 0) { LastSignError = $"ysp_self_gen_ckey rc={n}"; return null; }
            int z = Array.IndexOf(b, (byte)0);
            if (z < 0) z = b.Length;
            return z == 0 ? null : Encoding.ASCII.GetString(b, 0, z);
        }
        catch (Exception ex)
        {
            LastSignError = ex.Message;
            return null;
        }
    }

    // ==================================================================
    // 2) 江苏荔枝 txSecret 签名
    // ==================================================================

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int jstv_sign_query(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string streamId,
        long unixSec, byte[] outBuf, UIntPtr outCap);

    /// <summary>
    /// 生成江苏台的 `txSecret=...&txTime=...` 查询串（直接拼在上游 m3u8 地址后）。
    /// ★ 2026-11-05：桌面去掉 `proxy.exe` 后，这条由 C# 现算（原来在 Go 代理里算）。
    /// ⚠️ 密钥与 `common/native/src/jstv_sign.c` 同源；官方轮换时两端一起改。
    /// </summary>
    internal static string? JstvSignQuery(string streamId, long unixSec)
    {
        try
        {
            var b = new byte[256];
            int rc = jstv_sign_query(streamId, unixSec, b, (UIntPtr)b.Length);
            if (rc != 0)
            {
                LastSignError = $"jstv_sign_query rc={rc}";
                return null;
            }
            int z = Array.IndexOf(b, (byte)0);
            if (z < 0) z = b.Length;
            return z == 0 ? null : Encoding.ASCII.GetString(b, 0, z);
        }
        catch (Exception ex)
        {
            LastSignError = ex.Message;
            return null;
        }
    }
}
