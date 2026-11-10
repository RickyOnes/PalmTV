package com.rickyone.palmtv.ui

import android.content.res.Configuration
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rickyone.palmtv.MainViewModel
import com.rickyone.palmtv.R
import com.rickyone.palmtv.UiState
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.IptvSources
import com.rickyone.palmtv.player.Logos

/**
 * 关于页（第 4 个 tab）—— 字段与鸿蒙 `aboutView()` 一致。
 * ★ 新增一项「自定义 IPTV 源」（对齐桌面版机制；鸿蒙无此机制）。
 */
@Composable
fun AboutView(vm: MainViewModel, ui: UiState) {
    val clipboard = LocalClipboardManager.current
    val ctx = LocalContext.current
    var showIptv by remember { mutableStateOf(false) }

    Column(
        Modifier.fillMaxSize().background(Palette.ChannelBg)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Image(
                painter = painterResource(R.mipmap.ic_launcher),
                contentDescription = null,
                modifier = Modifier.size(48.dp).clip(RoundedCornerShape(10.dp))
            )
            Spacer(Modifier.width(10.dp))
            Column {
                Text(Strings.ABOUT_TITLE, fontSize = 16.sp, color = Palette.TextBright,
                    fontWeight = FontWeight.Bold)
                Text(Strings.aboutVersion(ui.appVersion), fontSize = 12.sp, color = Palette.TextDim)
                Text(Strings.ABOUT_EDITION, fontSize = 12.sp, color = Palette.TextDim)
                // ★ 2026-10-02（用户要求）：在「版权人：飘渺峰」**之后**加一个版权图标。
                //   观感取舍：原图（`版权.ico`）是 48×48 的人像方图 ⇒ 做成**行内小图标**（16dp）——
                //   16dp 在 3x 屏正好 48px（1:1 不放大、不糊），贴着文字基线垂直居中，不抢标题。
                //   ⚠️ 用户明确要求**圆角矩形，不要圆形**（2026-10-02 二次反馈）⇒ `RoundedCornerShape(4.dp)`；
                //      三端一致：鸿蒙/桌面端同尺寸同圆角。
                //   ⚠️ 图来自 `assets/palmres.dat` 的 `app/copyright` 条目（**不额外占 APK 文件数**）；
                //      老包/构建脚本没跑时取不到 ⇒ 只显示文字，不崩。
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(Strings.ABOUT_COPYRIGHT, fontSize = 12.sp, color = Palette.TextDim)
                    val cp = remember { Logos.app(ctx, "copyright") }
                    if (cp != null) {
                        Spacer(Modifier.width(5.dp))
                        Image(
                            bitmap = cp.asImageBitmap(),
                            contentDescription = "版权图标",
                            modifier = Modifier.size(16.dp).clip(RoundedCornerShape(4.dp))
                        )
                    }
                }
            }
        }

        SectionTitle(Strings.SEC_TECH)
        Text(Strings.TECH_1, fontSize = 12.sp, color = Palette.TextMid)
        Text(Strings.TECH_2, fontSize = 12.sp, color = Palette.TextMid)
        Text(Strings.TECH_3, fontSize = 12.sp, color = Palette.TextMid)
        // ★ 2026-10-02（用户要求：与桌面端**同位置**）：「自定义 IPTV 源」是**技术说明的第 4 条**，
        //   行内跟一个「添加 / 编辑」按钮 —— 桌面端 `MainWindow.xaml` 就是这个结构：
        //     `· 支持自定义 IPTV 源`  +  [添加 / 编辑]（Click → 独立编辑窗）
        //   原来安卓把它单列成一个「自定义 IPTV 源」小节（放在"举报/联系"之前）⇒ 已挪到这里。
        //   ⚠️ 下面那行"已载入 N 个地方台（自定义 M 条）"对应桌面端挂在按钮 ToolTip 上的信息
        //      （手机没有 ToolTip，所以直接显示成一行小字）。
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(Strings.IPTV_TECH_ITEM, fontSize = 12.sp, color = Palette.TextMid)
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.height(26.dp).clip(RoundedCornerShape(6.dp)).background(Palette.Primary)
                    .clickable { showIptv = true }.padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(Strings.IPTV_ENTRY_BTN, fontSize = 12.sp, color = Color.White)
            }
        }
        val localCount = ui.channels.count { it.group == Channel.Group.LOCAL }
        val customCount = ui.channels.count { it.id.startsWith("iptv-u") }
        Text(Strings.iptvCount(localCount, customCount), fontSize = 11.sp, color = Palette.TextDim)

        SectionTitle(Strings.SEC_ACCOUNT)
        // ★ 2026-10-02（用户要求：两个登录按钮**并排等大**）：原来竖着各占一整行 ⇒ 改成
        //   `Row` + 两个都 `weight(1f)`（等宽）+ 同一个 38dp 高度（等高）⇔ 视觉上是两个等大的按钮。
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            LoginButton(Strings.LOGIN_WECHAT, Palette.WechatGreen, Modifier.weight(1f)) {
                vm.notice(Strings.notImplemented(Strings.LOGIN_WECHAT))
            }
            Spacer(Modifier.width(8.dp))
            LoginButton(Strings.LOGIN_HUAWEI, Palette.HuaweiRed, Modifier.weight(1f)) {
                vm.notice(Strings.notImplemented(Strings.LOGIN_HUAWEI))
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(Strings.LOGIN_1, fontSize = 11.sp, color = Palette.TextDim)
        Text(Strings.LOGIN_2, fontSize = 11.sp, color = Palette.TextDim)

        SectionTitle(Strings.SEC_LEGAL)
        Text(
            Strings.VIEW_FULL_DISCLAIMER, fontSize = 13.sp, color = Palette.Primary,
            modifier = Modifier.clickable { vm.openDisclaimerReadOnly() }.padding(vertical = 6.dp)
        )

        SectionTitle(Strings.SEC_CONTACT)
        Text(
            Config.CONTACT_EMAIL, fontSize = 13.sp, color = Palette.LinkBlue,
            modifier = Modifier.clickable {
                clipboard.setText(AnnotatedString(Config.CONTACT_EMAIL))
                vm.notice("已复制联系邮箱：${Config.CONTACT_EMAIL}")
            }.padding(vertical = 6.dp)
        )
        Spacer(Modifier.height(12.dp))
    }

    if (showIptv) {
        IptvEditorDialog(
            initial = vm.loadCustomSources(),
            filePath = vm.iptvFilePath(),
            onDismiss = { showIptv = false },
            onSave = { list ->
                // ★ 保存结果要回给弹窗：写文件失败时**留在弹窗里**并提示（桌面端也是这个行为）
                val ok = vm.saveCustomSources(list)
                if (ok) {
                    showIptv = false
                    vm.notice("已保存自定义 IPTV 源")
                }
                ok
            }
        )
    }
}

@Composable
private fun SectionTitle(t: String) {
    Spacer(Modifier.height(14.dp))
    Text(t, fontSize = 13.sp, color = Palette.TextBright, fontWeight = FontWeight.Bold)
    Spacer(Modifier.height(4.dp))
}

/** 登录按钮（占位）—— 尺寸/位置由调用方给的 [modifier] 决定（现在两个都传 `weight(1f)` ⇒ 并排等大） */
@Composable
private fun LoginButton(label: String, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.height(38.dp).clip(RoundedCornerShape(8.dp)).background(color)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Text(label, fontSize = 14.sp, color = Color.White, fontWeight = FontWeight.Medium)
    }
}

/**
 * 自定义 IPTV 源编辑 —— ★★ 2026-10-02（用户实测"体验很差且显示不全"后**重做**）★★
 *
 * ① **"显示不全"的真因**（设计缺陷，不是内容太多）：
 *    原来这个弹窗是直接写在「关于」页那个 `Column(Modifier.verticalScroll(...))` **里边**的 ⇒
 *      · 滚动容器给子项的高度约束是**无界**的 ⇒ 里面的 `weight(1f)` 列表被压成 0 高、
 *        `fillMaxHeight(0.9f)` 也失去意义；
 *      · 它只是滚动内容里的一块 ⇒ 被滚动视口**裁切**，底部的「取消 / 保存并生效」直接看不见
 *        （用户截图里对话框就是被屏幕下沿切掉的）。
 *    ⇒ 改用**窗口级 `Dialog`**（`usePlatformDefaultWidth = false`）：浮在整个界面之上，拿到的是
 *      **真实窗口约束** ⇒ `fillMaxHeight(0.9f)` / `weight(1f)` 全部恢复正常，且**不会被任何父容器裁切**。
 * ② **形态与鸿蒙弹窗对齐**（用户要求"同步鸿蒙端弹窗形式"）：
 *      标签在输入框**左侧**（不再用 Material 的浮动标签挤在框里）→ 输入框更矮更紧凑 →
 *      列表固定 140dp → 按钮**按职责分三档配色**（见 [DlgBtn]，不再是"一片全蓝"）。
 * ③ 结构：标题 → 说明 → **列表**(定高) → **输入+操作**(可滚，吃满剩余高度) → **取消 / 保存**(钉在窗底)。
 *    ⚠️ 中段单独做成 `weight(1f) + verticalScroll`：小屏上它自己滚，底部两个按钮**永远可见**
 *      —— 这就是"显示不全"要根治的点。
 *
 * 规则全部与桌面端一致（在 `IptvSources` 里）：地址必填 + 必须 http(s)、空名取域名、
 * 剥 `(720p)` 后缀、同地址提示"该地址已在列表里。"、保存失败提示 + 留在窗内。
 * ⚠️ 另外保留了「粘贴 m3u 文本导入」这个手机端特有的入口（桌面端是让你用记事本改文件）。
 */
@Composable
fun IptvEditorDialog(
    initial: List<IptvSources.Entry>,
    filePath: String,
    onDismiss: () -> Unit,
    onSave: (List<IptvSources.Entry>) -> Boolean
) {
    // ⚠️ 必须用 SnapshotStateList：原来用普通 MutableList 套 mutableStateOf ⇒ 增删改**不触发重组**
    //（表现为"输入框像卡住、删除没反应"，2026-10-02 实测踩过）
    val rows = remember { mutableStateListOf<IptvSources.Entry>().apply { addAll(initial) } }
    var sel by remember { mutableStateOf(-1) }        // 列表选中项（-1 = 未选）
    var nameBox by remember { mutableStateOf("") }
    var urlBox by remember { mutableStateOf("") }
    var err by remember { mutableStateOf("") }
    var hint by remember { mutableStateOf("") }
    var showImport by remember { mutableStateOf(false) }
    var importText by remember { mutableStateOf("") }
    // ★ 2026-10-02：**横屏判定**（矮窗口自适应用）—— 横屏时列表降到 90dp 把高度让给输入区，
    //   见下方列表那一处的注释（鸿蒙侧同口径：`this.isWide() ? 90 : 140`）。
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    // ★★ 弹窗高度**上限** = 屏幕高的 90%（**注意是"上限"、不是"固定高度"**，见下方 Column 处注释）。
    //   用 `screenHeightDp` 而不是 `BoxWithConstraints`：省一层嵌套，且横竖屏都会自动跟着变。
    val maxDialogH = LocalConfiguration.current.screenHeightDp.dp * 0.9f

    /** 校验当前两个输入框（桌面 `Validate()`）；通过则返回归一化后的条目，否则把错误写进 [err] 并返回 null */
    fun readInputs(): IptvSources.Entry? {
        val url = urlBox.trim()
        IptvSources.validateUrl(url)?.let {
            err = it
            return null
        }
        return IptvSources.Entry(IptvSources.nameOrHost(IptvSources.stripQuality(nameBox), url), url)
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,   // ★ 关键：拿到真实窗口约束（否则对话框被限成一个小窗）
            dismissOnClickOutside = false      // ⚠️ 必须显式点「取消」才关，防误触把编辑丢掉
        )
    ) {
        Box(
            Modifier.fillMaxSize().background(Color(0xCC000000)),
            contentAlignment = Alignment.Center
        ) {
            // ★★ 2026-10-02 三次修正（用户实测：**竖屏**下弹窗"有点拉夸、不紧凑"）★★
            //   上一版是 `fillMaxHeight(0.9f)` —— 把弹窗**强行撑到窗口的 90%** ⇒ 内容本来只有 ~520dp，
            //   下面白白空一大块 ✗（横屏是修好了，但竖屏难看）。
            //   改成 `heightIn(max = maxDialogH)`：**按内容自适应**（竖屏紧凑 ✓），只有内容真的放不下
            //   时才撑到上限；配合中段的 `weight(1f, fill = false)` ⇒ 中段先让步（自己滚），
            //   底栏「取消 / 保存并生效」钉住不动 ⇒ 横屏（矮窗口）依然点得到按钮，不退回老问题 ✓。
            Column(
                Modifier.fillMaxWidth(0.92f).heightIn(max = maxDialogH)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Palette.CardBg).padding(16.dp)
            ) {
                Text(Strings.SEC_IPTV, fontSize = 15.sp, color = Palette.TextBright,
                    fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text(Strings.IPTV_DLG_TOP, fontSize = 11.sp, color = Palette.TextMid)

                // ---------- 列表（桌面 `SourceList`）：点一条即选中 + 回填输入框 ----------
                // ★ **固定高度**（与鸿蒙弹窗一致）：竖屏 140dp、**横屏 90dp** ——
                //   横屏窗口矮（360dp 上下），列表是"看"的、输入区是"填"的 ⇒ 把高度让给中段，
                //   否则中段只剩几十 dp、输入框一行都显示不全（2026-10-02 用户实测横屏体验差）。
                Spacer(Modifier.height(8.dp))
                Column(
                    Modifier.fillMaxWidth().height(if (landscape) 90.dp else 140.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(Palette.ChannelBg).verticalScroll(rememberScrollState()).padding(4.dp)
                ) {
                    if (rows.isEmpty()) {
                        Text(Strings.IPTV_EMPTY_LIST, fontSize = 11.sp, color = Palette.TextDim,
                            modifier = Modifier.padding(6.dp))
                    }
                    rows.forEachIndexed { i, e ->
                        val on = i == sel
                        Text(
                            "${i + 1}. ${e.name.ifBlank { Strings.IPTV_UNNAMED }}    ${e.url}",
                            fontSize = 11.sp,
                            color = if (on) Color.White else Palette.TextMid,
                            maxLines = 1,
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp))
                                .background(if (on) Palette.Primary else Color.Transparent)
                                .clickable {
                                    sel = i
                                    nameBox = e.name
                                    urlBox = e.url
                                    err = ""
                                    hint = ""
                                }.padding(horizontal = 6.dp, vertical = 7.dp)
                        )
                    }
                }

                // ---------- 中段：输入 + 操作 —— ★ 可滚 + 吃满剩余高度 ----------
                //   ⚠️ 这就是"显示不全"的根治点：小屏 / 软键盘弹出时**中段自己滚**，
                //      而下面的「取消 / 保存并生效」钉在窗底 ⇒ 永远看得见、点得到。
                Spacer(Modifier.height(8.dp))
                // ★ 中段：`fill = false` 是关键 —— **按内容高度**（不强行吃满剩余空间）⇒ 竖屏不再留空白；
                //   只有内容真的放不下时，它才取"剩余高度"并把内容滚动（横屏矮窗口）。
                Column(
                    Modifier.weight(1f, fill = false).fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                ) {
                    // 输入区（桌面 `NameBox` / `UrlBox`）：**标签在框外**（与鸿蒙弹窗一致）——
                    // 标签固定 52dp ⇒ 两行输入框左边界对齐；框高 38dp（Material 默认 56dp 太占地方）。
                    FieldRow("频道名", nameBox, "留空则自动取域名") { nameBox = it }
                    Spacer(Modifier.height(6.dp))
                    FieldRow("播放地址", urlBox, "http:// 或 https:// 开头的 m3u8 / ts",
                        KeyboardType.Uri) { urlBox = it }

                    // ---------- 三个操作按钮（桌面同款顺序）----------
                    // ★ 配色分层：主操作=实心蓝、次要=描边、删除=危险红（不再是"一片全蓝"）
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // ★ 2026-10-02（用户："操作后要马上更新列表，让用户知道"）：
                        //   列表本身是 `SnapshotStateList` ⇒ 增删改**当场**重绘；这里补的是"看得见的回执"
                        //   （hint 会顶掉底部汇总那几行，2 秒内用户就知道刚才那一下生效了）。
                        DlgBtn(Strings.IPTV_ADD, BtnKind.PRIMARY) {
                            val e = readInputs() ?: return@DlgBtn
                            if (rows.any { it.url.equals(e.url, ignoreCase = true) }) {
                                err = Strings.IPTV_DUP
                                return@DlgBtn
                            }
                            rows.add(e)
                            sel = rows.size - 1
                            nameBox = ""
                            urlBox = ""
                            err = ""
                            hint = "✓ 已添加第 ${rows.size} 条：${e.name}（共 ${rows.size} 条，未保存）"
                        }
                        Spacer(Modifier.width(8.dp))
                        DlgBtn(Strings.IPTV_UPDATE, BtnKind.GHOST) {
                            if (sel < 0 || sel >= rows.size) {
                                err = Strings.IPTV_NEED_SELECT_EDIT
                                return@DlgBtn
                            }
                            val e = readInputs() ?: return@DlgBtn
                            if (rows.withIndex().any { it.index != sel && it.value.url.equals(e.url, true) }) {
                                err = Strings.IPTV_DUP
                                return@DlgBtn
                            }
                            rows[sel] = e
                            err = ""
                            hint = "✓ 已更新第 ${sel + 1} 条：${e.name}（共 ${rows.size} 条，未保存）"
                        }
                        Spacer(Modifier.width(8.dp))
                        DlgBtn(Strings.IPTV_REMOVE, BtnKind.DANGER) {
                            if (sel < 0 || sel >= rows.size) {
                                err = Strings.IPTV_NEED_SELECT_DEL
                                return@DlgBtn
                            }
                            val no = sel + 1
                            val gone = rows[sel].name
                            rows.removeAt(sel)
                            sel = -1
                            nameBox = ""
                            urlBox = ""
                            err = ""
                            hint = "✓ 已删除第 $no 条：$gone（剩 ${rows.size} 条，未保存）"
                        }
                    }

                    // ---------- 手机特有：粘贴 m3u 文本导入（桌面端那份 iptv-local.m3u 可直接粘进来）----------
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (showImport) Strings.IPTV_IMPORT_LABEL else Strings.IPTV_IMPORT_SHOW,
                        fontSize = 11.sp, color = Palette.Primary,
                        modifier = Modifier.clickable { showImport = !showImport }.padding(vertical = 3.dp)
                    )
                    if (showImport) {
                        Spacer(Modifier.height(4.dp))
                        Box(
                            Modifier.fillMaxWidth().heightIn(min = 76.dp).clip(RoundedCornerShape(6.dp))
                                .background(Color(0xFF0F3460))
                                .border(1.dp, Palette.BorderIdle, RoundedCornerShape(6.dp))
                                .padding(horizontal = 10.dp, vertical = 8.dp)
                        ) {
                            BasicTextField(
                                value = importText,
                                onValueChange = { importText = it },
                                textStyle = TextStyle(color = Palette.TextBright, fontSize = 11.sp),
                                cursorBrush = SolidColor(Palette.Primary),
                                keyboardOptions = KeyboardOptions(autoCorrect = false),
                                modifier = Modifier.fillMaxWidth()
                            )
                            if (importText.isEmpty()) {
                                Text("把 m3u 内容粘到这里（可多行）", fontSize = 11.sp,
                                    color = Palette.TextDim)
                            }
                        }
                        Spacer(Modifier.height(6.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            DlgBtn(Strings.IPTV_IMPORT_DO, BtnKind.PRIMARY) {
                                val parsed = IptvSources.parseM3u(importText)
                                if (parsed.isEmpty()) {
                                    err = Strings.IPTV_IMPORT_EMPTY
                                } else {
                                    parsed.forEach { p ->
                                        if (rows.none { it.url.equals(p.url, ignoreCase = true) }) rows.add(p)
                                    }
                                    importText = ""
                                    showImport = false
                                    err = ""
                                    hint = Strings.iptvImported(parsed.size)
                                }
                            }
                            Spacer(Modifier.width(8.dp))
                            DlgBtn(Strings.CLOSE, BtnKind.GHOST) { showImport = false }
                        }
                    }

                    // ---------- 提示（错误红 / 说明灰；都留在窗内，手机没有 MessageBox）----------
                    Spacer(Modifier.height(8.dp))
                    if (err.isNotEmpty()) {
                        Text(err, fontSize = 11.sp, color = Palette.OnAirRed)
                    } else if (hint.isNotEmpty()) {
                        Text(hint, fontSize = 11.sp, color = Palette.TextDim)
                    } else {
                        Text(Strings.iptvHint(rows.size, filePath), fontSize = 10.sp,
                            color = Palette.TextDim)
                    }
                }

                // ---------- 取消 / 保存并生效：**钉在窗底**（中段自己滚，这两个永远可见）----------
                Spacer(Modifier.height(8.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    DlgBtn(Strings.CANCEL, BtnKind.GHOST) { onDismiss() }
                    Spacer(Modifier.width(8.dp))
                    DlgBtn(Strings.IPTV_SAVE_APPLY, BtnKind.PRIMARY) {
                        hint = ""
                        err = ""
                        if (!onSave(rows.toList())) {
                            err = Strings.IPTV_SAVE_FAIL + "\n" + filePath
                        }
                    }
                }
            }
        }
    }
}

/** 编辑窗按钮的三种层级（与鸿蒙 `iptvBtn(label, cb, kind)` 一一对应）：
 *  · [BtnKind.PRIMARY] 实心蓝 = **主操作**（添加到列表 / 导入到列表 / 保存并生效）——
 *    同屏尽量只出现一个，否则又变成用户吐槽的"全是蓝色背景、没有重点"；
 *  · [BtnKind.GHOST]   透明 + 灰描边 = 次要操作（更新选中 / 取消 / 关闭）；
 *  · [BtnKind.DANGER]  透明 + 暗红描边 + 红字 = 破坏性操作（删除选中）。 */
private enum class BtnKind { PRIMARY, GHOST, DANGER }

/** 编辑窗里的小按钮 —— 尺寸统一，**只靠配色区分职责**（与鸿蒙同观感） */
@Composable
private fun DlgBtn(label: String, kind: BtnKind, onClick: () -> Unit) {
    val shape = RoundedCornerShape(6.dp)
    val bg = if (kind == BtnKind.PRIMARY) Palette.Primary else Color.Transparent
    val line = when (kind) {
        BtnKind.PRIMARY -> Palette.Primary
        BtnKind.DANGER -> Color(0xFF5C2A2A)
        BtnKind.GHOST -> Palette.BorderIdle
    }
    val fg = when (kind) {
        BtnKind.PRIMARY -> Color.White
        BtnKind.DANGER -> Color(0xFFFF6B6B)
        BtnKind.GHOST -> Palette.TextBright
    }
    Box(
        Modifier.height(32.dp).clip(shape).background(bg).border(1.dp, line, shape)
            .clickable { onClick() }.padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(label, fontSize = 12.sp, color = fg)
    }
}

/** 一行「标签 + 输入框」—— 标签在**框外**（与鸿蒙弹窗一致）。
 *  用 `BasicTextField` 而不是 Material 的 `OutlinedTextField`：后者默认 56dp 高 + 浮动标签，
 *  在手机上太占地方（用户反馈"体验很差"），这里要的是鸿蒙那种紧凑观感。
 *  [keyboardType] 默认文本；播放地址传 `KeyboardType.Uri` ⇒ 键盘直接给 `/` `.` `:`，少切一次键盘。 */
@Composable
private fun FieldRow(
    label: String,
    value: String,
    placeholder: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    onChange: (String) -> Unit
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 12.sp, color = Palette.TextMid, modifier = Modifier.width(52.dp))
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier.weight(1f).height(38.dp).clip(RoundedCornerShape(6.dp))
                .background(Color(0xFF0F3460))
                .border(1.dp, Palette.BorderIdle, RoundedCornerShape(6.dp))
                .padding(horizontal = 10.dp),
            contentAlignment = Alignment.CenterStart
        ) {
            BasicTextField(
                value = value,
                onValueChange = onChange,
                singleLine = true,
                textStyle = TextStyle(color = Palette.TextBright, fontSize = 12.sp),
                cursorBrush = SolidColor(Palette.Primary),
                keyboardOptions = KeyboardOptions(keyboardType = keyboardType, autoCorrect = false),
                modifier = Modifier.fillMaxWidth()
            )
            if (value.isEmpty()) {
                Text(placeholder, fontSize = 11.sp, color = Palette.TextDim, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}


