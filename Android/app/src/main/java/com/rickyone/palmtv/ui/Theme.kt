package com.rickyone.palmtv.ui

import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle

/** 配色（与鸿蒙 `Index.ets` 同一套值，逐条对应） */
object Palette {
    val Bg = Color(0xFF0A0A0A)          // 页面底
    val ChannelBg = Color(0xFF0D0D0D)   // 频道区
    val StatusBg = Color(0xFF101010)    // 状态栏
    val EpgStripBg = Color(0xFF181818)  // EPG 条
    val CardBg = Color(0xFF1E1E1E)      // EPG 弹层
    val DisclaimerBg = Color(0xFF161616)
    val TabTrack = Color(0xFF262626)    // 分段控件轨道
    val Primary = Color(0xFF2F6BFF)     // 主蓝（滑块/链接）
    val OnAirRed = Color(0xFFFF3B3B)    // 当前台 / 选中边框
    val NowRed = Color(0xFFFF4444)      // 正在播出
    val NextGreen = Color(0xFF3DDC84)   // 播放灯 / 接下来
    /* ★ 2026-11-10：节目单"当前选中的日期 TAB 但不是正在看的那天"用紫色（与红/绿都区分得开，
     *   深色底上可读）。三端同值：鸿蒙 `#a78bfa`、桌面 `#A78BFA`。 */
    val SelPurple = Color(0xFFA78BFA)
    val TextDim = Color(0xFF888888)
    val TextMid = Color(0xFFA8A8A8)
    val TextBright = Color(0xFFE0E0E0)
    val BorderIdle = Color(0xFF3A3A3A)
    val UnselectedTabText = Color(0xFFA8A8A8)
    val WechatGreen = Color(0xFF07C160)
    val HuaweiRed = Color(0xFFCF0A2C)
    val LinkBlue = Color(0xFF8AB4FF)
}

@Composable
fun PalmTvTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            background = Palette.Bg,
            surface = Palette.CardBg,
            primary = Palette.Primary,
            onBackground = Palette.TextBright,
            onSurface = Palette.TextBright
        ),
        content = {
            // ★★ 2026-10-01（用户实测："节目条/状态栏明显比鸿蒙高"）★★
            //   Material3 的 `LocalTextStyle` 默认 **`includeFontPadding = true`** —— Android 字体自带上下留白，
            //   而鸿蒙文字没有这份留白 ⇒ 同样字号的文字在安卓侧一定更高（每行多 3~5dp）。
            //   这里**全局**关掉它（本项目所有 `Text` 都显式传了 fontSize/color，不受影响）。
            //   另外：不覆盖 lineHeight ⇒ 未显式指定的文本用字体自然行高，也比 Material3 默认的
            //   `bodyLarge: lineHeight 24sp` 更接近鸿蒙（需要精确对齐的地方再单独给 lineHeight）。
            CompositionLocalProvider(
                LocalTextStyle provides TextStyle(
                    platformStyle = PlatformTextStyle(includeFontPadding = false)
                )
            ) { content() }
        }
    )
}
