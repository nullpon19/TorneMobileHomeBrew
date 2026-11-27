/// Unified error representation for the tmhb core (plan section 12.6).
///
/// Every transport converts its failures into a [NasneError] at the domain
/// interface boundary, so UI / domain code never sees transport-specific
/// error shapes (HTTP status, WebAPI `errorcode`, UPnP Fault, ...).
library;

/// Error categories (plan section 12.6).
enum NasneErrorCategory {
  /// The device could not be reached (socket error / timeout).
  unreachable,

  /// HTTP status was not 200 (and no more specific shape was recognised).
  http,

  /// WebAPI JSON error (`errorcode != 0`, or the 400 rejection of a POST).
  webapi,

  /// UPnP SOAP Fault (`errorCode` / `errorDescription`).
  soapFault,

  /// The response did not match the expected schema.
  parse,

  /// Client-side input validation failed before anything was sent.
  validation,

  /// The capability is not implemented (e.g. the v1 PlaybackEngine stub).
  unsupported,
}

/// The unified error type thrown by every core service.
class NasneError implements Exception {
  const NasneError({
    required this.category,
    required this.source,
    required this.messageKey,
    this.code,
    this.retryable = false,
    this.detail,
  });

  /// Coarse category (see [NasneErrorCategory]).
  final NasneErrorCategory category;

  /// Original code, kept verbatim as a string (HTTP status, WebAPI
  /// errorcode, UPnP errorCode, ...). Null when there is no code.
  final String? code;

  /// Where the error came from, e.g. `webapi:/status/boxNameGet`,
  /// `soap:X_CreateRecordSchedule`, `ssdp:discover`.
  final String source;

  /// Whether an automatic retry is acceptable. Only idempotent reads are
  /// ever retryable (plan section 12.4); writes are never retried.
  final bool retryable;

  /// Key for the user-facing explanation. The UI maps this to a message;
  /// the core itself holds no localised text.
  final String messageKey;

  /// Optional human-readable detail for logs / diagnostics (never a secret).
  final String? detail;

  factory NasneError.unreachable(String source, {Object? cause}) {
    return NasneError(
      category: NasneErrorCategory.unreachable,
      source: source,
      messageKey: 'error.unreachable',
      retryable: true,
      detail: cause?.toString(),
    );
  }

  factory NasneError.http(int statusCode, String source, {String? detail}) {
    return NasneError(
      category: NasneErrorCategory.http,
      code: '$statusCode',
      source: source,
      messageKey: statusCode == 404 ? 'error.notImplemented' : 'error.http',
      detail: (detail != null && detail.isNotEmpty)
          ? detail
          : 'HTTP $statusCode',
    );
  }

  factory NasneError.webapi(int errorCode, String source) {
    return NasneError(
      category: NasneErrorCategory.webapi,
      code: '$errorCode',
      source: source,
      messageKey: 'error.webapi',
      detail: 'errorcode=$errorCode',
    );
  }

  /// Builds an error from a UPnP SOAP Fault, applying the measured
  /// interpretation table of plan section 12.6.
  factory NasneError.soapFault({
    required String errorCode,
    String? errorDescription,
    required String source,
  }) {
    // Measured interpretations (plan 11.7 / 12.6):
    //  402 Invalid Args  -> the request shape was wrong; an implementation
    //                       problem, not a user mistake.
    //  803               -> id format wrong (the create-response "0x" id
    //                       used for delete). Prevented by model
    //                       normalisation; if it surfaces it is a bug.
    //  877               -> the title is protected (plan 86.3:
    //                       X_DeleteTitle on a protected title is
    //                       refused with this code).
    //  500 / others      -> interpret together with errorDescription.
    final key = switch (errorCode) {
      '402' => 'error.invalidArgs',
      '803' => 'error.invalidIdFormat',
      '877' => 'error.titleProtected',
      _ => 'error.soapFault',
    };
    return NasneError(
      category: NasneErrorCategory.soapFault,
      code: errorCode,
      source: source,
      messageKey: key,
      detail: errorDescription,
    );
  }

  factory NasneError.parse(String source, {Object? cause}) {
    return NasneError(
      category: NasneErrorCategory.parse,
      source: source,
      messageKey: 'error.parse',
      detail: cause?.toString(),
    );
  }

  factory NasneError.validation(String source, String detail) {
    return NasneError(
      category: NasneErrorCategory.validation,
      source: source,
      messageKey: 'error.validation',
      detail: detail,
    );
  }

  factory NasneError.unsupported(String source, {String? detail}) {
    return NasneError(
      category: NasneErrorCategory.unsupported,
      source: source,
      messageKey: 'error.unsupported',
      detail: detail,
    );
  }

  @override
  String toString() {
    final b = StringBuffer('NasneError(${category.name}, source=$source');
    if (code != null) b.write(', code=$code');
    b.write(', key=$messageKey');
    if (retryable) b.write(', retryable');
    if (detail != null) b.write(', detail=$detail');
    b.write(')');
    return b.toString();
  }
}
