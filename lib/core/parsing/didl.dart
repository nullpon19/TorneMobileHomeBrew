/// DIDL-Lite parsing (plan 11.8 / 12.5).
library;

import 'package:xml/xml.dart';

import '../broadcast_text.dart';
import '../errors.dart';
import '../models/didl.dart';
import '../models/live_channel.dart';
import '../models/title.dart';
import '../time_util.dart';
import '../transport/xml_util.dart';

/// Parses a DIDL-Lite document string (the `Result` of a Browse).
DidlDocument parseDidl(String xmlText, String source) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } catch (e) {
    throw NasneError.parse(source, cause: e);
  }
  final root = doc.rootElement;
  if (root.name.local != 'DIDL-Lite') {
    throw NasneError.parse(source, cause: 'root element is not <DIDL-Lite>');
  }

  final containers = <DidlContainer>[];
  for (final el in childElements(root, 'container')) {
    containers.add(DidlContainer(
      id: el.getAttribute('id') ?? '',
      parentId: el.getAttribute('parentID') ?? '',
      title: normalizeBroadcastText(childText(el, 'title') ?? ''),
      childCount: int.tryParse(el.getAttribute('childCount') ?? ''),
    ));
  }

  final items = <DidlItem>[];
  for (final el in childElements(root, 'item')) {
    items.add(_parseItem(el));
  }
  return DidlDocument(containers: containers, items: items);
}

DidlItem _parseItem(XmlElement el) {
  final properties = <String, String>{};
  final resList = <TitleRes>[];
  String? description;
  String? longDescription;
  String? channelName;
  int? channelNr;
  int? cogCount;

  for (final child in el.childElements) {
    final qualified = child.name.qualified;
    final text = child.innerText;
    switch (child.name.local) {
      case 'res':
        resList.add(_parseRes(child));
      case 'description':
        description = normalizeBroadcastText(text);
        properties[qualified] = text;
      case 'longDescription':
        // Two entries exist (synopsis / credits); keep both, joined.
        longDescription = longDescription == null
            ? normalizeBroadcastText(text)
            : '$longDescription\n${normalizeBroadcastText(text)}';
        properties.putIfAbsent(qualified, () => text);
      case 'channelName':
        channelName = normalizeBroadcastText(text);
        properties[qualified] = text;
      case 'channelNr':
        channelNr = int.tryParse(text.trim());
        properties[qualified] = text;
      case 'COGCount':
        cogCount = int.tryParse(text.trim());
        properties[qualified] = text;
      default:
        properties.putIfAbsent(qualified, () => text);
    }
  }

  return DidlItem(
    id: el.getAttribute('id') ?? '',
    parentId: el.getAttribute('parentID') ?? '',
    title: normalizeBroadcastText(childText(el, 'title') ?? ''),
    date: properties['dc:date'],
    description: description,
    longDescription: longDescription,
    channelName: channelName,
    channelNr: channelNr,
    copyCountRemaining: cogCount,
    res: resList,
    properties: properties,
  );
}

/// Converts one LiveTuner DIDL item into a [LiveChannel]
/// (plan 39). The channel identity rides in the item id's query
/// (`ch?nid=7880&tsid=7880&svid=de00`, hex — the same space as
/// `channelListGet`'s decimal ids, verified in the live survey);
/// the current programme's genre and scheduled times ride in the
/// `upnp:` properties the generic item parse retains.
LiveChannel liveChannelFromDidl(DidlItem item) {
  int? hexParam(String name) {
    final q = item.id.indexOf('?');
    if (q < 0) return null;
    for (final pair in item.id.substring(q + 1).split('&')) {
      final eq = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq) == name) {
        return int.tryParse(pair.substring(eq + 1), radix: 16);
      }
    }
    return null;
  }

  DateTime? timeProp(String key) {
    final raw = item.properties[key];
    return parseJstDateTime(raw);
  }

  return LiveChannel(
    id: item.id,
    bandId: item.parentId,
    networkId: hexParam('nid'),
    transportStreamId: hexParam('tsid'),
    serviceId: hexParam('svid'),
    channelName: item.channelName,
    channelNr: item.channelNr,
    genre: item.properties['upnp:genre'],
    programTitle: item.title,
    description: item.description,
    longDescription: item.longDescription,
    programStart: timeProp('upnp:scheduledStartTime'),
    programEnd: timeProp('upnp:scheduledEndTime'),
    res: item.res,
  );
}

TitleRes _parseRes(XmlElement el) {
  final url = el.innerText.trim();
  final protocolInfo = el.getAttribute('protocolInfo') ?? '';

  String? protocolParam(String name) {
    final m = RegExp('$name=([^;:]*)').firstMatch(protocolInfo);
    return m?.group(1);
  }

  Duration? duration;
  final durationText = el.getAttribute('duration');
  if (durationText != null) {
    final parts = durationText.split(':');
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = double.tryParse(parts[2]);
      if (h != null && m != null && s != null && h >= 0 && m >= 0 && s.isFinite && s >= 0) {
        duration = Duration(
          hours: h,
          minutes: m,
          seconds: s.floor(),
          milliseconds: ((s - s.floor()) * 1000).round(),
        );
      }
    }
  }

  String? quality;
  final uri = Uri.tryParse(url);
  if (uri != null) quality = uri.queryParameters['quality'];

  return TitleRes(
    url: url,
    protocolInfo: protocolInfo,
    dtcpHost: protocolParam('DTCP1HOST'),
    dtcpPort: int.tryParse(protocolParam('DTCP1PORT') ?? ''),
    duration: duration,
    cleartextSize: int.tryParse(el.getAttribute('dlna:cleartextSize') ??
        el.getAttribute('cleartextSize') ??
        ''),
    quality: quality,
  );
}
