/// Paged fetching of UPnP SOAP list actions (plan 74.10).
///
/// X_GetTitleList and ContentDirectory Browse both answer at most
/// one server-chosen page per call when RequestedCount is 0
/// (measured on SIE: the X_GetTitleList default page is 200 items),
/// so the full list is assembled by advancing StartingIndex until
/// the accumulated entries reach the response's TotalMatches.
library;

import '../transport/soap_transport.dart';

/// Upper bound on the pages fetched for one list. The largest
/// measured page is 200 items, so 100 pages cover 20,000 entries —
/// far beyond any list the device can hold; the bound exists only
/// so a device that keeps answering pages forever cannot spin the
/// caller in an endless loop.
const int maxListPages = 100;

/// Fetches every page of a paged list action.
///
/// [requestPage] issues one call with the given StartingIndex;
/// [consumePage] folds one response into the caller's accumulation
/// and returns how many entries the page carried. Paging stops
/// when the accumulated entries reach TotalMatches, when a page
/// reports NumberReturned 0, or after [maxListPages] pages. When
/// the counts are absent from the response, the first page is
/// taken as the whole list (the behaviour before paging).
///
/// [onPage], when given, runs after each page has been consumed
/// (plan 100): a caller building a progressive view of the list
/// uses it to publish the accumulation so far without waiting
/// for the remaining pages.
Future<void> fetchAllListPages({
  required Future<SoapResponse> Function(int startingIndex) requestPage,
  required int Function(SoapResponse response) consumePage,
  void Function()? onPage,
  int initialStartingIndex = 0,
  bool Function()? shouldCancel,
}) async {
  var accumulated = 0;
  var startingIndex = initialStartingIndex;
  for (var page = 0; page < maxListPages; page++) {
    if (shouldCancel?.call() == true) break;
    final response = await requestPage(startingIndex);
    if (shouldCancel?.call() == true) break;
    accumulated += consumePage(response);
    onPage?.call();
    if (shouldCancel?.call() == true) break;
    final numberReturned = int.tryParse(
      response.values['NumberReturned'] ?? '',
    );
    final totalMatches = int.tryParse(response.values['TotalMatches'] ?? '');
    if (numberReturned == null || numberReturned <= 0) break;
    if (totalMatches == null || accumulated >= totalMatches) break;
    startingIndex += numberReturned;
    if (startingIndex >= totalMatches) break;
  }
}
