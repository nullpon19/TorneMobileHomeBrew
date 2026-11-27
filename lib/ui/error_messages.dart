/// Maps the core's unified errors (plan 12.6) to user-facing Japanese
/// messages. The core holds only message keys; the wording lives here
/// so the core stays UI- and locale-free.
///
/// Plan 86 (plan 85 item 9): the messages no longer carry the
/// transport codes (HTTP status, WebAPI errorcode, SOAP code).
/// A code is not something a viewer can act on; it stays on the
/// error itself, where the diagnostic log and the error dialog's
/// detail section ([errorDetailText]) keep it available. What
/// the viewer sees first is what happened and, where one can be
/// offered, what to do next ([errorNextStepForError]).
library;

import '../core/core.dart';

/// True when [error] indicates nasne's live tuner is currently busy
/// (HTTP 511 from the DTCP live stream endpoint).
bool isTunerBusyError(Object error) =>
    error is NasneError &&
    error.messageKey == 'error.http' &&
    error.code == '511';

/// A user-facing explanation for [error] (usually a [NasneError]).
String userMessageForError(Object error) {
  if (isTunerBusyError(error)) {
    return 'nasne のチューナーが現在使用中です。';
  }
  if (error is NasneError) {
    return switch (error.messageKey) {
      'error.unreachable' => 'nasne に接続できませんでした。電源とネットワークを確認してください。',
      'error.notImplemented' => 'このファームウェアでは未対応の機能です。',
      'error.http' => 'nasne からエラーが返りました。',
      'error.webapi' => 'nasne がエラーを返しました。',
      'error.invalidArgs' => '要求の形式が正しくありませんでした。',
      'error.invalidIdFormat' => 'ID の形式が正しくありませんでした。',
      'error.soapFault' => '操作に失敗しました。',
      'error.titleProtected' => 'このタイトルは保護されているため削除できません。',
      'error.parse' => 'nasne の応答を読み取れませんでした。',
      'error.validation' => error.detail ?? '入力内容を確認してください。',
      'error.unsupported' => 'この機能は未実装です。',
      _ => 'エラーが発生しました。',
    };
  }
  return 'エラーが発生しました。';
}

/// What the viewer can do next about [error], in plain words,
/// for the surfaces that have room to show it (the playback
/// error dialog; plan 86, plan 85 item 9). Null when nothing
/// useful can be added — the explanation already says what to
/// check, or the failure is not one a viewer can act on.
String? errorNextStepForError(Object error) {
  if (isTunerBusyError(error)) {
    return '他の視聴や録画が終わると再生できます。少し待ってから再試行するか、「空きを待って自動再生」をお使いください。';
  }
  if (error is NasneError) {
    return switch (error.messageKey) {
      'error.unreachable' =>
        'nasne の電源が入っていることと、この端末が同じ Wi-Fi '
            '(同じネットワーク) につながっていることを確認してから、'
            'もう一度お試しください。',
      'error.http' || 'error.webapi' || 'error.soapFault' =>
        'しばらく待ってからもう一度お試しください。'
            '繰り返し失敗する場合は、nasne を再起動すると直ることがあります。',
      'error.parse' => 'もう一度お試しください。直らない場合は、アプリを再起動してください。',
      'error.notImplemented' => 'この nasne では使えない機能です。アプリ側でできる対応はありません。',
      'error.invalidArgs' || 'error.invalidIdFormat' => 'アプリを再起動してもう一度お試しください。',
      _ => null,
    };
  }
  return null;
}

/// The diagnostic classification of [error] — category, source,
/// code, detail — as one block of text. This is the text the
/// playback error dialog used to lead with (plan 28); since
/// plan 86 it belongs in the dialog's collapsed detail section
/// and in the diagnostic log, not in front of the viewer.
String errorDetailText(NasneError error) {
  final detail = StringBuffer(
    '分類: ${error.category.name} / 発生元: ${error.source}',
  );
  if (error.code != null) detail.write(' / コード: ${error.code}');
  if (error.detail != null) detail.write('\n詳細: ${error.detail}');
  return detail.toString();
}
