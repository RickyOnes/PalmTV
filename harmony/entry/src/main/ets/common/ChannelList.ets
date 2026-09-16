/**
 * ChannelList - 源站频道列表（★ 权威来源）
 * 桌面版 PlayerService.cs Channels 已按本文件全量回灌对齐 (2026-09-04)。
 * 切换频道时以 Pid 走 /auth + /get-live-info 全流程。
 */

export interface TvChannel {
  id: string;
  name: string;
  pid: string;
  cnlId: string;
  group: 'cctv' | 'satellite' | 'local';  // 分组：CCTV / 卫视频道 / 地方频道
}

export const Channels: TvChannel[] = [
  // ===== CCTV 组（默认）=====
  { id: 'cctv1', name: 'CCTV-1 综合', pid: '600001859', cnlId: '2024078203', group: 'cctv' },
  { id: 'cctv2', name: 'CCTV-2 财经', pid: '600001800', cnlId: '2024075403', group: 'cctv' },
  { id: 'cctv3', name: 'CCTV-3 综艺', pid: '600001801', cnlId: '2024068503', group: 'cctv' },
  { id: 'cctv4', name: 'CCTV-4 中文国际', pid: '600001814', cnlId: '2029797103', group: 'cctv' },
  { id: 'cctv5', name: 'CCTV-5 体育', pid: '600001818', cnlId: '2024078403', group: 'cctv' },
  { id: 'cctv5p', name: 'CCTV-5+ 赛事', pid: '600001817', cnlId: '2024078003', group: 'cctv' },
  { id: 'cctv6', name: 'CCTV-6 电影', pid: '600108442', cnlId: '2013693901', group: 'cctv' },
  { id: 'cctv7', name: 'CCTV-7 军事', pid: '600004092', cnlId: '2024072003', group: 'cctv' },
  { id: 'cctv8', name: 'CCTV-8 电视剧', pid: '600001803', cnlId: '2029793003', group: 'cctv' },
  { id: 'cctv9', name: 'CCTV-9 纪录', pid: '600004078', cnlId: '2024078603', group: 'cctv' },
  { id: 'cctv10', name: 'CCTV-10 科教', pid: '600001805', cnlId: '2024078703', group: 'cctv' },
  { id: 'cctv11', name: 'CCTV-11 戏曲', pid: '600001806', cnlId: '2027248703', group: 'cctv' },
  { id: 'cctv12', name: 'CCTV-12 社会与法', pid: '600001807', cnlId: '2027248803', group: 'cctv' },
  { id: 'cctv13', name: 'CCTV-13 新闻', pid: '600001811', cnlId: '2029797203', group: 'cctv' },
  { id: 'cctv14', name: 'CCTV-14 少儿', pid: '600001809', cnlId: '2027248903', group: 'cctv' },
  { id: 'cctv15', name: 'CCTV-15 音乐', pid: '600001815', cnlId: '2027249003', group: 'cctv' },
  { id: 'cctv16', name: 'CCTV-16 奥林匹克', pid: '600098637', cnlId: '2027249103', group: 'cctv' },
  { id: 'cctv16k', name: 'CCTV-16(4K)', pid: '600099502', cnlId: '2027249303', group: 'cctv' },
  { id: 'cctv17', name: 'CCTV-17 农业', pid: '600001810', cnlId: '2027249403', group: 'cctv' },
  { id: 'cctv4k', name: 'CCTV-4K 超高清', pid: '600002264', cnlId: '2029810303', group: 'cctv' },
  { id: 'cctv8k', name: 'CCTV-8K', pid: '600156816', cnlId: '2026774121', group: 'cctv' },
  { id: 'cetv1', name: '中国教育1台', pid: '600171827', cnlId: '2022823801', group: 'cctv' },
  { id: 'cgne', name: 'CGN英文台', pid: '600014550', cnlId: '2024181703', group: 'cctv' },
  // ===== 卫视频道组 =====
  { id: 'jsws', name: '江苏卫视', pid: '600002521', cnlId: '2024171103', group: 'satellite' },
  { id: 'hnws', name: '湖南卫视', pid: '600002475', cnlId: '2024054803', group: 'satellite' },
  { id: 'zjws', name: '浙江卫视', pid: '600002520', cnlId: '2024054703', group: 'satellite' },
  { id: 'bjws', name: '北京卫视', pid: '600002309', cnlId: '2024052703', group: 'satellite' },
  { id: 'dfws', name: '东方卫视', pid: '600002483', cnlId: '2024054503', group: 'satellite' },
  { id: 'henws', name: '河南卫视', pid: '600002525', cnlId: '2029797303', group: 'satellite' },
  { id: 'hebws', name: '河北卫视', pid: '600002493', cnlId: '2024171503', group: 'satellite' },
  { id: 'ahws', name: '安徽卫视', pid: '600002532', cnlId: '2024171403', group: 'satellite' },
  { id: 'tjws', name: '天津卫视', pid: '600152137', cnlId: '2019927003', group: 'satellite' },
  { id: 'sdws', name: '山东卫视', pid: '600002513', cnlId: '2029787903', group: 'satellite' },
  { id: 'sxws', name: '山西卫视', pid: '600190407', cnlId: '2025560803', group: 'satellite' },
  { id: 'dnws', name: '东南卫视', pid: '600002484', cnlId: '2024061503', group: 'satellite' },
  { id: 'hbws', name: '湖北卫视', pid: '600002508', cnlId: '2024171203', group: 'satellite' },
  { id: 'jxws', name: '江西卫视', pid: '600002503', cnlId: '2024061703', group: 'satellite' },
  { id: 'shxws', name: '陕西卫视', pid: '600190400', cnlId: '2029795103', group: 'satellite' },
  { id: 'lnws', name: '辽宁卫视', pid: '600002505', cnlId: '2024171303', group: 'satellite' },
  { id: 'jlws', name: '吉林卫视', pid: '600190405', cnlId: '2025561503', group: 'satellite' },
  { id: 'hebs', name: '黑龙江卫视', pid: '600002498', cnlId: '2029797003', group: 'satellite' },
  { id: 'ynws', name: '云南卫视', pid: '600190402', cnlId: '2025561303', group: 'satellite' },
  { id: 'gzws', name: '贵州卫视', pid: '600002490', cnlId: '2024061603', group: 'satellite' },
  { id: 'scws', name: '四川卫视', pid: '600002516', cnlId: '2024061403', group: 'satellite' },
  { id: 'cqws', name: '重庆卫视', pid: '600002531', cnlId: '2024061103', group: 'satellite' },
  { id: 'hainanws', name: '海南卫视', pid: '600002506', cnlId: '2024055603', group: 'satellite' },
  { id: 'gdws', name: '广东卫视', pid: '600002485', cnlId: '2024060903', group: 'satellite' },
  { id: 'gxws', name: '广西卫视', pid: '600002509', cnlId: '2024060703', group: 'satellite' },
  { id: 'szws', name: '深圳卫视', pid: '600002481', cnlId: '2024061303', group: 'satellite' },
  { id: 'nmgws', name: '内蒙古卫视', pid: '600190401', cnlId: '2025561203', group: 'satellite' },
  { id: 'gansuws', name: '甘肃卫视', pid: '600190408', cnlId: '2025561703', group: 'satellite' },
  { id: 'qhws', name: '青海卫视', pid: '600190406', cnlId: '2025559103', group: 'satellite' },
  { id: 'xzws', name: '西藏卫视', pid: '600190403', cnlId: '2025558003', group: 'satellite' },
  { id: 'xinjiangws', name: '新疆卫视', pid: '600152138', cnlId: '2019927403', group: 'satellite' },
  { id: 'ningxiaws', name: '宁夏卫视', pid: '600190737', cnlId: '2025608503', group: 'satellite' },
  // ===== 地方频道组（待实现：占位，无真实 PID/cnlId）=====
  // 后续补全国各省、市级台：pid/cnlId 需从官方源获取，并经 /auth + /get-live-info 全流程验证
  // 占位示例结构：
  // { id: 'bjcity', name: '北京卫视-市', pid: 'TBD', cnlId: 'TBD', group: 'local' },
];

/** 按分组筛选频道 */
export function channelsByGroup(g: 'cctv' | 'satellite' | 'local'): TvChannel[] {
  return Channels.filter((c) => c.group === g);
}

/**
 * 频道 id → media 图标资源名（resources/base/media 下的文件名，不含扩展名）。
 * 用于鸿蒙系统媒体控制卡片左上角频道图标。缺失图标的频道返回空字符串。
 */
// ★ media 资源名只允许 [a-zA-Z0-9_]，频道图标文件已按此规则命名。
const CHANNEL_ICONS: Record<string, string> = {
  // CCTV 组
  'cctv1': 'cctv_1',
  'cctv2': 'cctv_2',
  'cctv3': 'cctv_3',
  'cctv4': 'cctv_4',
  'cctv5': 'cctv_5',
  'cctv5p': 'cctv_5p',
  'cctv6': 'cctv_6',
  'cctv7': 'cctv_7',
  'cctv8': 'cctv_8',
  'cctv9': 'cctv_9',
  'cctv10': 'cctv_10',
  'cctv11': 'cctv_11',
  'cctv12': 'cctv_12',
  'cctv13': 'cctv_13',
  'cctv14': 'cctv_14',
  'cctv15': 'cctv_15',
  'cctv16': 'cctv_16',
  'cctv16k': 'cctv_16p',
  'cctv17': 'cctv_17',
  'cctv4k': 'cctv_4k',
  'cctv8k': 'cctv_8k',
  'cetv1': 'cetv_1',
  'cgne': 'CGTN',
  // 卫视频道
  'jsws': 'jiangsu_ws',
  'hnws': 'hunan_ws',
  'zjws': 'zhejiang_ws',
  'bjws': 'beijing_ws',
  'dfws': 'dongfang_ws',
  'szws': 'shenzhen_ws',
  'ahws': 'anhui_ws',
  'gdws': 'guangdong_ws',
  'tjws': 'tianjin_ws',
  'hbws': 'hubei_ws',
  'sdws': 'shandong_ws',
  'dnws': 'dongnan_ws',
  'hebs': 'heilongjiang_ws',
  'lnws': 'liaoning_ws',
  'sxws': 'shanxi_ws',
  'jxws': 'jiangxi_ws',
  'jlws': 'jilin_ws',
  'shxws': 'shaanxi_ws',
  'ynws': 'yunnan_ws',
  'scws': 'sichuan_ws',
  'gxws': 'guangxi_ws',
  'gzws': 'guizhou_ws',
  'hebws': 'hebei_ws',
  'hainanws': 'hainan_ws',
  'cqws': 'chongqing_ws',
  'henws': 'henan_ws',
  'gansuws': 'gansu_ws',
  'qhws': 'qinghai_ws',
  'xzws': 'xizang_ws',
  'xinjiangws': 'xinjiang_ws',
  'ningxiaws': 'ningxia_ws',
  'nmgws': 'neimenggu_ws'
};

/** 按频道 id 获取 media 图标资源名；无图标返回空字符串 */
export function channelIcon(id: string): string {
  return CHANNEL_ICONS[id] ?? '';
}
