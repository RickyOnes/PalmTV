package com.rickyone.palmtv.data

/**
 * 频道表 —— 与鸿蒙 `common/ChannelList.ets` **逐条、按序**一致（含顺序）。
 *
 * 三种取流来源（`src`）：
 *   · `ysp`（缺省）—— 央视频链路：**自研 cKey** → `liveinfo` → **明文 HLS**（`playbacktime` 决定
 *     直播 / 时移 / 回看），2026-10-22 起不再有 CMG 解密
 *   · `jstv`       —— 江苏台（荔枝 TV）直连：只需 `txSecret` 签名 + Referer，**流是明文**
 *   · `iptv`       —— 外部 IPTV 明文直链：**不需要签名、不解密**，播放器直接吃 URL
 *
 * ⚠️ 顺序决定 `iptv-<下标>` 的 id（台标按 id 挂）⇒ **不要为了"看起来整齐"重排**。
 */
data class Channel(
    val id: String,
    val name: String,
    val pid: String,
    val cnlId: String,
    val group: Group,
    val src: Src = Src.YSP,
    /** jstv = 荔枝 TV 流 ID；iptv = 原始 HLS 直链 URL */
    val streamId: String = ""
) {
    enum class Group { CCTV, SATELLITE, LOCAL }
    enum class Src { YSP, JSTV, IPTV }

    val isJstv: Boolean get() = src == Src.JSTV
    /**
     * ★★★ 2026-10-27：**是否需要 ChinaDRM 解密**（只有这 8 个台）★★★
     *
     * 实测（`docs/ysp-ckey/ref/drm/seg-scan.py`）：这 8 个台的 m3u8 带
     * `#EXT-X-KEY:METHOD=SM4-CBC,...URI="data:text/plain;base64,<PSSH>"`，
     * 且 liveinfo 返回 `encrypt=2` ⇒ 流是 SM4 加密的，明文链路播出来必然绿屏。
     *
     * 解密必须走 ChinaDRM（GY/T 277-2019）三步：DTA provision → GetLicense → SM4，
     * 而设备证书绑定官方 App 的签名指纹（`libTPCore-master.so` 的 `appCertFingerprint`）
     * ⇒ **自研不可行**，只能沿用 CMG 解密核（`cmg_runtime` + `eb_prog.bin`）。
     *
     * 其余频道（含 CCTV-1..13 等）走「安卓/鸿蒙平台移动端链路 + 自研 cKey」的**明文**流，不需要解密。
     */
    val needsCmg: Boolean get() = id in CMG_IDS
    val isIptv: Boolean get() = src == Src.IPTV
    /** 本地直连类（jstv + iptv）：不参与 auth/签名/EPG/解密 */
    val isLocalDirect: Boolean get() = isJstv || isIptv

    /** 台标候选名（按序尝试）：先 id、再中文名 —— 与桌面 `ResolveLogoPath` 同策略 */
    val logoNames: List<String> get() = listOf(id, name)
}


/** ★ 需要解密（`Channel.needsCmg`）的频道 id —— 8 个 ChinaDRM(sm4c) 加密台。
 *
 *  实测确认（liveinfo `encrypt=2` + m3u8 `METHOD=SM4-CBC`）：
 *  CCTV-4K / 11 / 12 / 14 / 15 / 16 / 16(4K) / 17，共 8 个。
 *
 *  ★★★ 2026-10-29：**不再用 CMG 解，改用自研 `player/Sm4C.kt`（SM4-CBC）** ★★★
 *   · 算法：标准 SM4-CBC；key=`entuqw6iysy3wbii`（所有台通用）；
 *     IV = hex(PSSH contentID 前 8 字符)；
 *     范围 = 每个 slice NAL 固定第 32 字节到 NAL 尾（末尾不足 16 字节原样保留）。
 *   · 验证：与官方 App 解码器实际拿到的明文逐字节一致；与桌面 `windows/Sm4C.cs`
 *     和 Python 参考实现输出逐字节相同。
 *   ⇒ `plainChannel=false` ⇒ `CmgDataSource` 边取边解：**先试 sm4c**，不中才回落 CMG。
 *
 *  ⚠️ 加台前请先跑 `docs/ysp-ckey/ref/drm/seg-scan.py` 确认，别凭感觉加。 */
val CMG_IDS: Set<String> = setOf(
    "cctv4k", "cctv11", "cctv12", "cctv14",
    "cctv15", "cctv16", "cctv16k", "cctv17"
)

object Channels {

    val all: List<Channel> = listOf(
        // ===== 央视组（默认）=====
        Channel("cctv1", "CCTV-1 综合", "600001859", "2024078203", Channel.Group.CCTV),
        Channel("cctv2", "CCTV-2 财经", "600001800", "2024075403", Channel.Group.CCTV),
        Channel("cctv3", "CCTV-3 综艺", "600001801", "2024068503", Channel.Group.CCTV),
        Channel("cctv4", "CCTV-4 中文国际", "600001814", "2029797103", Channel.Group.CCTV),
        Channel("cctv5", "CCTV-5 体育", "600001818", "2024078403", Channel.Group.CCTV),
        Channel("cctv5p", "CCTV-5+ 赛事", "600001817", "2024078003", Channel.Group.CCTV),
        Channel("cctv6", "CCTV-6 电影", "600108442", "2013693901", Channel.Group.CCTV),
        Channel("cctv7", "CCTV-7 军事", "600004092", "2024072003", Channel.Group.CCTV),
        Channel("cctv8", "CCTV-8 电视剧", "600001803", "2029793003", Channel.Group.CCTV),
        Channel("cctv9", "CCTV-9 纪录", "600004078", "2024078603", Channel.Group.CCTV),
        Channel("cctv10", "CCTV-10 科教", "600001805", "2024078703", Channel.Group.CCTV),
        Channel("cctv11", "CCTV-11 戏曲", "600001806", "2027248703", Channel.Group.CCTV),
        Channel("cctv12", "CCTV-12 社会与法", "600001807", "2027248803", Channel.Group.CCTV),
        Channel("cctv13", "CCTV-13 新闻", "600001811", "2029797203", Channel.Group.CCTV),
        Channel("cctv14", "CCTV-14 少儿", "600001809", "2027248903", Channel.Group.CCTV),
        Channel("cctv15", "CCTV-15 音乐", "600001815", "2027249003", Channel.Group.CCTV),
        Channel("cctv16", "CCTV-16 奥林匹克", "600098637", "2027249103", Channel.Group.CCTV),
        Channel("cctv16k", "CCTV-16(4K)", "600099502", "2027249303", Channel.Group.CCTV),
        Channel("cctv17", "CCTV-17 农业", "600001810", "2027249403", Channel.Group.CCTV),
        Channel("cctv4k", "CCTV-4K 超高清", "600002264", "2029810303", Channel.Group.CCTV),
        Channel("cctv8k", "CCTV-8K", "600156816", "2026774121", Channel.Group.CCTV),
        Channel("cetv1", "中国教育1台", "600171827", "2022823801", Channel.Group.CCTV),
        Channel("cgne", "CGN英文台", "600014550", "2024181703", Channel.Group.CCTV),

        // ===== 卫视频道组 =====
        Channel("jsws", "江苏卫视", "600002521", "2024171103", Channel.Group.SATELLITE),
        Channel("hnws", "湖南卫视", "600002475", "2024054803", Channel.Group.SATELLITE),
        Channel("zjws", "浙江卫视", "600002520", "2024054703", Channel.Group.SATELLITE),
        Channel("bjws", "北京卫视", "600002309", "2024052703", Channel.Group.SATELLITE),
        Channel("dfws", "东方卫视", "600002483", "2024054503", Channel.Group.SATELLITE),
        Channel("henws", "河南卫视", "600002525", "2029797303", Channel.Group.SATELLITE),
        Channel("hebws", "河北卫视", "600002493", "2024171503", Channel.Group.SATELLITE),
        Channel("ahws", "安徽卫视", "600002532", "2024171403", Channel.Group.SATELLITE),
        Channel("tjws", "天津卫视", "600152137", "2019927003", Channel.Group.SATELLITE),
        Channel("sdws", "山东卫视", "600002513", "2029787903", Channel.Group.SATELLITE),
        Channel("sxws", "山西卫视", "600190407", "2025560803", Channel.Group.SATELLITE),
        Channel("dnws", "东南卫视", "600002484", "2024061503", Channel.Group.SATELLITE),
        Channel("hbws", "湖北卫视", "600002508", "2024171203", Channel.Group.SATELLITE),
        Channel("jxws", "江西卫视", "600002503", "2024061703", Channel.Group.SATELLITE),
        Channel("shxws", "陕西卫视", "600190400", "2029795103", Channel.Group.SATELLITE),
        Channel("lnws", "辽宁卫视", "600002505", "2024171303", Channel.Group.SATELLITE),
        Channel("jlws", "吉林卫视", "600190405", "2025561503", Channel.Group.SATELLITE),
        Channel("hebs", "黑龙江卫视", "600002498", "2029797003", Channel.Group.SATELLITE),
        Channel("ynws", "云南卫视", "600190402", "2025561303", Channel.Group.SATELLITE),
        Channel("gzws", "贵州卫视", "600002490", "2024061603", Channel.Group.SATELLITE),
        Channel("scws", "四川卫视", "600002516", "2024061403", Channel.Group.SATELLITE),
        Channel("cqws", "重庆卫视", "600002531", "2024061103", Channel.Group.SATELLITE),
        Channel("hainanws", "海南卫视", "600002506", "2024055603", Channel.Group.SATELLITE),
        Channel("gdws", "广东卫视", "600002485", "2024060903", Channel.Group.SATELLITE),
        Channel("gxws", "广西卫视", "600002509", "2024060703", Channel.Group.SATELLITE),
        Channel("szws", "深圳卫视", "600002481", "2024061303", Channel.Group.SATELLITE),
        Channel("nmgws", "内蒙古卫视", "600190401", "2025561203", Channel.Group.SATELLITE),
        Channel("gansuws", "甘肃卫视", "600190408", "2025561703", Channel.Group.SATELLITE),
        Channel("qhws", "青海卫视", "600190406", "2025559103", Channel.Group.SATELLITE),
        Channel("xzws", "西藏卫视", "600190403", "2025558003", Channel.Group.SATELLITE),
        Channel("xinjiangws", "新疆卫视", "600152138", "2019927403", Channel.Group.SATELLITE),
        Channel("ningxiaws", "宁夏卫视", "600190737", "2025608503", Channel.Group.SATELLITE),

        // ===== 地方台：江苏（jstv，明文直连 + 签名）=====
        // ⚠️ 不列江苏卫视（jswspro）：卫视组已有同名的 jsws（央视频源），重复只会让人分不清。
        Channel("jsws4kpro", "江苏卫视4K", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsws4kpro"),
        Channel("jszypro", "江苏综艺", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jszypro"),
        Channel("jsyspro", "江苏影视", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsyspro"),
        Channel("jscspro", "江苏城市", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jscspro"),
        Channel("jsxwpro", "江苏新闻", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsxwpro"),
        Channel("jsjypro", "江苏教育", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsjypro"),
        Channel("jsxxpro", "江苏休闲", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsxxpro"),
        Channel("jsgjpro", "江苏国际", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "jsgjpro"),
        Channel("ymktpro", "优漫卡通", "", "", Channel.Group.LOCAL, Channel.Src.JSTV, "ymktpro"),

        // ===== 地方台：外部 IPTV 明文直链（iptv）=====
        // ⚠️ 与桌面 `IptvChannels.BuiltIn`、鸿蒙 `ChannelList.ets` 三处互为镜像：**内容 + 顺序**都要一致。
        Channel("iptv-0", "广州电视", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://tencentplaybusiness.gztv.com/live/zonghes.m3u8"),
        Channel("iptv-7", "广州新闻", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://tencentplay.gztv.com/live/nanguodushi.m3u8?txSecret=550af55c0ea34ce492748481415b6dfa&txTime=1903e7b17de"),
        Channel("iptv-1", "哈尔滨电影", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://stream.hrbtv.net/yspd/playlist.m3u8"),
        Channel("iptv-2", "哈尔滨综合", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://stream.hrbtv.net/xwzh/playlist.m3u8?_upt=ef41dd531755913594"),
        Channel("iptv-3", "吉林都市", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/7e8474e6daea44ccaa5aa2300191439e/index.m3u8"),
        Channel("iptv-4", "吉林乡村", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/3ffc4824dce54b92be185555923ce382/index.m3u8"),
        Channel("iptv-5", "吉林生活", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/0a76740c72b74fabae611845aa21e06a/index.m3u8"),
        Channel("iptv-6", "吉林影视", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/906341e6f19b4c4bacdc89941eb85d12/index.m3u8"),
        Channel("iptv-8", "农林卫视", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://124.116.183.146:9901/tsfile/live/1004_1.m3u8"),
        Channel("iptv-9", "山东教育", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://test1.live.sdetv.com.cn/live/dianshizhibo/playlist.m3u8"),
        Channel("iptv-10", "四平综合", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://stream2.jlntv.cn/sptv/sd/live.m3u8?_upt=f27750421743154598"),
        Channel("iptv-11", "通化新闻", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/43ea5771aa44421591f9dfd2b71f1b9b/index.m3u8"),
        Channel("iptv-12", "赤峰综合", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://play1-qk.nmtv.cn/live/1735546697341033.m3u8"),
        Channel("iptv-13", "香港卫视", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "https://hkstv.tv/api/m3u8-proxy?url=http%3A%2F%2Fwebcast.hkstv.tv%2Flivestream%2Fmutfysrq%2Fplaylist.m3u8"),
        Channel("iptv-14", "金鹰卡通", "", "", Channel.Group.LOCAL, Channel.Src.IPTV, "http://59.39.89.130:60901/tsfile/live/0125_25.m3u8?key=txiptv&playlive=1&authid=0")
    )

    /** 按分组取（顺序 = 本表顺序） */
    fun byGroup(g: Channel.Group): List<Channel> = all.filter { it.group == g }

    fun byId(id: String): Channel? = all.firstOrNull { it.id == id }

    fun byName(name: String): Channel? = all.firstOrNull { it.name == name }

    /**
     * 源标错 PAR 的台（键 = 频道名）：按 16:9 摆画面。
     * 与鸿蒙 `ASPECT_OVERRIDES` 一致（用户实测这三路必须强制 16:9）。
     */
    val aspectOverrides: Map<String, Float> = mapOf(
        "哈尔滨电影" to 16f / 9f,
        "哈尔滨综合" to 16f / 9f,
        "农林卫视" to 16f / 9f
    )

    /** 分组 tab 文案（与鸿蒙逐字一致） */
    fun groupLabel(g: Channel.Group): String = when (g) {
        Channel.Group.CCTV -> "央视"
        Channel.Group.SATELLITE -> "卫视"
        Channel.Group.LOCAL -> "地方"
    }
}
