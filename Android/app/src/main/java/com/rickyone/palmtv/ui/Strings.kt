package com.rickyone.palmtv.ui

/**
 * 全部用户可见文案 —— **逐字**照抄鸿蒙 `pages/Index.ets`（三端文案必须一致）。
 * 改这里就必须同时改桌面 `windows/MainWindow.xaml.cs` 与鸿蒙 `Index.ets`。
 */
object Strings {

    // ---------- 状态栏 ----------
    const val BOOT_INIT = "正在初始化…"
    /** ★ 2026-10-01：启动完成后的待机文案（与鸿蒙 `bootSequence` 末尾的 `bootMsg = '就绪'` 一致）。
     *  ⚠️ 定义早已有，但**一直没人用** ⇒ App 起来后状态栏停在"正在初始化…"（用户实测指出）。
     *     现在 `MainViewModel.init` 会按 native 是否就绪写它（或写失败原因）。 */
    const val READY = "就绪"
    const val NO_CHANNEL = "未选择频道"
    fun gettingUrl(name: String) = "$name 正在获取播放地址…"
    fun phaseAuth(name: String) = "$name 鉴权中…"
    fun phaseSign(name: String) = "$name 签名中…"
    fun phaseToken(name: String) = "$name 换取会话…"
    fun phaseLive(name: String) = "$name 取流中…"
    fun buffering(name: String) = "$name 正在缓冲…"
    fun retryAuth(name: String, n: Int) = "$name 登录态过期，正在重新鉴权（$n/3）…"
    fun retryNet(name: String, n: Int) = "$name 网络信号差，正在重试（$n/3）…"
    fun retryOther(name: String, n: Int) = "$name 取流异常，正在重试（$n/3）…"
    fun noSignal(name: String) = "$name 暂无直播信号"
    fun authLater(name: String) = "$name 登录态异常，稍后自动重试…"
    fun fetchFailed(name: String, msg: String) = "$name 取流失败：$msg"
    fun playingOf(name: String) = "$name 播放中"
    fun netUnavailable(name: String) = "$name 网络不可用，请检查网络后重新点击频道"
    fun netResume(name: String, sec: Int, n: Int) = "$name 网络异常，${sec}s 后自动重试（$n/24）"
    fun playErrGiveUp(name: String) = "$name 播放异常，请换台或重开应用"
    fun waitingNet(name: String) = "$name 网络异常，正在等待网络恢复…"
    fun recovering(name: String, n: Int) = "$name 播放异常，正在恢复（$n/3）…"
    fun interrupted(name: String) = "$name 播放中断"
    fun reconnecting(name: String) = "$name 信号中断，正在重连…"
    fun audioTaken(name: String) = "$name 被其他应用中断，稍后自动恢复"
    fun resuming(name: String) = "$name 正在恢复…"
    fun initFailed(name: String) = "$name 播放器初始化失败"
    fun nativeInitFailed(err: String) = "native 初始化失败: $err"
    const val NO_CONTEXT = "无法获取 UIAbilityContext"

    // ---------- 中央浮层 ----------
    // ★★ 2026-10-01（用户要求统一）★★ "没源"的提示合并为**同一句**：
    //   · 有原台可退 ⇒ [fallbackTo]："xxx 无信号，已切回 yyy"
    //   · 没有可退的原台 ⇒ [noSignalClick]："xxx 暂无信号，请点击其他频道"
    //   原先的三套文案（`源无响应` / `应版权方要求，暂停提供直播信号，请点击其他频道观看` /
    //   `源无响应，请点击其他频道`）**已删除** —— 现在 IPTV 预检失败、CCTV-10 的"版权停播"、
    //   直连台播放器报错，全都说上面这两句之一（由 `MainViewModel.revertWithNotice()` 统一发出）。
    //   超时秒数 / 错误详情 / 版权原因一律进日志（浮层只留结论，2 秒自消）。
    //   ⚠️ 三端同步：鸿蒙 `Index.ets` 的 `noticeNoSignal()`；桌面端同名文案。
    const val NET_BAD_RETRYING = "网络信号差，暂时无法播放，正在自动重试…"
    fun fallbackTo(failed: String, back: String) = "$failed 无信号，已切回 $back"
    fun noSignalClick(name: String) = "$name 暂无信号，请点击其他频道"
    /** ★★ 2026-10-02（与鸿蒙同步修："无信号回退原台时条幅认错台"）★★
     *  "没有原台可退、且失败的台**不是用户点的**"（是自动回退/自动重取拉起来的原台）时的口径：
     *  不提台名、也不说"请点击其他频道"（那是在告诉用户"你选的那个台没信号"，可他没选它）。
     *  ⚠️ 三端同文案：鸿蒙 `noticeNoSignal()` 的中性分支、桌面 `StatusText` 的"{x} 无信号；按「播放」可重试"。 */
    const val INTERRUPTED_RETRY = "信号中断，正在自动重试…"
    const val PLAYER_UNRECOVERABLE = "播放器异常，无法自动恢复，请换台或重新打开应用"

    // ---------- EPG ----------
    const val EPG_DASH = "-"
    const val EPG_NONE = "暂无节目单"

    /** ★ 2026-10-07：节目单里**已播完**节目右侧的小标 —— 点它即回看 */
    const val REPLAY = "回看"
    /** ★ 2026-10-21：回看被服务端拒绝时的提示（超出回看窗口 / 该频道不支持回看） */
    /** ★ 2026-10-22（用户要求）：**只显示时移秒数，用正负号区分方向**。
     *  例：`时移 +125 秒`（在基准之后）/ `时移 -30 秒`（在基准之前）。 */
    fun timeshiftSigned(sec: Int): String = "时移 " + (if (sec >= 0) "+$sec" else "$sec") + " 秒"

    /** ★ 2026-10-22（用户要求）：**回看时按"节目内位置"显示**，而不是"离直播沿多远"。
     *  例：`12:30 / 45:00`。看 8 小时前的节目若按直播沿算会显示"时移 478 分"，毫无意义。 */
    fun posHint(posSec: Int, durSec: Int): String {
        fun mmss(t: Int): String {
            val v = t.coerceAtLeast(0)
            return "%02d:%02d".format(v / 60, v % 60)
        }
        return if (durSec > 0) "${mmss(posSec)} / ${mmss(durSec)}" else mmss(posSec)
    }

    /** ★ 2026-10-22：左右滑动时移的 OSD 提示（与音量/亮度浮层同款）
     *  sec = 相对直播沿的累计偏移：0 ⇒ 直播；>0 ⇒ 落后多少秒 */
    fun timeshiftHint(sec: Int): String = when {
        sec <= 0 -> "直播"
        sec < 60 -> "时移 ${sec} 秒"
        else -> "时移 ${sec / 60} 分 ${sec % 60} 秒"
    }

    /** ★ 2026-10-22：节目单里的状态标签（用户要求：回看中用红粗字，直播中用"直播中"） */
    const val EPG_IN_REPLAY = "回看中"
    const val EPG_LIVE_NOW = "直播中"
    /** ★ 2026-11-10（用户要求）：**回看/时移期间**，正在直播那档的标签改为「直播」（绿字），
     *   与「回看中」区分——你已经不在看直播，写「直播中」会误导。 */
    const val EPG_LIVE = "直播"
    /** 官方 [10]="2"（版权原因等）⇒ 明确告诉用户不可回看，而不是给一个点了会失败的按钮 */
    const val EPG_NO_REPLAY_ITEM = "不可回看"

    const val REPLAY_UNAVAILABLE = "该频道暂不支持回看（可能需登录/会员），已切回直播"
    /** ★ 2026-10-21：节目单里"正在播出"的节目可点时移（从 5 分钟前开始播） */
    const val TIMESHIFT = "时移"
    /** ★ 2026-10-21：节目条上的回看状态标记 */
    const val REPLAYING = "回看中"
    const val BACK_TO_LIVE = "回到直播"
    const val EPG_NO_NEXT = "暂无"
    /** ★ 2026-10-21：节目单为空时说明"为什么不能回看/时移"（用户反馈缺提示） */
    const val EPG_NO_REPLAY_HINT = "该频道暂无节目单，因此无法回看 / 时移"
    const val EPG_RETRYING = "EPG 获取失败，正在重试…"
    const val EPG_FAILED = "EPG 获取失败"
    const val EPG_BUTTON = "节目单 ☰"
    const val EPG_NOW_TITLE = "正在播出"
    const val EPG_NEXT_TITLE = "接下来"
    fun epgTitle(name: String) = "$name · 节目单"
    const val CLOSE = "关闭"

    // ---------- 手势 ----------
    fun volumeHint(p: Int) = "音量 $p%"
    fun brightnessHint(p: Int) = "亮度 $p%"

    // ---------- 频道区 ----------
    const val TAB_CCTV = "央视"
    const val TAB_SATELLITE = "卫视"
    const val TAB_LOCAL = "地方"
    const val TAB_ABOUT = "关于"
    const val GROUP_EMPTY = "该分组暂无频道"
    // ★ 2026-10-01：去掉"下方" —— 横屏分栏时频道列表在**右侧**（竖屏才在下方）⇒ 用中性文案。
    //   ⚠️ 三端同步改：鸿蒙 `Index.ets` 同名文案（桌面端没有这句空态提示）。
    const val PICK_CHANNEL = "请选择频道开始观看"

    // ---------- 关于页 ----------
    /** ★ 2026-10-02（用户要求：应用名只留中文，别出现英文 "PalmTV"）—— 原为 "PalmTV 掌上电视"。
     *  ⚠️ 鸿蒙 `Index.ets` 关于页同位置也写着 "PalmTV 掌上电视"，若要三端一致需一起改（本次只改了安卓）。 */
    const val ABOUT_TITLE = "掌上电视"
    fun aboutVersion(v: String) = "版本 $v"
    const val ABOUT_EDITION = "安卓版 · com.rickyone.palmtv"
    const val ABOUT_COPYRIGHT = "版权人：飘渺峰"
    const val SEC_TECH = "技术说明"
    const val TECH_1 = "· 客户端：Kotlin / Jetpack Compose（界面与取流编排）"
    const val TECH_2 = "· 播放器：Media3 (ExoPlayer)，HLS 原生播放"
    const val TECH_3 = "· 数据来源：各电视台/内容方公开发布的直播地址"
    const val SEC_ACCOUNT = "账号与登录"
    const val LOGIN_WECHAT = "微信登录"
    const val LOGIN_HUAWEI = "华为账号登录"
    const val LOGIN_1 = "· 登录用于跨设备同步「收藏」与偏好；未登录也可正常观看"
    const val LOGIN_2 = "· 收藏、登录同步将在后续版本提供"
    const val SEC_LEGAL = "内容来源与免责"
    const val VIEW_FULL_DISCLAIMER = "查看完整声明 >"
    const val SEC_CONTACT = "举报 / 联系"
    fun notImplemented(name: String) = "$name：后续版本开放"
    const val SEC_IPTV = "自定义 IPTV 源"
    const val IPTV_ENTRY = "添加 / 编辑自定义源…"
    // ---- ★ 2026-10-02（用户要求：与桌面端同位置/同交互）----
    /** 技术说明的第 4 条（桌面 `MainWindow.xaml` 里的同一条文案） */
    const val IPTV_TECH_ITEM = "· 支持自定义 IPTV 源"
    const val IPTV_ENTRY_BTN = "添加 / 编辑"
    /** 编辑窗顶部说明（逐字照抄桌面 `IptvSourceWindow.xaml`） */
    const val IPTV_DLG_TOP = "填写电视台/运营方公开发布的直播直链（.m3u8 或 .ts）。支持多路，保存后立即生效、无需重启。"
    const val IPTV_ADD = "添加到列表"
    const val IPTV_UPDATE = "更新选中"
    const val IPTV_REMOVE = "删除选中"
    const val IPTV_NEED_SELECT_EDIT = "请先在列表里选中要修改的那条。"
    const val IPTV_NEED_SELECT_DEL = "请先在列表里选中要删除的那条。"
    const val IPTV_SAVE_APPLY = "保存并生效"
    const val IPTV_EMPTY_LIST = "（还没有自定义源：填好下面两项，点「添加到列表」）"
    const val IPTV_UNNAMED = "(未命名)"
    const val CANCEL = "取消"
    // ---------- 自定义 IPTV 源编辑（★ 2026-10-02 同步桌面端 `IptvSourceWindow` 的文案口径）----------
    fun iptvCount(local: Int, custom: Int) = "已载入 $local 个地方台（自定义 $custom 条）"
    /** 编辑窗底部灰字提示（逐字照抄桌面 `IptvSourceWindow.xaml.cs` 的 `UpdateHint()`，只把"记事本"改成"文本编辑器"） */
    fun iptvHint(count: Int, path: String) =
        "当前 $count 条自定义源。\n" +
            "· 支持 m3u8 / ts 直播直链；保存后立即生效，无需重启\n" +
            "· 自定义源写在应用私有目录（升级 / 重装都不会丢）\n" +
            "· 也可用文本编辑器直接编辑：$path"
    const val IPTV_IMPORT_SHOW = "从 m3u 文本导入 ▾"
    const val IPTV_IMPORT_LABEL = "粘贴 m3u 文本（#EXTINF:-1,频道名 换行 地址）"
    const val IPTV_IMPORT_DO = "导入到列表"
    fun iptvImported(n: Int) = "已导入 $n 条"
    const val IPTV_IMPORT_EMPTY = "没解析到条目（需要 #EXTINF:-1,频道名 与地址各占一行）"
    const val IPTV_DUP = "该地址已在列表里。"
    const val IPTV_SAVE_FAIL = "保存失败（目录不可写？）"
    const val SAVE = "保存"

    // ---------- ★ 2026-10-04：TV 版专用文案（TV 上没有触摸/手势 ⇒ 用中文按钮与按键提示）----------
    const val TV_PLAY = "▶ 播放"
    const val TV_PAUSE = "⏸ 暂停"
    const val TV_MUTE = "静音"
    const val TV_UNMUTE = "取消静音"
    const val TV_FULLSCREEN = "全屏"
    const val TV_EXIT_FULLSCREEN = "退出全屏"
    /** 遥控按键提示（TV 控制行右侧的小字）。
     *  ⚠️ **TV 版没有"应用内音量"**（2026-10-04 用户拍板：音量交给电视遥控，符合 TV 应用惯例）——
     *     文案里点明"音量键＝电视音量"，免得用户再去找音量调节入口。
     *  ★ 2026-10-04 二次更新（用户实测：手机遥控**没有**「频道±」键、全屏就没法换台）：
     *     明说"**全屏时 上下＝换台**"，并写清 HUD 4 秒自动收起。 */
    const val TV_KEY_HINT = "方向键选台 · OK 确认 · 频道±切台 · 音量键＝电视音量\n" +
        "全屏时：左右＝时移 ±10 秒、上下＝换台、OK 唤出控制条（4 秒自动收起）"
    /** 关于页里的说明：TV 版不做自定义源编辑（用户 2026-10-04 决定） */
    const val TV_IPTV_NOTE = "· 自定义 IPTV 源：请在手机版 / 桌面版编辑（TV 上不便输入）"
    /** TV 版的"关于页"版本行（手机版是 `ABOUT_EDITION`） */
    const val ABOUT_EDITION_TV = "TV 版 · com.rickyone.palmtv"
    /** TV 版节目单弹层底部提示（2026-10-04 补 EPG 弹层） */
    const val TV_EPG_HINT = "上下滚动 · OK 回看已播节目 · 返回 关闭（带「回看」标的才可回看）"

    // ---------- 免责声明 ----------
    const val DISC_TITLE = "内容来源与免责声明"
    const val DISC_AGREE = "我已阅读并同意"
    const val DISC_REFUSE = "不同意并退出"
    const val DISC_AGREED_NOTE = "以上为当前生效的声明内容"
    const val DISC_FIRST_NOTE = "继续使用即表示您已阅读并同意以上说明"

    /** 正文（逐字，与桌面/鸿蒙一致；改动必须升 `Config.DISC_VERSION`） */
    val DISC_TEXT = """
        1. 本应用为纯播放器客户端，自身不提供、不存储、不制作任何音视频内容。

        2. 所有频道的播放地址（直播流）与台标图片均来自互联网公开渠道，包括 GitHub、Gitee 等开源项目以及各地电视台公开发布的直播地址，仅用于网络流媒体播放技术的演示与个人学习。

        3. 音视频内容的著作权、播出权及解释权归原电视台或相应权利人所有；本应用不对其合法性、准确性、完整性与可用性作任何担保。

        4. 若权利人认为本应用展示或播放的内容侵犯其合法权益，请通过下方联系方式告知我们，核实后将及时移除相关来源。

        5. 请勿将本应用用于商业用途或二次分发；使用者应自行确保其使用行为符合所在地区法律法规。
    """.trimIndent()
}
