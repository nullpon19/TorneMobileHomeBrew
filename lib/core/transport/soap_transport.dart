/// UPnP SOAP transport (plan 12.3).
///
/// Envelopes are built from string templates with every argument
/// value XML-escaped (the same construction the phase 0 probes proved
/// against the device). Responses are parsed in two stages by the
/// callers: this transport unwraps the SOAP envelope and returns the
/// action's out-arguments as strings; the `Result` string is then
/// re-parsed as xsrs / DIDL by the owning service.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../errors.dart';
import 'xml_util.dart';

/// The out-arguments of a successful SOAP action call.
class SoapResponse {
  const SoapResponse(this.values);

  /// Argument name -> text content (entities already decoded, so a
  /// `Result` value is the raw xsrs / DIDL document string).
  final Map<String, String> values;

  String? get result => values['Result'];
}

class SoapTransport {
  SoapTransport({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final Duration timeout;
  final http.Client _client;

  /// Calls [action] on the service at [controlUrl].
  ///
  /// [args] preserves insertion order. Argument values are escaped;
  /// an argument whose value is itself an XML document (xsrs
  /// `Elements`) is therefore transported as escaped text, exactly as
  /// the device expects (plan 12.3).
  Future<SoapResponse> call({
    required Uri controlUrl,
    required String serviceType,
    required String action,
    Map<String, String> args = const {},
  }) async {
    final source = 'soap:$action';
    final inner = args.entries
        .map((e) => '<${e.key}>${escapeXmlText(e.value)}</${e.key}>')
        .join();
    final body = '<?xml version="1.0" encoding="UTF-8"?>'
        '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" '
        'xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<soapenv:Body>'
        '<u:$action soapenv:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" '
        'xmlns:u="$serviceType">$inner</u:$action>'
        '</soapenv:Body></soapenv:Envelope>';

    final http.Response resp;
    final abortTrigger = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    });
    final request = http.AbortableRequest(
      'POST',
      controlUrl,
      abortTrigger: abortTrigger.future,
    );
    request.headers.addAll({
      'Content-Type': 'text/xml; charset="utf-8"',
      'SOAPAction': '"$serviceType#$action"',
    });
    request.bodyBytes = utf8.encode(body);
    try {
      final streamed = await _client.send(request).timeout(timeout);
      resp = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException catch (e) {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
      throw NasneError.unreachable(source, cause: e);
    } catch (e) {
      throw NasneError.unreachable(source, cause: e);
    } finally {
      timer.cancel();
    }

    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } catch (e) {
      if (resp.statusCode != 200) throw NasneError.http(resp.statusCode, source);
      throw NasneError.parse(source, cause: e);
    }

    final fault = firstDescendant(doc.rootElement, 'Fault');
    if (fault != null) {
      final code =
          firstDescendant(fault, 'errorCode')?.innerText.trim() ?? '';
      final description =
          firstDescendant(fault, 'errorDescription')?.innerText.trim();
      throw NasneError.soapFault(
        errorCode: code.isEmpty ? '${resp.statusCode}' : code,
        errorDescription: description,
        source: source,
      );
    }
    if (resp.statusCode != 200) {
      throw NasneError.http(resp.statusCode, source);
    }

    final responseElement = firstDescendant(doc.rootElement, '${action}Response');
    if (responseElement == null) {
      throw NasneError.parse(source,
          cause: 'no ${action}Response element in response');
    }
    final values = <String, String>{};
    for (final child in responseElement.childElements) {
      values[child.name.local] = child.innerText;
    }
    return SoapResponse(values);
  }
}
