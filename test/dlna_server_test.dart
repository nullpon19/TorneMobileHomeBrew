import 'package:flutter_test/flutter_test.dart';
import 'package:tmhb/core/core.dart';

void main() {
  group('Generic DLNA / DTCP-IP server models & discovery classification', () {
    const sampleDdd = '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Living Room Recorder</friendlyName>
    <manufacturer>Example Electronics</manufacturer>
    <modelName>REC-1000</modelName>
    <UDN>uuid:00000000-1111-2222-3333-444455556666</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
        <SCPDURL>/cds.xml</SCPDURL>
        <controlURL>/cds_control</controlURL>
        <eventSubURL>/cds_event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <SCPDURL>/cm.xml</SCPDURL>
        <controlURL>/cm_control</controlURL>
        <eventSubURL>/cm_event</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>''';

    test('parseDeviceDescription identifies non-nasne ContentDirectory server', () {
      final device = parseDeviceDescription(
        sampleDdd,
        Uri.parse('http://192.0.2.50:20003/description.xml'),
      );
      expect(device.isNasne, isFalse);
      expect(isGenericDlnaMediaServer(device), isTrue);
      expect(device.friendlyName, 'Living Room Recorder');
      expect(
        device.controlUrl('urn:schemas-upnp-org:service:ContentDirectory:1'),
        Uri.parse('http://192.0.2.50:20003/cds_control'),
      );
    });

    test('isGenericDlnaMediaServer excludes proprietary DTCP+ endpoints', () {
      const proprietaryDdd = '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Remote Server</friendlyName>
    <modelName>REC-1000</modelName>
    <UDN>uuid:aaaa</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <controlURL>/cds</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-digion-com:service:X_DtcpPlus:1</serviceType>
        <controlURL>/dtcpplus</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final dev = parseDeviceDescription(
        proprietaryDdd,
        Uri.parse('http://192.0.2.50:61100/dms/ddd.xml'),
      );
      expect(isGenericDlnaMediaServer(dev), isFalse);
    });

    test('RegisteredDlnaServer JSON roundtrip preserves fields', () {
      final device = parseDeviceDescription(
        sampleDdd,
        Uri.parse('http://192.0.2.50:20003/description.xml'),
      );
      final server = RegisteredDlnaServer.fromDevice(device);
      final restored = RegisteredDlnaServer.fromJson(server.toJson());
      expect(restored.id, server.id);
      expect(restored.host, '192.0.2.50');
      expect(restored.friendlyName, 'Living Room Recorder');
      expect(
        restored.contentDirectoryControlUrl,
        'http://192.0.2.50:20003/cds_control',
      );
    });

    test('dlnaItemToRecordedTitle filters thumbnail res and maps metadata for Jikkyo', () {
      const didlXml = '''<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:arib="urn:schemas-arib-or-jp:elements-1-0/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
  <item id="9010_/0001/item1" parentID="9010_/0001" restricted="1">
    <dc:title>夕方のニュース特集</dc:title>
    <dc:date>2026-11-26T18:00:00+09:00</dc:date>
    <upnp:channelName>NHK総合</upnp:channelName>
    <upnp:channelNr>1024</upnp:channelNr>
    <arib:objectType>ARIB_TB</arib:objectType>
    <upnp:genre>ニュース／報道</upnp:genre>
    <upnp:longDescription>本編の詳しい番組解説テキスト</upnp:longDescription>
    <res duration="01:00:00" protocolInfo="http-get:*:application/x-dtcp1;DTCP1HOST=192.0.2.50;DTCP1PORT=30000;CONTENTFORMAT=&quot;video/vnd.dlna.mpeg-tts&quot;:DLNA.ORG_OP=10;DLNA.ORG_FLAGS=01110000000000000000000000000000">http://192.0.2.50:10480/content/1</res>
    <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">http://192.0.2.50:10480/thumb/1.jpg</res>
  </item>
</DIDL-Lite>''';
      final doc = parseDidl(didlXml, 'test');
      expect(doc.items, hasLength(1));

      final title = dlnaItemToRecordedTitle(doc.items.first);
      expect(title.title, '夕方のニュース特集');
      expect(title.channelName, 'NHK総合');
      expect(title.channel?.broadcastingType, 2);
      expect(title.scheduledStart, DateTime.parse('2026-11-26T18:00:00+09:00'));
      expect(title.scheduledDurationSeconds, 3600);
      expect(title.res, hasLength(1));
      expect(title.res.first.url, 'http://192.0.2.50:10480/content/1');

      final jkMatch = resolveJikkyoChannel(
        settings: const JikkyoSettings(),
        broadcastingType: title.channel?.broadcastingType,
        channelName: title.channelName,
      );
      expect(jkMatch.hasChannel, isTrue);
      expect(jkMatch.jkId, 'jk1');
    });

    test('parseDlnaNptSeconds parses both HH:MM:SS.mmm and decimal seconds', () {
      expect(DtcpMediaFetcher.parseDlnaNptSeconds('01:45:02.000'), 6302.0);
      expect(DtcpMediaFetcher.parseDlnaNptSeconds('00:05:30'), 330.0);
      expect(DtcpMediaFetcher.parseDlnaNptSeconds('600.250'), 600.25);
      expect(DtcpMediaFetcher.parseDlnaNptSeconds('*'), isNull);
    });
  });
}
