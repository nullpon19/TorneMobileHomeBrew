/// TitleCatalogService implementation (plan 12.1 / 12.5).
///
/// Primary source is the XSRS title list; counts come from the
/// WebAPI count endpoints; the DIDL complement (copy count, res list,
/// descriptions) is joined by title id inside this implementation —
/// callers only see the merged [RecordedTitle].
library;

import 'dart:async';
import 'dart:typed_data';

import '../endpoints.dart';
import '../errors.dart';
import '../models/title.dart';
import '../parsing/chapter.dart';
import '../parsing/thumbnail.dart';
import '../parsing/xsrs.dart';
import '../transport/soap_transport.dart';
import '../transport/webapi_transport.dart';
import 'interfaces.dart';
import 'paged_list.dart';

class SoapTitleCatalogService implements TitleCatalogService {
  SoapTitleCatalogService({
    required this._soap,
    required Uri xsrsControlUrl,
    required this._webApi,
    required this._metadata,
    this._pvrControlUrl,
  }) : _controlUrl = xsrsControlUrl;

  final SoapTransport _soap;
  final Uri _controlUrl;
  final WebApiTransport _webApi;
  final MetadataService _metadata;

  /// The X_PvrControl control URL (X_GetTitleInfo's
  /// service), or null when the device description
  /// carried none — chapters are then simply absent.
  final Uri? _pvrControlUrl;

  static const String _serviceType =
      'urn:schemas-xsrs-org:service:X_ScheduledRecording:2';

  static const String _pvrServiceType =
      'urn:schemas-s-bras-org:service:X_PvrControl:1';

  /// Entries the first X_GetTitleList request of a progressive
  /// load asks for (plan 100). The point is the time to the
  /// first thing on screen: one short round trip, against the
  /// server default page of 200 entries plus a full DIDL Browse
  /// that the whole-list load used to wait for before anything
  /// could be shown.
  static const int firstChunkSize = 20;

  @override
  Future<List<RecordedTitle>> listTitles({bool withMetadata = true}) async {
    final progress = await listTitlesProgressively(withMetadata: withMetadata)
        .last;
    return progress.titles;
  }

  @override
  Stream<TitleListProgress> listTitlesProgressively({
    bool withMetadata = true,
  }) {
    var cancelled = false;
    late StreamController<TitleListProgress> controller;
    controller = StreamController<TitleListProgress>(
      onListen: () => _emitTitleProgress(
        controller,
        withMetadata: withMetadata,
        isCancelled: () => cancelled || controller.isClosed,
      ),
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }

  /// The progressive load behind [listTitlesProgressively]:
  /// publishes the accumulation after the first chunk and after
  /// every further page, then the DIDL-merged list as the
  /// complete stage.
  Future<void> _emitTitleProgress(
    StreamController<TitleListProgress> sink, {
    required bool withMetadata,
    required bool Function() isCancelled,
  }) async {
    try {
      // The DIDL Browse runs alongside the XSRS paging, not
      // after it: the merge at the end then waits only for
      // whichever side finishes last, instead of paying both
      // latencies in series as the whole-list load used to.
      final didlFuture = withMetadata
          ? _metadata.browse(MetadataService.allRecordingsContainer)
          : null;
      if (didlFuture != null) {
        // If the paging fails first, nothing else awaits this
        // future; keep its error from surfacing as unhandled.
        // The merge below still observes it when paging
        // succeeds.
        didlFuture.ignore();
      }
      final titles = <RecordedTitle>[];
      var firstRequest = true;
      // RequestedCount 0 answers at most the server's default
      // page (200 items, measured in plan 74.10), so pages are
      // fetched until TotalMatches is covered. The first
      // request asks for [firstChunkSize] explicitly — the one
      // change that makes the first stage arrive quickly.
      await fetchAllListPages(
        shouldCancel: isCancelled,
        requestPage: (startingIndex) {
          final count = firstRequest ? '$firstChunkSize' : '0';
          firstRequest = false;
          return _soap.call(
            controlUrl: _controlUrl,
            serviceType: _serviceType,
            action: 'X_GetTitleList',
            args: {
              'SearchCriteria': '',
              'Filter': '*',
              'StartingIndex': '$startingIndex',
              'RequestedCount': count,
              'SortCriteria': '',
            },
          );
        },
        consumePage: (resp) {
          final result = resp.result;
          if (result == null) {
            throw NasneError.parse(
              'soap:X_GetTitleList',
              cause: 'missing Result',
            );
          }
          final page = [
            for (final item in parseXsrsItems(result, 'soap:X_GetTitleList'))
              recordedTitleFromXsrs(item, source: 'soap:X_GetTitleList'),
          ];
          titles.addAll(page);
          return page.length;
        },
        onPage: () {
          if (!isCancelled()) {
            sink.add(
              TitleListProgress(List.unmodifiable(titles), complete: false),
            );
          }
        },
      );
      if (isCancelled()) return;
      if (!withMetadata || titles.isEmpty) {
        sink.add(TitleListProgress(List.unmodifiable(titles), complete: true));
        return;
      }
      final didl = await didlFuture!;
      if (isCancelled()) return;
      final byTitleId = {
        for (final item in didl.items)
          if (item.titleId != null) item.titleId!: item,
      };
      sink.add(
        TitleListProgress([
          for (final title in titles)
            if (byTitleId[title.id] case final match?)
              title.withDidl(
                description: match.description,
                longDescription: match.longDescription,
                channelName: match.channelName,
                genre: match.genre,
                copyCountRemaining: match.copyCountRemaining,
                res: match.res,
              )
            else
              title,
        ], complete: true),
      );
    } catch (e, s) {
      if (!isCancelled()) {
        sink.addError(e, s);
      }
    } finally {
      if (!sink.isClosed) {
        await sink.close();
      }
    }
  }

  @override
  Future<void> deleteTitle(String id) async {
    // X_DeleteTitle on the same XSRS service as the title list
    // (plan 86.3). The TitleID argument name follows the
    // service's measured ID naming (X_DeleteRecordSchedule
    // takes RecordScheduleID); a wrong name surfaces as a SOAP
    // Fault, never as a silent wrong deletion. Device
    // verification is pending (plan 86.3).
    await _soap.call(
      controlUrl: _controlUrl,
      serviceType: _serviceType,
      action: 'X_DeleteTitle',
      args: {'TitleID': id},
    );
  }

  @override
  Future<void> setTitleProtection(
    RecordedTitle title, {
    required bool protect,
  }) async {
    // X_UpdateTitle on the same XSRS service (plan 86.3,
    // device-verified): the Elements argument is the item
    // document exactly as listed, with only titleProtectFlag
    // changed, and the item's id attribute names the target.
    // A title without its listed document cannot be updated —
    // guessing a document could rewrite the wrong metadata,
    // so this refuses instead of reconstructing one.
    final itemXml = title.sourceItemXml;
    if (itemXml == null) {
      throw NasneError.unsupported(
        'soap:X_UpdateTitle',
        detail: 'title carries no listed item document',
      );
    }
    await _soap.call(
      controlUrl: _controlUrl,
      serviceType: _serviceType,
      action: 'X_UpdateTitle',
      args: {'Elements': buildTitleProtectElements(itemXml, protect: protect)},
    );
  }

  @override
  Future<Uint8List?> fetchThumbnail(String id) async {
    // Measured on a real unit (plan 97 / 99): thumbnailMapGet
    // returns a position map with no image in it; the frames
    // live behind recordedContentThumbnailGet as AES-128-CBC
    // payloads whose key is an app-common constant, and
    // decode to 360x240 UYVY (plan 99). The first entry is
    // the list's picture. The magic-byte extraction stays as
    // a defensive path if a unit ever embeds a plain image.
    // Every failure — transport, status, an unrecognised
    // payload — is simply "no thumbnail"; a missing picture
    // must never break the list.
    try {
      final mapRaw = await _webApi.getBytes(
        WebApiEndpoints.thumbnailMapGet,
        params: {'id': id},
      );
      final embedded = extractThumbnailImage(mapRaw);
      if (embedded != null) return embedded;
      final count = thumbnailEntryCount(mapRaw);
      if (count == null || count == 0) return null;
      final raw = await _webApi.getBytes(
        WebApiEndpoints.recordedContentThumbnailGet,
        params: {'id': id, 'thumbnailEntryId': '0'},
      );
      return extractThumbnailImage(raw) ?? decodeThumbnailPayload(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setResumePosition(String id, Duration position) async {
    // The media-service call behind the interface contract
    // (plan 102): the form carries the position in
    // milliseconds. A negative position is rejected by the
    // unit (errorcode 803, measured), so clamp at zero — the
    // cleared point — instead of sending one.
    final clamped = position.isNegative ? Duration.zero : position;
    await _webApi.postJson(
      WebApiEndpoints.recordedContentResumePositionSet,
      form: {'id': id, 'position': '${clamped.inMilliseconds}'},
    );
  }

  @override
  Future<List<Duration>> fetchChapters(
    String id, {
    required int durationSeconds,
  }) async {
    // Chapter points from X_GetTitleInfo on X_PvrControl
    // (plan 110 / 112): an xsrs document whose root
    // carries chapterNum / chapterTime / startPTS
    // directly. The parse validates before converting —
    // the unit serves broken chapter data for some
    // titles — and every failure is simply "no
    // chapters": a missing control URL, a transport
    // error, a fault, bad data. Chapters decorate
    // playback; they must never break it.
    final controlUrl = _pvrControlUrl;
    if (controlUrl == null) return const [];
    try {
      final resp = await _soap.call(
        controlUrl: controlUrl,
        serviceType: _pvrServiceType,
        action: 'X_GetTitleInfo',
        args: {'TitleID': id},
      );
      final result = resp.result;
      if (result == null) return const [];
      final fields = parseTitleInfoDocument(result, 'soap:X_GetTitleInfo');
      return chapterPositionsFromTitleInfo(
        fields,
        durationSeconds: durationSeconds,
      );
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<int> countTitles() async {
    final json = await _webApi.getJson(WebApiEndpoints.recordedContentCountGet);
    final count = json['count'];
    if (count is! num) {
      throw NasneError.parse(
        'webapi:/recorded/recordedContentCountGet',
        cause: 'missing count',
      );
    }
    return count.toInt();
  }

  @override
  Future<int> maxTitles() async {
    final json = await _webApi.getJson(
      WebApiEndpoints.recordedContentMaxCountGet,
    );
    final count = json['count'];
    if (count is! num) {
      throw NasneError.parse(
        'webapi:/recorded/recordedContentMaxCountGet',
        cause: 'missing count',
      );
    }
    return count.toInt();
  }
}
