/// Channel auto/manual mapping and fuzzy programme-title mismatch detection
/// for Niconico Jikkyo integration (Phase 40).
library;

import 'jikkyo_models.dart';

enum JikkyoMatchSource {
  manual,
  disabled,
  autoServiceId,
  autoStationName,
  autoRemoteKey,
  unmatched,
}

class JikkyoChannelMatch {
  const JikkyoChannelMatch({
    required this.jkId,
    required this.source,
    required this.overrideKey,
    required this.displayLabel,
  });

  final String? jkId;
  final JikkyoMatchSource source;
  final String overrideKey;
  final String displayLabel;

  bool get isDisabled => source == JikkyoMatchSource.disabled;
  bool get hasChannel => jkId != null && !isDisabled;

  JikkyoChannelDef? get channelDef => jikkyoChannelById(jkId);
}

String _toHalfwidthAscii(String input) {
  final sb = StringBuffer();
  for (final rune in input.runes) {
    if (rune == 0x3000) {
      sb.writeCharCode(0x20);
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      sb.writeCharCode(rune - 0xFEE0);
    } else {
      sb.writeCharCode(rune);
    }
  }
  return sb.toString();
}

String normalizeJikkyoStationText(String raw) {
  return _toHalfwidthAscii(raw)
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_・･\.]+'), '');
}

String jikkyoOverrideKey({int? serviceId, String? channelName}) {
  if (serviceId != null && serviceId > 0) {
    return 'sid:$serviceId';
  }
  final norm = normalizeJikkyoStationText(channelName ?? '');
  return norm.isNotEmpty ? 'name:$norm' : 'unknown';
}

const Map<int, String> _bsCsServiceIdToJk = {
  101: 'jk101',
  102: 'jk101',
  103: 'jk103',
  104: 'jk103',
  141: 'jk141',
  142: 'jk141',
  143: 'jk141',
  151: 'jk151',
  152: 'jk151',
  153: 'jk151',
  161: 'jk161',
  162: 'jk161',
  163: 'jk161',
  171: 'jk171',
  172: 'jk171',
  173: 'jk171',
  181: 'jk181',
  182: 'jk181',
  183: 'jk181',
  191: 'jk191',
  192: 'jk192',
  193: 'jk193',
  200: 'jk200',
  201: 'jk201',
  211: 'jk211',
  222: 'jk222',
  236: 'jk236',
  252: 'jk252',
  260: 'jk260',
  263: 'jk263',
  265: 'jk265',
  333: 'jk333',
  991: 'jk991',
  992: 'jk992',
};

const List<({String jkId, List<String> keywords})> _bsCsStationKeywords = [
  (jkId: 'jk103', keywords: ['プレミアム4k', 'bsp4k', 'bs4k']),
  (jkId: 'jk141', keywords: ['bs日テレ']),
  (jkId: 'jk151', keywords: ['bs朝日']),
  (jkId: 'jk161', keywords: ['bstbs']),
  (jkId: 'jk171', keywords: ['bsテレ東', 'bsジャパン']),
  (jkId: 'jk181', keywords: ['bsフジ']),
  (jkId: 'jk191', keywords: ['wowowプライム', 'wowowprime']),
  (jkId: 'jk192', keywords: ['wowowライブ', 'wowowlive']),
  (jkId: 'jk193', keywords: ['wowowシネマ', 'wowowcinema']),
  (jkId: 'jk252', keywords: ['wowowプラス', 'wowowplus', 'シネフィル']),
  (jkId: 'jk201', keywords: ['bs10スターチャンネル', 'スターチャンネル', 'star']),
  (jkId: 'jk200', keywords: ['bs10']),
  (jkId: 'jk211', keywords: ['bs11', 'イレブン']),
  (jkId: 'jk222', keywords: ['bs12', 'トゥエルビ']),
  (jkId: 'jk101', keywords: ['nhkbs', 'bsプレミアム', 'bs1']),
  (jkId: 'jk236', keywords: ['アニマックス', 'animax']),
  (jkId: 'jk260', keywords: ['bs松竹東急', 'jcombs', 'j:combs']),
  (jkId: 'jk263', keywords: ['bsjapanext', 'ジャパネクスト']),
  (jkId: 'jk265', keywords: ['bsよしもと', 'よしもと']),
  (jkId: 'jk333', keywords: ['atx', 'アニメシアター']),
];

const List<({String jkId, List<String> keywords})> _terrestrialStationKeywords =
    [
      // Independent UHF stations first (specific matches)
      (jkId: 'jk9', keywords: ['tokyomx', '東京mx', 'mxテレビ']),
      (jkId: 'jk10', keywords: ['テレ玉', 'テレビ埼玉', 'tvs']),
      (jkId: 'jk11', keywords: ['tvk', 'テレビ神奈川']),
      (jkId: 'jk12', keywords: ['チバテレ', '千葉テレビ', 'ちばテレビ']),
      (jkId: 'jk13', keywords: ['サンテレビ', 'suntv']),
      (jkId: 'jk14', keywords: ['kbs京都', '京都テレビ']),
      // NHK
      (jkId: 'jk2', keywords: ['nhkeテレ', 'eテレ', 'nhk教育']),
      (jkId: 'jk1', keywords: ['nhk総合']),
      // Nippon TV network (jk4)
      (
        jkId: 'jk4',
        keywords: [
          '日本テレビ',
          '日テレ',
          '読売テレビ',
          'ytv',
          '中京テレビ',
          'ctv',
          '札幌テレビ',
          'stv',
          '福岡放送',
          'fbs',
          'ミヤギテレビ',
          'ミヤテレ',
          '秋田放送',
          'abs',
          'テレビ岩手',
          'tvi',
          '山形放送',
          'ybc',
          '福島中央',
          'テレビ新潟',
          'teny',
          'テレビ信州',
          '山梨放送',
          'ybs',
          '静岡第一',
          'sdt',
          '北日本放送',
          'knb',
          'テレビ金沢',
          '福井放送',
          'fbc',
          '広島テレビ',
          'htv',
          '山口放送',
          '四国放送',
          'jrt',
          '西日本放送',
          'rnc',
          '南海放送',
          'rnb',
          '高知放送',
          'rkc',
          '長崎国際',
          'nib',
          'くまもと県民',
          'kkt',
          '鹿児島読売',
          'kyt',
          '日本海テレビ',
          'nkt',
        ],
      ),
      // TV Asahi network (jk5)
      (
        jkId: 'jk5',
        keywords: [
          'テレビ朝日',
          'テレ朝',
          '朝日放送',
          'abcテレビ',
          'abc',
          'メ~テレ',
          'メーテレ',
          '名古屋テレビ',
          '北海道テレビ',
          'htb',
          '九州朝日放送',
          'kbc',
          '東日本放送',
          'khb',
          '青森朝日',
          '岩手朝日',
          'iat',
          '秋田朝日',
          'aab',
          '山形テレビ',
          'yts',
          '福島放送',
          '新潟テレビ21',
          'ux',
          '長野朝日',
          'abn',
          '静岡朝日',
          'satv',
          '北陸朝日',
          '広島ホーム',
          '瀬戸内海放送',
          'ksb',
          '山口朝日',
          '愛媛朝日',
          'eat',
          '長崎文化放送',
          'ncc',
          '熊本朝日',
          'kab',
          '大分朝日',
          'oab',
          '鹿児島放送',
          'kkb',
          '琉球朝日',
          'qab',
        ],
      ),
      // TBS network (jk6)
      (
        jkId: 'jk6',
        keywords: [
          'tbs',
          '毎日放送',
          'mbs',
          'cbcテレビ',
          'cbc',
          '北海道放送',
          'hbc',
          'rkb毎日',
          'rkb',
          '東北放送',
          'tbc',
          '青森テレビ',
          'ibc岩手',
          'テレビユー山形',
          'tuy',
          'テレビユー福島',
          'tuf',
          '新潟放送',
          'bsn',
          '信越放送',
          'sbc',
          'テレビ山梨',
          'uty',
          '静岡放送',
          'sbs',
          'チューリップテレビ',
          '北陸放送',
          'mro',
          'rsk山陽',
          '山陽放送',
          '中国放送',
          'rcc',
          '山陰放送',
          'bss',
          'テレビ山口',
          'tys',
          'あいテレビ',
          'itv',
          'テレビ高知',
          'kutv',
          '長崎放送',
          'nbc',
          '熊本放送',
          'rkk',
          '大分放送',
          'obs',
          '宮崎放送',
          'mrt',
          '南日本放送',
          'mbc',
          '琉球放送',
          'rbc',
          'テレビ大分',
          'tos',
        ],
      ),
      // TV Tokyo network (jk7)
      (
        jkId: 'jk7',
        keywords: [
          'テレビ東京',
          'テレ東',
          'テレビ大阪',
          'tvo',
          'テレビ愛知',
          'tva',
          'テレビ北海道',
          'tvh',
          'tvq九州',
          'テレq',
          'テレビせとうち',
          'tsc',
        ],
      ),
      // Fuji TV network (jk8)
      (
        jkId: 'jk8',
        keywords: [
          'フジテレビ',
          '関西テレビ',
          'カンテレ',
          'ktv',
          '東海テレビ',
          '北海道文化放送',
          'uhb',
          'テレビ西日本',
          'tnc',
          '仙台放送',
          '秋田テレビ',
          'akt',
          '岩手めんこい',
          'mit',
          'さくらんぼテレビ',
          'say',
          '福島テレビ',
          'ftv',
          'nst新潟',
          '新潟総合',
          '長野放送',
          'nbs',
          'テレビ静岡',
          'sut',
          '富山テレビ',
          'bbt',
          '石川テレビ',
          'itc',
          '福井テレビ',
          'ftb',
          '山陰中央',
          'tsk',
          '岡山放送',
          'ohk',
          'テレビ新広島',
          'tss',
          'テレビ愛媛',
          'ebc',
          '高知さんさん',
          'kss',
          'サガテレビ',
          'sts',
          'テレビ長崎',
          'ktn',
          'テレビ熊本',
          'tku',
          'テレビ宮崎',
          'umk',
          '鹿児島テレビ',
          'kts',
          '沖縄テレビ',
          'otv',
        ],
      ),
    ];

const Map<int, String> _terrestrialRemoteKeyToJk = {
  1: 'jk1',
  2: 'jk2',
  4: 'jk4',
  5: 'jk5',
  6: 'jk6',
  7: 'jk7',
  8: 'jk8',
  9: 'jk9',
};

int? extractRemoteControlKeyFromNumber(String? channelNumber) {
  if (channelNumber == null || channelNumber.trim().isEmpty) return null;
  final digits = RegExp(r'\d+').firstMatch(channelNumber)?.group(0);
  if (digits == null) return null;
  final numVal = int.tryParse(digits);
  if (numVal == null || numVal <= 0) return null;
  if (numVal <= 12) return numVal;
  // Standard Japanese 3-digit terrestrial number: 011..129 -> leading digits ~/ 10.
  if (numVal >= 10 && numVal <= 129) {
    return numVal ~/ 10;
  }
  return null;
}

bool _isBsOrCs({
  int? broadcastingType,
  String? bandId,
  int? networkId,
  int? serviceId,
  String? normName,
}) {
  if (broadcastingType == 3 || broadcastingType == 4) return true;
  final upperBand = bandId?.toUpperCase() ?? '';
  if (upperBand.contains('BS') || upperBand.contains('CS')) return true;
  if (networkId == 4 || networkId == 6 || networkId == 7) return true;
  if (serviceId != null && serviceId >= 100 && serviceId <= 999) return true;
  if (normName != null &&
      (normName.startsWith('bs') ||
          normName.contains('wowow') ||
          normName.contains('nhkbs') ||
          normName.contains('atx'))) {
    return true;
  }
  return false;
}

/// Resolves which NX-Jikkyo channel ID corresponds to a nasne channel.
JikkyoChannelMatch resolveJikkyoChannel({
  required JikkyoSettings settings,
  int? broadcastingType,
  String? bandId,
  int? networkId,
  int? serviceId,
  String? channelNumber,
  String? channelName,
}) {
  final sidKey = (serviceId != null && serviceId > 0) ? 'sid:$serviceId' : null;
  final normName = normalizeJikkyoStationText(channelName ?? '');
  final nameKey = normName.isNotEmpty ? 'name:$normName' : null;
  final primaryKey = sidKey ?? nameKey ?? 'unknown';
  final displayLabel =
      (channelName != null && channelName.trim().isNotEmpty)
          ? channelName.trim()
          : (sidKey ?? 'チャンネル');

  // 1. User manual overrides (serviceId key checked before name key).
  final overrideValue =
      (sidKey != null ? settings.channelOverrides[sidKey] : null) ??
      (nameKey != null ? settings.channelOverrides[nameKey] : null);
  final matchedOverrideKey =
      (sidKey != null && settings.channelOverrides.containsKey(sidKey))
          ? sidKey
          : (nameKey != null && settings.channelOverrides.containsKey(nameKey))
              ? nameKey
              : primaryKey;
  if (overrideValue == kJikkyoDisabledId) {
    return JikkyoChannelMatch(
      jkId: null,
      source: JikkyoMatchSource.disabled,
      overrideKey: matchedOverrideKey,
      displayLabel: displayLabel,
    );
  }
  if (overrideValue != null && jikkyoChannelById(overrideValue) != null) {
    return JikkyoChannelMatch(
      jkId: overrideValue,
      source: JikkyoMatchSource.manual,
      overrideKey: matchedOverrideKey,
      displayLabel: displayLabel,
    );
  }

  // 2. BS / CS matching via serviceId first, then station name keywords.
  if (_isBsOrCs(
    broadcastingType: broadcastingType,
    bandId: bandId,
    networkId: networkId,
    serviceId: serviceId,
    normName: normName,
  )) {
    if (serviceId != null) {
      final bySid = _bsCsServiceIdToJk[serviceId];
      if (bySid != null) {
        return JikkyoChannelMatch(
          jkId: bySid,
          source: JikkyoMatchSource.autoServiceId,
          overrideKey: primaryKey,
          displayLabel: displayLabel,
        );
      }
    }
    if (normName.isNotEmpty) {
      for (final rule in _bsCsStationKeywords) {
        for (final kw in rule.keywords) {
          if (normName.contains(normalizeJikkyoStationText(kw))) {
            return JikkyoChannelMatch(
              jkId: rule.jkId,
              source: JikkyoMatchSource.autoStationName,
              overrideKey: primaryKey,
              displayLabel: displayLabel,
            );
          }
        }
      }
    }
    return JikkyoChannelMatch(
      jkId: null,
      source: JikkyoMatchSource.unmatched,
      overrideKey: primaryKey,
      displayLabel: displayLabel,
    );
  }

  // 3. Terrestrial station name keyword match BEFORE remote key
  //    (critical for Kansai 4=MBS/6=ABC/10=YTV and regional affiliates).
  if (normName.isNotEmpty) {
    for (final rule in _terrestrialStationKeywords) {
      for (final kw in rule.keywords) {
        if (normName.contains(normalizeJikkyoStationText(kw))) {
          return JikkyoChannelMatch(
            jkId: rule.jkId,
            source: JikkyoMatchSource.autoStationName,
            overrideKey: primaryKey,
            displayLabel: displayLabel,
          );
        }
      }
    }
  }

  // 4. Fallback to remote control key number (e.g. 011..091).
  final remoteKey = extractRemoteControlKeyFromNumber(channelNumber);
  if (remoteKey != null) {
    final byRemote = _terrestrialRemoteKeyToJk[remoteKey];
    if (byRemote != null) {
      return JikkyoChannelMatch(
        jkId: byRemote,
        source: JikkyoMatchSource.autoRemoteKey,
        overrideKey: primaryKey,
        displayLabel: displayLabel,
      );
    }
  }

  return JikkyoChannelMatch(
    jkId: null,
    source: JikkyoMatchSource.unmatched,
    overrideKey: primaryKey,
    displayLabel: displayLabel,
  );
}

final RegExp _aribTagPattern = RegExp(
  r'\[(字|新|終|再|生|デ|二|多|解|無|手|S|SS|HV|W|B|N|初|前|後|映|吹|声|P|SD|MV|天|交|料|販|PPV|ほか)\]',
);

/// Normalizes programme titles from nasne / NX-Jikkyo for loose matching.
String normalizeJikkyoTitleForCompare(String raw) {
  var text = _toHalfwidthAscii(raw);
  text = text.replaceAll(_aribTagPattern, '');
  // Strip Unicode enclosed CJK / alnum symbols often used in ARIB titles.
  final filtered = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x1F100 && rune <= 0x1F2FF) continue;
    filtered.writeCharCode(rune);
  }
  return filtered
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[【】\[\]（）\(\)「」『』＜＞<>〈〉《》・･、。!！?？\s\-_:：/／~〜～]+'), '');
}

Set<String> _bigrams(String text) {
  if (text.length < 2) return {text};
  final out = <String>{};
  for (var i = 0; i < text.length - 1; i++) {
    out.add(text.substring(i, i + 2));
  }
  return out;
}

/// Returns true only when both titles are substantial AND clearly diverge
/// (helpful for catching local station overrides or delayed-net broadcasts).
bool isJikkyoProgramLikelyDifferent({
  required String nasneTitle,
  required String jikkyoTitle,
}) {
  final a = normalizeJikkyoTitleForCompare(nasneTitle);
  final b = normalizeJikkyoTitleForCompare(jikkyoTitle);
  if (a.length < 3 || b.length < 3) return false;
  if (a.contains(b) || b.contains(a)) return false;

  final bgA = _bigrams(a);
  final bgB = _bigrams(b);
  var overlap = 0;
  for (final g in bgA) {
    if (bgB.contains(g)) overlap++;
  }
  final dice = (2.0 * overlap) / (bgA.length + bgB.length);
  return dice < 0.25;
}
