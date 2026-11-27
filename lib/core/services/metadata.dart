/// MetadataService implementations (plan 12.1 / 12.8 / 21).
///
/// The boundary is composite: ContentDirectory Browse stays with
/// the DLNA implementation, while the programme guide and channel
/// logos are served by the WebAPI EPG implementation
/// (services/epg.dart). Callers see only MetadataService.
library;

import 'dart:isolate';

import '../endpoints.dart';
import '../errors.dart';
import '../models/channel.dart';
import '../models/didl.dart';
import '../models/epg.dart';
import '../parsing/didl.dart';
import '../transport/soap_transport.dart';
import 'epg.dart';
import 'interfaces.dart';
import 'paged_list.dart';

const int _isolateDidlParseThreshold = 16384;

DidlDocument _parseDidlPage(String xmlText) => parseDidl(xmlText, 'soap:Browse');

Future<DidlDocument> _parseDidlPageInIsolate(String xmlText) =>
    Isolate.run(() => _parseDidlPage(xmlText));

/// ContentDirectory Browse over UPnP SOAP (plan 12.1).
class DlnaMetadataService {
  DlnaMetadataService({
    required this._soap,
    required this._controlUrl,
  });

  final SoapTransport _soap;
  final Uri _controlUrl;

  static const String _serviceType =
      'urn:schemas-upnp-org:service:ContentDirectory:1';

  Future<DidlDocument> browse(String objectId) async {
    SoapServices.contentDirectory.action('Browse');
    // A Browse can answer a partial page (the per-response cap
    // differs by maker, plan 74.10), so pages are fetched until
    // TotalMatches is covered and merged in response order.
    final containers = <DidlContainer>[];
    final items = <DidlItem>[];
    await fetchAllListPages(
      requestPage: (startingIndex) => _soap.call(
        controlUrl: _controlUrl,
        serviceType: _serviceType,
        action: 'Browse',
        args: {
          'ObjectID': objectId,
          'BrowseFlag': 'BrowseDirectChildren',
          'Filter': '*',
          'StartingIndex': '$startingIndex',
          // 0 = as many as available (measured form, plan 11.8).
          'RequestedCount': '0',
          'SortCriteria': '',
        },
      ),
      consumePage: (resp) async {
        final result = resp.result;
        if (result == null) {
          throw NasneError.parse('soap:Browse', cause: 'missing Result');
        }
        final page = result.length >= _isolateDidlParseThreshold
            ? await _parseDidlPageInIsolate(result)
            : _parseDidlPage(result);
        containers.addAll(page.containers);
        items.addAll(page.items);
        return page.containers.length + page.items.length;
      },
    );
    return DidlDocument(containers: containers, items: items);
  }
}

/// The app's MetadataService: Browse via DLNA, EPG via WebAPI.
class CompositeMetadataService implements MetadataService {
  CompositeMetadataService({required this._dlna, required this._epg});

  final DlnaMetadataService _dlna;
  final WebApiEpgService _epg;

  @override
  Future<DidlDocument> browse(String objectId) => _dlna.browse(objectId);

  @override
  Future<EpgGuide> getProgrammeGuide(
    int broadcastingType,
    List<Channel> channels,
  ) =>
      _epg.getProgrammeGuide(broadcastingType, channels);

  @override
  Future<Map<int, List<int>>> getChannelLogos(int broadcastingType) =>
      _epg.getChannelLogos(broadcastingType);
}
