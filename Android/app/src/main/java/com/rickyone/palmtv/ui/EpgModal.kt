package com.rickyone.palmtv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rickyone.palmtv.UiState
import com.rickyone.palmtv.data.Epg
import kotlinx.coroutines.delay
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/**
 * ★★★ 2026-10-22 重写：多天节目单（过去 6 天 ~ 未来 3 天）+ 官方"可回看"标志 + 回看中/直播中标示 ★★★
 *
 * 关键变更：
 *  1. 顶部增加**日期选择行**（对标官方 App：星期一 10/19 … 今日 10/22 … 星期六 10/24）
 *  2. 「回看」按钮改用 **protobuf 字段 [10]**（官方是否允许回看），不再只看"是否已播完"
 *     —— 否则会给"版权原因不可回看"的节目也显示回看按钮（点击必然失败）
 *  3. 当前节目：回看中 ⇒ **红粗「回看中」**；直播中 ⇒ **红粗「直播中」**
 */
@Composable
fun EpgModal(
    ui: UiState,
    matchVideo: Boolean,
    videoW: androidx.compose.ui.unit.Dp,
    /** 点节目 ⇒ 从该时刻起播（回看用 start；时移用 now-Ns） */
    onReplay: (Long) -> Unit = {},
    onClose: () -> Unit
) {
    val today = remember { LocalDate.now() }
    val fmt = remember { DateTimeFormatter.ofPattern("yyyyMMdd") }
    val todayYmd = remember { today.format(fmt) }
    /* ★ 2026-11-10（用户要求，三端统一）：**"正在看的那天"** ——
     *   · 回看/时移 ⇒ 正在播那档所属的日期（与 `Epg.Item.ymd` 同源：由 start 时间戳推出）；
     *   · 直播 ⇒ 今天。
     *   那一天的日期 TAB **始终红粗**（切到别的 TAB 也不变），表示"你正在看这天的节目"。 */
    val watchDayYmd = remember(ui.replayStart, todayYmd) {
        if (ui.replayStart <= 0L) todayYmd
        else java.time.Instant.ofEpochSecond(ui.replayStart)
            .atZone(java.time.ZoneId.systemDefault()).toLocalDate().format(fmt)
    }

    // 按天分组
    val byDay = remember(ui.epg) { Epg.groupByDay(ui.epg) }
    // 默认选中：回看中 ⇒ 回看节目所在那天；否则今天
    var selDay by remember(ui.epg, ui.replayStart) {
        val ref = if (ui.replayStart > 0L) ui.replayStart else System.currentTimeMillis() / 1000
        val d = byDay.firstOrNull { (_, list) -> list.any { it.start > 0 && ref in it.start until it.end } }
            ?.first
        mutableStateOf(d ?: todayYmd)
    }
    val dayList = byDay.firstOrNull { it.first == selDay }?.second ?: emptyList()
    val listState = rememberLazyListState()
    // ★ 日期行自己也要滚到选中日（否则默认停在最早那天，用户以为只有过去几天）
    val dayRowState = rememberLazyListState()
    LaunchedEffect(selDay, byDay.size) {
        val i = byDay.indexOfFirst { it.first == selDay }
        if (i >= 0) {
            // 让选中日落在中间（左侧留 2 天做"还有更早"的提示）
            dayRowState.scrollToItem((i - 2).coerceAtLeast(0))
        }
    }

    // 定位到"当前/回看"的节目（往上留 3 行，落在视口中部）
    LaunchedEffect(selDay, dayList, ui.replayStart) {
        val ref = if (ui.replayStart > 0L) ui.replayStart else System.currentTimeMillis() / 1000
        val idx = dayList.indexOfFirst { it.start > 0 && it.end > 0 && ref in it.start until it.end }
        if (idx >= 0) {
            delay(200)
            listState.scrollToItem((idx - 3).coerceAtLeast(0))
        } else {
            listState.scrollToItem(0)
        }
    }

    Box(
        Modifier.fillMaxSize().background(Color(0xAA000000)).clickable { onClose() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier.then(
                if (matchVideo && videoW > 0.dp) Modifier.width(videoW).fillMaxHeight(0.86f)
                // ★ 2026-10-22（用户要求）：**手机版恢复原占比 92% / 72%**，不要跟着 TV 一起放大
                else Modifier.fillMaxWidth(0.92f).fillMaxHeight(0.72f)
            )
                .clip(RoundedCornerShape(12.dp)).background(Palette.CardBg)
                .padding(horizontal = 14.dp, vertical = 10.dp)
                .clickable { /* 吞掉点击 */ }
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(Strings.epgTitle(ui.currentName), fontSize = 15.sp,
                    color = Palette.TextBright, fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f))
                Text(Strings.CLOSE, fontSize = 13.sp, color = Palette.Primary,
                    modifier = Modifier.clickable { onClose() }.padding(6.dp))
            }

            if (byDay.isEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(Strings.EPG_NONE, fontSize = 13.sp, color = Palette.TextDim)
                Spacer(Modifier.height(6.dp))
                Text(Strings.EPG_NO_REPLAY_HINT, fontSize = 12.sp, color = Palette.TextDim)
                return@Column
            }

            Spacer(Modifier.height(8.dp))
            // ---------- 日期选择行 ----------
            LazyRow(state = dayRowState, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(byDay.map { it.first }) { day ->
                    val on = day == selDay
                    val isToday = day == todayYmd
                    val isWatch = day == watchDayYmd
                    val d = runCatching { LocalDate.parse(day, fmt) }.getOrNull()
                    val week = when (d?.dayOfWeek?.value) {
                        1 -> "星期一"; 2 -> "星期二"; 3 -> "星期三"; 4 -> "星期四"
                        5 -> "星期五"; 6 -> "星期六"; else -> "星期日"
                    }
                    val label = if (isToday) "今日" else week
                    /* ★ 2026-11-10（用户要求，三端统一）：TAB 配色优先级
                     *   ① 正在看的那天 ⇒ 红（离开该 TAB 也保持红）；
                     *   ② 当前选中、但不是正在看的那天 ⇒ 紫；
                     *   ③ 今天（既不是观看日、也没被选中）⇒ 绿（跨天回看时"今日"不再抢红）；
                     *   ④ 其余 ⇒ 灰。 */
                    val fg = when {
                        isWatch -> Palette.NowRed
                        on -> Palette.SelPurple
                        isToday -> Palette.NextGreen
                        else -> Palette.TextDim
                    }
                    val bold = isWatch || on
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(
                                when {
                                    !on -> Color.Transparent
                                    isWatch -> Color(0x33FF4444)
                                    else -> Color(0x33A78BFA)
                                }
                            )
                            .clickable { selDay = day }
                            .padding(horizontal = 10.dp, vertical = 5.dp)
                    ) {
                        Text(
                            label, fontSize = 12.sp, color = fg,
                            fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal
                        )
                        Text(
                            "${d?.monthValue ?: ""}/${d?.dayOfMonth ?: ""}", fontSize = 11.sp, color = fg
                        )
                    }
                }
            }
            Spacer(Modifier.height(6.dp))

            // ---------- 节目列表 ----------
            val now = System.currentTimeMillis() / 1000
            // ★★ 2026-10-22（用户要求）：处于回看/时移时，正在直播的那档**不再用红色**，
            //   只把状态字改成绿色 —— 否则两处都红，看不出主次。
            // ★ 2026-11-10（用户实测）：判据必须是**"当前是否在回看/时移"（全局）**，
            //   不能是"选中这一天里有没有回看中" —— 跨天回看（回看昨天那档、人在今天的 TAB）时
            //   原来会退回红粗，用户要求同样是绿字（文案同时由「直播中」改为「直播」）。
            fun isReplaying(it: Epg.Item) = ui.replayStart > 0L && it.start > 0 &&
                ui.replayStart >= it.start - 5 && ui.replayStart < it.end
            val hasReplay = ui.replayStart > 0L
            LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                itemsIndexed(dayList) { _, it ->
                    val liveOnAir = it.start > 0 && it.end > 0 && now in it.start until it.end
                    val inReplay = isReplaying(it)
                    // 直播中且处于回看/时移 ⇒ 退为次要样式（绿字、不红）
                    val liveSecondary = liveOnAir && hasReplay
                    val ended = it.start > 0 && it.end > 0 && it.end < now
                    // ★ 官方 [10] 为 "2"（版权原因等）⇒ 不给回看
                    val canReplay = ended && it.replayable
                    val canShift = liveOnAir
                    val clickTarget = when {
                        inReplay -> null                    // 已经在这档回看中，无需再点
                        canReplay -> it.start
                        canShift -> now - 300               // 时移：从 5 分钟前起播
                        else -> null
                    }
                    Row(
                        Modifier.fillMaxWidth()
                            .then(
                                if (clickTarget != null)
                                    Modifier.clickable { onReplay(clickTarget) }
                                else Modifier
                            )
                            .padding(vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "${Epg.hhmm(it, true)}-${Epg.hhmm(it, false)}",
                            fontSize = 12.sp,
                            color = when {
                                inReplay -> Color(0xFFFF7B7B)
                                // ★ 2026-11-10：回看/时移时的直播那档 ⇒ **绿**（时间列也跟着变，不能只改标记）
                                liveSecondary -> Palette.NextGreen
                                liveOnAir -> Color(0xFFFF7B7B)
                                else -> Palette.TextDim
                            },
                            modifier = Modifier.width(92.dp)
                        )
                        Text(
                            it.title, fontSize = 13.sp,
                            color = when {
                                inReplay -> Palette.NowRed
                                // ★ 2026-11-10（用户要求）：直播那档在回看/时移时整行**绿粗**，否则红粗
                                liveSecondary -> Palette.NextGreen
                                liveOnAir -> Palette.NowRed
                                else -> Palette.TextBright
                            },
                            fontWeight = if (inReplay || liveOnAir)
                                FontWeight.Bold else FontWeight.Normal,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        // ★ 状态/操作：回看中 > 直播中 > 回看 > 时移 > （不可回看）
                        when {
                            inReplay -> Text(
                                Strings.EPG_IN_REPLAY, fontSize = 12.sp,
                                color = Palette.NowRed, fontWeight = FontWeight.Bold
                            )
                            liveOnAir -> Text(
                                // 处于回看/时移 ⇒ 「直播」（绿粗）；否则「直播中」（红粗）
                                if (liveSecondary) Strings.EPG_LIVE else Strings.EPG_LIVE_NOW,
                                fontSize = 12.sp,
                                color = if (liveSecondary) Palette.NextGreen else Palette.NowRed,
                                fontWeight = FontWeight.Bold
                            )
                            canReplay -> Text(
                                Strings.REPLAY, fontSize = 11.sp, color = Palette.Primary,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(Color(0x1AFFFFFF))
                                    .padding(horizontal = 8.dp, vertical = 3.dp)
                            )
                            canShift -> Text(
                                Strings.TIMESHIFT, fontSize = 11.sp, color = Palette.NextGreen
                            )
                            ended && !it.replayable -> Text(
                                Strings.EPG_NO_REPLAY_ITEM, fontSize = 11.sp, color = Palette.TextDim
                            )
                        }
                    }
                }
            }
        }
    }
}
