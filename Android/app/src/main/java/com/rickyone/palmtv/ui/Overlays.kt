package com.rickyone.palmtv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.Epg
import kotlinx.coroutines.delay

/** 免责声明弹窗（首启：同意/不同意退出；再次查看：只有"关闭"） */
@Composable
fun DisclaimerModal(ui: UiState, onAgree: () -> Unit, onRefuse: () -> Unit, onClose: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color(0xCC000000)),
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier.fillMaxWidth(0.86f).clip(RoundedCornerShape(14.dp))
                .background(Palette.DisclaimerBg).padding(16.dp)
        ) {
            Text(Strings.DISC_TITLE, fontSize = 16.sp, color = Palette.TextBright,
                fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
                Text(Strings.DISC_TEXT, fontSize = 12.sp, color = Color(0xFFCCCCCC), lineHeight = 18.sp)
                Spacer(Modifier.height(10.dp))
                Text(Config.CONTACT_LABEL + Config.CONTACT_EMAIL, fontSize = 12.sp, color = Palette.LinkBlue)
                Spacer(Modifier.height(8.dp))
                Text(
                    if (ui.disclaimerReadOnly) Strings.DISC_AGREED_NOTE else Strings.DISC_FIRST_NOTE,
                    fontSize = 11.sp, color = Palette.TextDim
                )
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                if (!ui.disclaimerReadOnly) {
                    Text(Strings.DISC_REFUSE, fontSize = 14.sp, color = Palette.TextMid,
                        modifier = Modifier.clickable { onRefuse() }.padding(10.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(Strings.DISC_AGREE, fontSize = 14.sp, color = Palette.Primary,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.clickable { onAgree() }.padding(10.dp))
                } else {
                    Text(Strings.CLOSE, fontSize = 14.sp, color = Palette.Primary,
                        modifier = Modifier.clickable { onClose() }.padding(10.dp))
                }
            }
        }
    }
}
