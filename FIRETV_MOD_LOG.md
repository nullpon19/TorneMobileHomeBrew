# TorneMobileHomeBrew Fire TV 暫定対応 改修ログ (`firetv-mod`)

本ドキュメントは、アップストリーム `mar1mo-41414/TorneMobileHomeBrew` に対する Fire TV Stick 向け暫定対応の変更点・技術的知見・再適用手順をまとめた保守用ログです（認証鍵や端末固有値などの秘密情報は一切含みません）。

---

## 1. 概要・ベースライン

- **アップストリーム元**: `mar1mo-41414/TorneMobileHomeBrew` (`main` コミット `78d74a8`, `v1.5.0+47`)
- **ローカル改修ブランチ**: `firetv-mod`（リモートへはプッシュしないローカル運用）
- **アプリ識別子 (`applicationId`)**: `com.markun.tmhb.firetv`
  - 公式版 (`com.markun.tmhb`) と同一端末へ共存インストール可能にするため分離しています。
- **検証実機・動作前提**:
  - Fire TV Stick (`AFTKRT` / Fire OS 8 / Android 11 SDK 30 / 32-bit `armeabi-v7a` / RAM 約 1.7 GB / `/data` 空き約 6.3 GB)
  - 配信画質: 設定画面でデフォルト画質（初期値 `元画質 (DR)` / `モバイル`）を選択でき、番組詳細・TV視聴詳細でその回のみの画質切替も可能（第 1 弾ではモバイル固定、第 5 弾で任意選択へ拡張）。DTCP-IP over LAN / Tailscale VPN / モバイル回線車載利用を想定。

---

## 2. 時系列の改修履歴

### 第1弾: Fire TV 暫定対応ベース (`1e8c0f4`)
- Fire TV リモコン（D-pad / Select / Back / Up / Down / Left / Right）で実用操作できるよう基盤を整備。
- **アプリ識別子・ランチャー対応**: `applicationId` を `com.markun.tmhb.firetv` に分離、`LEANBACK_LAUNCHER` カテゴリおよび TV バナー (`tv_banner.png`) を追加。
- **ビルド環境整理**: JDK 21 / Flutter SDK / Android SDK 導入時の後片付け手順 (`CLEANUP_BUILD_ENV.md`) を追加。
- **起動時音量 & Tailscale ガード (`lib/app/firetv_helper.dart`, `lib/ui/tailscale_guard.dart`, `MainActivity.kt`)**:
  - アプリ起動時のメディア音量最大化（`setMediaVolumeMax`）。
  - nasne 未到達かつ VPN 未使用時に Tailscale 接続確認・起動誘導を行うガード UI を追加。
- **証明書設定 (`lib/ui/dtcp_credential_screen.dart`)**:
  - 2 カラム入力（Cert / Private Key）＋上部に主要アクションボタンを配置し、`DocumentsUI` が存在しない Fire OS でも読み込めるアプリ内ファイルピッカーを実装（`READ_EXTERNAL_STORAGE` / `MANAGE_EXTERNAL_STORAGE` 経由で `getAppFilesDirPath` / `listCredentialCandidateFiles` / `readFileBytes` を利用）。
- **番組一覧・詳細 (`lib/ui/titles_screen.dart`, `lib/ui/live_screen.dart`)**:
  - Fire TV 向けにサムネイル 1/4 ＋タイトル 3/4 のヘッダー構成と上部再生ボタンへ最適化。
  - 当初は安全のため nasne モバイル画質 (`quality=mobile`) 固定化。
- **再生画面 (`lib/ui/player_screen.dart`, `lib/main.dart`)**:
  - フルスクリーン再生、D-pad リモコンによる再生/一時停止/シーク/チャプター送り/音声切替・情報 OSD、全体的な Amber フォーカス枠 (`_buildTheme`) を実装。

### 第2弾: ビルド時個人プリセット対応 (`a1307e1`)
- `--dart-define-from-file` 経由で個人の DTCP-IP 証明書・秘密鍵・nasne 登録情報をビルド時に注入できる `FireTvPreset` (`lib/app/firetv_preset.dart`) を追加。
- 初回起動時のみ自動投入（`firetv_preset_cred_applied` / `firetv_preset_nasne_applied` フラグで管理）し、手動削除・編集や再復元ボタン (`dtcp_credential_screen.dart`) と共存できるよう設計。

### 第3弾: 実機録画再生 ANR・クラッシュ解消 (`b6cce9a`)
- **事象**: Live は読み込み中くるくるが出ず黒画面のまま待機し、録画再生は音声のみ約 30 秒流れた後、`reason=6 ANR`（メインスレッド CPU 99%）でアプリが落ちる問題を実機ログから特定。
- **原因**: Fire OS 8 (`armeabi-v7a` 32-bit) ＋ Flutter 3.50（UI/プラットフォームスレッド統合）環境では、純粋 Dart の `pointycastle` による AES-128-CBC 復号が DTCP-IP バースト転送時にメインスレッド CPU を占有し続けていた。
- **対策**:
  1. C 言語 FIPS-197 T-table 実装のネイティブ AES-128-CBC (`android/app/src/main/cpp/tmhb_aes.c`, `CMakeLists.txt` `-O3`, `lib/core/dtcp/native_aes.dart`, `dtcp_crypto.dart`) を導入し、`libtmhb_fcntl.so` へ FFI オフロード。
  2. `DtcpProxy` (`lib/core/dtcp/dtcp_proxy.dart`) に 4ms ごとの協調的イベントループ譲歩を追加し、UI/入力応答を確保。
  3. メモリ制約のある Android/Fire TV 向けに初期録画デマクサバッファを軽量化 (`player_cache_policy.dart`: `androidRecordingDemuxerMaxBytes` = 8 MiB / `Back` = 4 MiB)。
  4. `PlayerScreen` に Live/録画共通の初期読み込み＆バッファリング中スピナー表示を追加。

### 第4弾: シークバー HUD・車載用長時間バッファ・無制限自動再接続・中華フォント修正 (`1097fd7`, `a329107`)
1. **録画再生シークバー HUD (`lib/ui/player_screen.dart`, `lib/ui/titles_screen.dart`)**:
   - 下部オーバーレイ型のシークバー HUD（左/右などの操作で表示し 3 秒後に自動消灯、リモコンフォーカスを奪わないため左右連打・長押しが可能）。
   - 操作バッジ、番組タイトル、`現在位置 / 総時間`、残り時間、先読み済みバッファバー、チャプター目盛り、シーク直後のプレビュー＆700ms 保持を表示。nasne メタデータ由来の `knownDuration` フォールバックを `titles_screen.dart` から受け渡し、フル OSD 下部と `_buildSeekBarSection` を共通化（設定中バッファ表示バッジも併記）。
2. **録画・Live 別バッファ時間設定とディスクキャッシュ (`lib/ui/player_cache_policy.dart`, `settings_screen.dart`, `MainActivity.kt`, `bootstrap.dart`, `main.dart`)**:
   - **録画のバッファ時間（先読み）**: `標準 (0秒)` / `30秒` / `1分` / `3分` / `5分`（デフォルト）/ `10分` / `15分` / `30分` / `45分` / `60分` を設定画面「再生」から選択可能。再生開始は約 5 秒 (`cache-pause-wait` <= 5) で素早く始めつつ裏で設定時間まで先読みし、60 秒以上では `cache-on-disk=yes` ＋ `demuxer-cache-dir=<tempDir>/mpv_cache`（前方最大 `1200 MiB`、後方最大 `150 MiB`）を使用。Android `StatFs` (`getCacheAvailableBytes`) により必ず `512 MiB` 以上の空き容量 (`minFreeDiskReserveBytes`) を残存保護。
   - **Live のバッファ時間（遅延再生）**: `標準 (0秒)`（デフォルト）/ `15秒` / `30秒` / `1分` / `3分` / `5分` から選択可能。radiko 風の事前蓄積 (`cache-pause-initial=yes`) 中に「バッファ蓄積中… X / Y秒」＋プログレスバーを表示。
3. **2 段階無制限自動再接続＆Fire TV フォーカス修正 (`lib/core/dtcp/dtcp_proxy.dart`, `dtcp_playback.dart`, `lib/app/providers.dart`, `player_screen.dart`)**:
   - **プロキシ層 (`DtcpProxy` / `DtcpMediaFetcher` / `PlaybackKeySource`)**: Android (`autoReconnect: Platform.isAndroid`) では回数上限を設けず（バックオフ `3秒 -> 5秒 -> 8秒 -> 10秒`、受信再開でリセット）、`resetClient()` ＋ `forceReauthenticate()`（AKE 再認証）で録画/Live 双方を復旧。一時エラー時のタイムシーク維持 (`_isTransientReconnectError`)、Live 再オープン時の `409 Conflict` 回避・旧ハンドラ解放 (`_PlaintextQueue.notify()` / `isSuperseded`)、`bufferOutput = false`（auto-gzip 抑止）も適用。
   - **プレイヤー層 (`PlayerScreen`)**: プレイヤー画面が開いている間は無制限で自動再開カウントダウン＆ウォッチドッグを実行。中断バナー・エラー画面上の明示的な `FocusNode.requestFocus()`、`FocusTraversalGroup`、Select/Enter キー即時再開でリモコン閉じ込めを解消。
4. **Fire OS 中華フォント（「中華グリフ」）対策 (`lib/main.dart`)**:
   - `TmhbApp` の `MaterialApp` に `locale: const Locale('ja', 'JP')`, `supportedLocales: const [Locale('ja', 'JP')]`, `localizationsDelegates: GlobalMaterialLocalizations.delegates` を設定し、`builder` 内でも `DefaultTextStyle.merge(style: const TextStyle(locale: Locale('ja', 'JP')))` を補完。

### 第5弾: 操作性・UI改善（10秒シーク統一・画質選択解除・IME閉じ込め防止・EPG枠フォーカス・ナイトモード）(`58566ca`)
1. **リモコン左右シーク幅を 10 秒へ統一 (`lib/ui/player_screen.dart`)**:
   - `PlayerScreen.rewindStep` (`-10秒`) と `PlayerScreen.forwardStep` (`+10秒`) をどちらも 10 秒に揃えて早送りも 10 秒刻みに統一し、HUD アイコン・OSD ボタンも `Icons.forward_10` / `+10秒` へ更新（バッファ計算および `バッファ: X / 設定 Y` 表示は従来のまま維持）。
2. **再生画質固定の解除と詳細画面での都度切替 (`lib/app/providers.dart`, `settings_screen.dart`, `titles_screen.dart`, `live_screen.dart`)**:
   - `PlaybackQualityNotifier` のモバイル固定ロックを解除し、設定画面「再生」に「デフォルト再生画質」（`元画質 (DR)` / `モバイル`、初期値＝`元画質`、`firetv_default_use_mobile` で永続化・旧固定キーはリセット）を追加。
   - `TitleDetailView` / `LiveChannelDetailView` では「再生」「視聴」ボタン横にその回限りの `SegmentedButton<bool>` を配置し、グローバルのデフォルト設定値を書き換えずに都度切替できるよう変更。
3. **バッファ設定 UI 整理 (`lib/ui/settings_screen.dart`)**:
   - 「Live のバッファ時間（遅延再生）」を上に、「録画のバッファ時間（先読み）」を下に配置変更し、「30〜60分はモバイル回線のギガ消費にご注意ください」および「（車載おすすめ）」表記を削除。
4. **全テキスト入力欄のダイアログ化による `FireTVIME` 閉じ込め防止 (`lib/ui/widgets.dart`, ほか 5 画面計 7 箇所)**:
   - 生の `TextField` を直接配置せず、決定キー／タップ時のみ `_FireTvTextInputDialog` を開く `FireTvTextInputField` を作成。
   - 適用先: `settings_screen.dart`（手動登録 IP/ホスト名）、`dtcp_credential_screen.dart`（証明書・秘密鍵 2 欄）、`titles_screen.dart`（タイトル検索）、`epg_search_screen.dart`（キーワード検索、`autofocus: true` も解除）、`schedule_form.dart`（長さ・条件 ID・録画先 3 欄）。
5. **番組表 (`EpgScreen`) のフォーカス表示をくっきりした太枠線へ変更 (`lib/ui/epg_screen.dart`)**:
   - `_EventTile` を `StatefulWidget` 化し、`InkWell.focusColor` を `Colors.transparent` にして背景色混濁を防いだうえで、`DecoratedBox(position: DecorationPosition.foreground)` による 3px 高コントラスト枠線（ライト時濃アンバー／ナイト時 `amberAccent`）をフォーカス時のみ前面描画。
6. **ナイトモード追加 (`lib/app/providers.dart`, `lib/main.dart`, `settings_screen.dart`)**:
   - `NightModeNotifier` / `nightModeProvider` (`firetv_night_mode`、初期値 `false`＝ライト) を追加し、設定画面「表示」→「ナイトモード」スイッチで即座にダークテーマへ切替可能に拡張（`segmentedButtonTheme` のフォーカス枠もライト/ダーク双方に対応）。

### 第6弾: EPG赤フォーカス枠・録画済み自動番組まとめ・終了確認ダイアログ (`0aa3de7`)
1. **番組表 (`EpgScreen`) ライトモード選択枠を赤に変更 (`lib/ui/epg_screen.dart`)**:
   - `_EventTileState.build` におけるライトモード時の 3px 前面フォーカス枠色を `#D32F2F`（Material Red 700）へ変更（ナイトモード時は `Colors.amberAccent`、背景 `focusColor` は透明のまま維持）。
2. **録画済み一覧の torne mobile 風シリーズ自動まとめ (`lib/app/providers.dart`, `lib/ui/title_list_filter.dart`, `lib/ui/titles_screen.dart`)**:
   - 既定 ON・`firetv_group_titles` で永続化する `GroupTitlesNotifier` / `groupTitlesProvider` と、一覧フィルタバー上の `'番組まとめ'` `FilterChip` を追加。
   - ARIB 番組記号・話数表記 (`#N`, `第N話`, `Vol.N`, `▽▼「『【`, ` 〜` 等) の正規化（パス 1）と、空白・明示区切りおよび 6 文字以上の数字開始境界のみを許可する安全マージ（パス 2）により、単発や別番組の誤統合を防ぎつつ 2 本以上の同シリーズ番組を折りたたみフォルダ `TitleGroup` へ自動集約。
   - フォルダ row (`_TitleGroupTile`) に開/閉フォルダアイコン、シリーズ名、JST 放送期間 (`YYYY/MM/DD 〜 YYYY/MM/DD`)、保護/未視聴 (`NEW`) アイコン、`全 ○ 本`、開閉シェブロンを表示し、選択時はリスト内にインデント＋縦ガイド線付きで各回をインライン展開。
   - フォルダ自体の並び順および展開後の各回順ともに、一覧で選択中の並び替え（録画日時新しい順・古い順・タイトル順）に連動。
3. **戻るボタンによるアプリ終了確認ダイアログ (`lib/ui/app_shell.dart`)**:
   - `AppShell` を `ConsumerStatefulWidget` 化し、ルートを `PopScope(canPop: false)` で保護。子画面・ダイアログが開いていないルート状態で戻るキーを押した場合に `'アプリを終了しますか？'`（初期フォーカス `'キャンセル'`／`'終了する'` で `SystemNavigator.pop()`）を表示し、多重オープンは `_exitDialogOpen` で抑止。

### 第7弾: 録画終端での誤再接続修正と再生完了時自動復帰 (`dd60d62`)
1. **録画正常終了 (EOF) 時のプロキシ無制限再接続防止 (`lib/core/services/dtcp_playback.dart`, `lib/core/dtcp/dtcp_proxy.dart`)**:
   - `DtcpPlaybackEngine._start` から `isLive` を `DtcpProxy.start` へ伝播し、非 Seekable 経路（モバイル画質などサイズ・尺欠如時）でエラー無しの正常 EOF を再接続対象とするのを Live 視聴限定に修正（通信エラー発生時の無制限再接続は維持）。
   - Seekable 録画経路でエラー無し (`producer.error == null`) のまま宣言サイズ (`totalBytes`) 未満でストリームが終わった場合、末尾付近（残り 2 MiB または 2% 以内）の1回確認または 2 回一致で実 EOF バイト (`_eofByte`) を確定して応答を正常クローズするよう修正（以降 `_eofByte` 以降の Range 要求は即 416 を返却）。
2. **プレイヤー終端ガードと再生完了時の自動一覧/詳細復帰 (`lib/ui/player_error_policy.dart`, `lib/ui/player_screen.dart`)**:
   - `isNearRecordedEnd`（録画で残り 8 秒以内、30 秒以下の短尺は 2 秒以内）を追加。
   - `mpv` の `completed=true` 通知時、および終端付近でのバッファ後停止／ストールタイムアウト／末尾エラー時にすべての自動再接続／ストール監視タイマーを止めて正常終了扱いとし、再生画面を閉じて録画一覧／詳細画面へ自動で戻るよう変更（通常のレジューム位置ゼロ報告は従来通り動作、終端での手動一時停止時は停止状態を維持）。

### 第8弾: 再生中 OSD からの番組詳細（半画面スクロール）表示 (`9a63f48`)
1. **OSD「番組詳細」ボタンと上半分スクロールオーバーレイ (`lib/ui/player_screen.dart`)**:
   - 番組の `description` と `longDescription` を重複なく結合する `formatProgramDetailBody` と、画面縦幅 45% 以内（上半分）にタイトル・メタ情報・全文を表示する `ProgramDetailOverlayPanel` を追加。
   - 詳細本文が存在する番組のみ OSD の「閉じる」手前に `'番組詳細'` ボタンを表示し、表示中は OSD 自動消灯タイマーを一時停止。Fire TV リモコンの上下キー（長押し連続スクロール対応）で全文スクロールでき、決定キー・戻るキー（またはパネル内「閉じる」）で再生画面を閉じずに詳細エリアのみ閉じて OSD ボタンへフォーカスを戻します。
2. **録画・TV視聴詳細画面からのメタデータ引き渡し (`lib/ui/titles_screen.dart`, `lib/ui/live_screen.dart`)**:
   - 録画済み詳細画面・Live 視聴詳細画面の双方で、番組タイトル・放送日時／チャンネル／ジャンル・詳細文（詳細画面上で 2 行省略または省略していた内容）を `PlayerScreen` へ渡すように拡張。

### 第9弾: OSD 循環フォーカストラップ＆高視認性強調・EPG 黒フォーカス枠＆予約済み赤枠／編集導線 (`b5f6be3`)
1. **再生中 OSD ボタンバーの循環フォーカストラップ＆強調スタイル (`lib/ui/player_screen.dart`)**:
   - OSD 操作ボタン列を専用 `FocusScopeNode` ベースの `PlayerOsdButtonBar` に変更し、右端から右で左端・左端から左へループし、上下矢印（複数行時は行間移動、単一行時は同ボタン維持）でもフォーカスが OSD 外へ逃げないように制御（万一ルートへ外れても矢印キーで先頭ボタンへ復帰）。
   - `osdButtonStyle()` によりフォーカス中ボタンを明るい金色背景・黒文字／黒アイコン・白 2.5px 枠線に反転強調。
2. **番組表ライト時フォーカス枠の黒枠化・録画予約済み赤枠＆「予約を編集」導線 (`lib/ui/epg_screen.dart`, `lib/ui/epg_search_screen.dart`)**:
   - ライトモード時の EPG タイルフォーカス枠色を `#D32F2F` から黒枠 (`Colors.black`, 3px) へ変更（ナイトモード時は `Colors.amberAccent` 維持）。
   - `schedulesProvider` と照合 (`parseScheduleEventId` / `findMatchingSchedule`) し、予約済み番組タイルを 2.5px の赤枠（ライト `#D32F2F` / ナイト `redAccent`）＋時刻横の赤ドットで囲い表示（予約済み＋フォーカス時は外側黒/金枠＋内側赤枠を併用描画）。
   - 予約済み番組の詳細ダイアログ（EPG・番組検索双方）では「録画予約」の代わりに **`'予約を編集'`** ボタンを表示し、押下で `ScheduleDetailPage`（編集／時刻変更／削除）を開くように変更。

### 第10弾: ホーム画面 2 カラム並列・高さ揃え＆リモコン下端スクロール対応 (`a724098`)
1. **ホーム画面のペアカード 2 カラム化＆高さ揃え (`lib/ui/home_screen.dart`, `lib/ui/widgets.dart`)**:
   - 横幅 `homeTwoColumnBreakpoint` (`600dp`) 以上（Fire TV／タブレット等）で、「本体情報」＋「HDD」および「ネットワーク」＋「B-CAS」をそれぞれ `_PairedSectionRow` (`IntrinsicHeight` + `Row(crossAxisAlignment: CrossAxisAlignment.stretch)`) により 2 カラム並列・同高さで配置。
   - 外側・中央マージンを上下カードと統一 (`12dp`) し、狭幅画面（スマホサイズ）では従来の縦 1 カラム表示を維持。
2. **ホーム画面のリモコン D-pad フォーカス＆最下部スクロール対応 (`lib/ui/widgets.dart`, `lib/ui/home_screen.dart`)**:
   - `SectionCard` に `margin`・`focusable`・`scrollController` 対応を追加し、ホーム画面の全 6 セクションカードをフォーカス可能化（ライト時黒枠 3px / ダーク時 `amberAccent` 3px、レイアウトズレなし、エラー時「再試行」ボタンへのフォーカス移動も両立）。
   - `_StatusList` の `ListView` に `ScrollController` と `scrollCacheExtent: ScrollCacheExtent.pixels(2000)` を設定し、全カード常時探索可能にしたうえでフォーカス追従 (`Scrollable.ensureVisible`)、画面縦幅超えカードの段階スクロール、および最下段到達時の最下部スクロールを実装。

### 第11弾: OSD 戻るキー修正＆「メニューを閉じる」化・プリセット廃止＆Download 権限対応・SegmentedButton 個別強調・EPG 上部バー統合 (`341cc5b`)
1. **再生中 OSD の戻るキー挙動修正＆「メニューを閉じる」変更 (`lib/ui/player_screen.dart`)**:
   - `PopScope(canPop: false)` ＋ `resolvePlayerBackOutcome`（詳細パネル／OSD クローズ直後の `450ms` 二重発火抑止）を導入し、OSD や番組詳細表示中にリモコンの戻るキーを押しても再生終了せず **`番組詳細のみ閉じる → OSD のみ閉じる → 再生終了`** の順に動作するよう修正。
   - OSD 右端ボタンのラベルを `'閉じる'` から **`'メニューを閉じる'`**（`playerOsdCloseMenuLabel`）へ変更し、OSD メニューを閉じるボタンであることを明確化。
2. **内蔵プリセットの完全廃止＆ `/sdcard/Download` 読み取り対応 (`lib/app/firetv_preset.dart` 削除, `lib/main.dart`, `lib/app/providers.dart`, `lib/ui/dtcp_credential_screen.dart`, `AndroidManifest.xml`, `MainActivity.kt`)**:
   - 第2弾で導入していた個人プリセット関連コード（`firetv_preset.dart`, `fireTvPresetProvider`, 起動時シード処理, `'内蔵プリセットを読み込む'` ボタン）を完全削除し、ビルド時注入を使わないクリーン APK 運用へ移行。
   - Android 11 / Fire OS 8（`targetSdk=36`）で `/sdcard/Download` 上の `.env` ファイルを参照できるよう `AndroidManifest.xml` に `MANAGE_EXTERNAL_STORAGE` を追加し、`MainActivity.kt` で `Environment.isExternalStorageManager()` 判定および設定画面 (`MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`) 誘導＋`onActivityResult` 自動再スキャンに対応。
3. **`SegmentedButton` の個別セグメント強調テーマ (`lib/main.dart`)**:
   - `segmentedButtonTheme` の外枠 `side` を通常枠のまま維持し、**フォーカス中のセグメント単体のみ** 背景をアンバー／金色・文字とアイコンを黒に反転させることで、「地デジ」「BS」などセットボタン群のフォーカス位置を明確化（全画面の `SegmentedButton` に一括適用）。
4. **番組表上部バー統合＆戻る／メニューキー一発上部ジャンプ (`lib/ui/app_shell.dart`, `lib/ui/epg_screen.dart`)**:
   - 横幅 `epgInlineBandBreakpoint` (`600dp`) 以上では `AppBar` 内に `[地デジ | BS]` セレクタと検索・更新アイコンを横 1 列に統合（タイトル横に `'戻る / メニューで上部へ'` ヒントを表示）。
   - `AppShell` に `tabBackHandlersProvider` を追加し、番組グリッド閲覧中に戻るキーまたはリモコンのメニュー (`contextMenu` / `info`) キーを押すと 0 時台まで上スクロールせず一発で上部バー（`地デジ`/`BS`）へフォーカス復帰（上部バー上での戻るキーで従来どおり終了確認ダイアログを表示）。

### 第12弾: Fire OS 8「すべてのファイル」権限付与時の設定画面クラッシュ修正 (`26886a2`)
- **事象・原因 (`android/app/src/main/AndroidManifest.xml`)**: Fire OS 8 実機で「ファイルとメディア → すべてのファイル」を選んだ際、OS 設定アプリ (`ManageAppPermissionsActivity.grantStoragePermissionV2`) が内部で `READ_EXTERNAL_STORAGE` に続けて `WRITE_EXTERNAL_STORAGE` を付与しようとし、マニフェスト未宣言による `SecurityException` で設定アプリ自体がクラッシュして `MANAGE_EXTERNAL_STORAGE` が付与されない問題を実機ログから特定。
- **対策**: `AndroidManifest.xml` に `<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>` を追加宣言。

### 第13弾: 番組表の左メニュー復帰修正＆Live 事前バッファ進捗表示修正 (`4c86497`)
1. **番組表グリッドからの左メニュー (`NavigationRail`) 復帰修正 (`lib/ui/epg_screen.dart`)**:
   - `_GuideView` 内のグリッドラッパーを `FocusScope` から `Focus(canRequestFocus: false, skipTraversal: true)` へ変更し、`FocusScope` 既定の境界停止 (`TraversalEdgeBehavior.stop`) によるフォーカス閉じ込めを解消。メニュー／戻るキーでの一発上部バー移動を保ったまま、グリッド左端・日付バー・上部バー（`地デジ`）のどこからでも左キーで左メニューへ抜けられるよう修正。
2. **Live 事前バッファ「バッファ蓄積中… X / Y秒」の進捗更新修正 (`lib/ui/player_screen.dart`)**:
   - `demuxer-cache-duration` の変更通知に加えて、`_player.stream.bufferingPercentage`（`mpv` の `cache-buffering-state`）、`_player.stream.buffer`（`demuxer-cache-time`）の初期位置からの増分、および事前蓄積中のみ動作する `500ms` 間隔の直接プロパティポーリング (`getProperty`) を統合（算出ロジックを `computePreBufferSeconds` として関数化）。再生前の「0秒 / 30秒」が進行しない問題と再生中 OSD バッファ表示の鮮度を改善。

### 第14弾: Live 事前バッファ実測カウント進行＆早期切替バグ修正 (`b58c83e`)
1. **Live 事前蓄積中の「0秒」停滞解消 (`lib/core/services/interfaces.dart`, `lib/core/dtcp/dtcp_proxy.dart`, `lib/core/services/dtcp_playback.dart`, `lib/ui/player_screen.dart`)**:
   - `DtcpProxy` / `_DtcpPlaybackSession` にオプショナルな転送カウンタ (`StreamTransferMetrics`: `servedBytes`, `firstByteServedAt`, `lastByteServedAt`) を公開。
   - `player_screen.dart` で `useDiskCache=false`（1分未満設定）時に `cache-on-disk=no` を明示設定し、`500ms` ポーリングへ `demuxer-cache-state` JSON の `cache-duration` 読み取り (`parseDemuxerCacheStateDuration`) を追加。
   - シーク不可の Live MPEG-TS で `mpv` の全キャッシュ系プロパティが `0` のまま推移する間は、`advanceLiveTransferSeconds` によりプロキシから実際に復号済みデータが届き始めて流入が続いている時間（上流停止時は自動一時停止）をフォールバック進捗として `computePreBufferSeconds` へ供給し、秒数と下部水色バーが滑らかに進行するよう修正。
2. **初期プリバッファ完了前の「バッファリング中…」誤切替抑止 (`lib/ui/player_screen.dart`)**:
   - `shouldLatchInitialPlaybackStarted`（`_initialPlaybackStarted` ラッチ）を導入し、映像解像度通知 (`width > 0`) が先に届いても `mpv` の初期待ち (`_buffering == true`) が明けて実再生に入るまで「バッファ蓄積中… X / Y秒」表示を維持するよう修正。

### 第15弾: 右画面「戻る」で左メニュー該当機能へ復帰＆再生終了確認ダイアログ (`b90cd80`)
1. **トップ階層での右画面「戻る」→左メニュー（現在表示中のタブ）復帰 (`lib/ui/app_shell.dart`)**:
   - `NavigationRail` へ `_railFocusNode` と各タブのラベルキー (`_railLabelKeys`) を割り当て、ワイドレイアウトで右画面操作中に戻るキーを押した場合、アプリ終了確認を出さずに左メニューの**現在開いている機能項目**へフォーカスを戻すよう改善（左メニュー上にフォーカスがある状態で戻るを押したときのみ `'アプリを終了しますか？'` を表示）。
   - `epg_screen.dart` の既存 `tabBackHandlersProvider[AppTabs.epg]` を活かし、**番組表グリッド内のみ 2 段階**（1回目で上部バー `地デジ/BS`、2回目で左メニュー `'番組表'`、3回目で終了確認）を維持。また `Navigator.push` で開く深い階層の画面は従来どおり 1 つ前の画面へそのまま戻ります。
2. **再生中「戻る」ボタンへの終了確認ダイアログ追加 (`lib/ui/player_screen.dart`)**:
   - `resolvePlayerBackOutcome` に `confirmExit`（`errorOpen` / `exitConfirmOpen` 引数）と `showPlayerExitConfirmDialog` を追加。
   - 番組詳細表示中・OSD 表示中は従来どおり確認なしで閉じ、通常再生中（プリバッファ／中断バナー表示中を含む）に戻るを押したときのみ **`'再生を終了しますか？'`** ダイアログを表示（初期フォーカス `'再生を続ける'`・`'終了する'` 選択時のみ `pop`・キャンセル時はプレイヤー側へフォーカス復帰）。開始エラー画面 (`_error != null`) は確認なしで即終了。

### 第16弾: `radiko` 表記削除＆`<activity android:banner>` 明記 (`f6630bd`, `392bbc6`)
1. **Live バッファ設定説明などからの `radiko` 表記削除 (`lib/ui/settings_screen.dart`, `lib/ui/player_cache_policy.dart`, `test/firetv_mod_test.dart`, `f6630bd`)**:
   - 設定画面 Live バッファ選択ダイアログの説明文・コードコメント・テスト名から `radiko` 表記を削除。
2. **Activity レベルの TV バナー宣言補強 (`android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/drawable/tv_banner.png`, `392bbc6`)**:
   - `<application>` だけでなく `<activity android:name=".MainActivity">` にも `android:banner="@drawable/tv_banner"` を明記し、汎用 `res/drawable/tv_banner.png` も配置して Android TV / カスタムランチャー互換を強化。

### 第17弾: 番組表の整数局幅フィット化＆右端スナップバウンス修正 (`3016574`)
1. **表示幅に応じた整数列フィット幅の算出 (`lib/ui/epg_screen.dart`)**:
   - `_GuideView` のグリッド領域を `LayoutBuilder` で計測し、`resolveEpgChannelWidth`（156〜210dp の範囲で表示幅を整数等分）で 1 局あたりの列幅を自動決定するよう変更（Fire TV `960dp` 環境の 5 局地域では 5 列きっちり `maxScrollExtent == 0` に収まり、5 局目の右端切れを解消）。
2. **`_ChannelSnapPhysics` の動的列幅追従＆右端非バウンス化 (`lib/ui/epg_screen.dart`)**:
   - `_ChannelSnapPhysics` に実際の `channelWidth` を渡し、さらに `resolveEpgSnapTarget` で `maxScrollExtent` を有効な吸着先として扱うよう修正。最右列での上下スクロール時に 0 側へ押し戻される横バウンスを根本解消。

### 第18弾: 公開前仕上げ（タイトル統一・ホーム初期フォーカス・EPG赤塗り＆時刻バー・Live 録画競合＆OSD通知）(`89d8f42`)
1. **タイトル統一 (`lib/ui/home_screen.dart`, `lib/ui/settings_screen.dart`, `test/widget_test.dart`)**:
   - ホーム画面の AppBar タイトルおよび設定画面最下部のバージョン表記を `torne HB FireTV` に統一。
2. **ホーム起動・読み込み時の左メニューフォーカス固定 (`lib/ui/app_shell.dart`)**:
   - 起動直後に左 `NavigationRail`（`ホーム`）へフォーカスを当て、`OrderedTraversalPolicy`・非表示タブへの `ExcludeFocus`・`registrationsProvider` / `selectedRegistrationProvider` 完了時ガードにより、右キーまたはポインタ操作で右ペインへ移らない限り左メニューにフォーカスを残すよう制御。
3. **番組表の録画予約済み表示切替＆時刻列赤太ボーダー (`lib/app/providers.dart`, `lib/ui/settings_screen.dart`, `lib/ui/epg_screen.dart`)**:
   - `epgReservedStyleProvider`（`firetv_epg_reserved_style`）を追加し、設定画面「番組表」セクションから `赤塗りつぶし`（既定・ダーク／ライト共通 `#C62828` 背景＋白文字・白ドット）と `赤枠` を切り替え可能化。
   - 時刻列 `_TimeRuler` 右端に、地デジ・BS・CS すべての予約および取得済み `recordingFlag` 番組を合算マージ (`buildEpgRulerReservedSpans`) した `4dp` 幅の赤太ボーダーを表示。
4. **Live 視聴中の他チャンネル録画競合検知・TV視聴表示・OSD／右上5秒通知 (`lib/ui/live_recording_policy.dart`, `lib/core/services/interfaces.dart`, `lib/core/dtcp/dtcp_proxy.dart`, `lib/core/services/dtcp_playback.dart`, `lib/ui/live_screen.dart`, `lib/ui/player_screen.dart`)**:
   - `StreamTransferMetrics` / `DtcpProxy` に連続再接続エラー数 (`consecutiveReconnectErrors`) を追加。
   - Live 再生中に別チャンネルの録画（90 秒前リード含む）が始まって停止／再接続失敗した際、無駄な無限リトライを即座に止めて `showLiveRecordingConflictDialog` を表示し、決定キー 1 回で録画中チャンネル（品質自動フォールバック付き）へ切り替えられるよう実装。
   - TV視聴一覧・詳細画面およびプレイヤー OSD 上部（`LIVE` 横）へ赤い `● 録画中` バッジを表示し、視聴中の同一チャンネルで録画が始まった／終了したタイミングで画面右上に 5 秒間の `録画中` / `録画終了` 通知を表示。
5. **テスト＆ビルド整備 (`test/epg_test.dart`, `test/firetv_mod_test.dart`, `FIRETV_MOD_LOG.md`, `CLEANUP_BUILD_ENV.md`, `README.md`)**:
   - 全テスト全パス・`dart analyze` 問題ゼロを確認し、公開ブランチ用にドキュメント内のローカルパス表現を汎用表記へ清掃。

### 第19弾: 録画競合ダイアログのフォーカス・バナー遮断＆番組表「現在時刻の赤ライン」リアルタイム更新 (`e1b3640`)
1. **録画競合ダイアログ表示中の背後バナー・フォーカス奪取を完全遮断 (`lib/ui/player_screen.dart`)**:
   - `shouldSuppressPlayerInterruption` を追加し、競合確定時に即座に `_conflictHandled = true`・`_autoResumeDisabled = true`、全タイマー＆全ストリーム購読 (`_subscriptions`) の解除、中断バナー／OSD 非表示化を行ってから `_player.stop()` → `widget.session.stop()` の順で安全に停止するよう修正。
   - すべての再生／中断／エラー／再接続／フォーカス要求ハンドラへ `_conflictHandled || _switchingChannel` ガードを追加し、プロキシ停止直後の `Failed to open ...` で背後の中断バナーが再出現して「今すぐ再開」へフォーカスが奪われる問題を根治。
2. **番組表「現在時刻の赤ライン」の 15 秒リアルタイム更新 (`lib/ui/epg_screen.dart`)**:
   - 従来の静的描画を独立した軽量 `StatefulWidget`（`EpgNowIndicatorLine` ＋ `computeEpgNowOffset`）へ分離し、番組表全体の再構築やフォーカス揺れを起こさず 15 秒周期およびアプリ復帰 (`AppLifecycleState.resumed`) 時に秒単位の端数を含めて自動再配置・日跨ぎ消去するよう修正。
   - テスト更新・回帰テスト 4 件追加後、`dart analyze` 問題ゼロ＆全 637 テスト合格を確認。

### 第20弾: リモコンフォーカス全画面総点検修正・TV視聴/番組表の自動更新・複数台 nasne 統合対応
1. **番組表「検索・更新」到達不能問題の根治＆全画面 D-pad フォーカス総点検 (`lib/ui/epg_screen.dart`, `lib/ui/app_shell.dart`, `lib/ui/schedules_screen.dart`, `lib/ui/schedule_form.dart`, `lib/ui/settings_screen.dart`, `lib/ui/titles_screen.dart`, `lib/ui/widgets.dart`, `lib/main.dart`, `lib/ui/epg_search_screen.dart`, `lib/ui/playback_launcher.dart`, `lib/ui/dtcp_credential_screen.dart`)**:
   - **番組表上部バー／日付バー／グリッド遷移修正**: スクロールアウトした番組タイルが `AppBar` 背後に隠れて方向探索を横取りする問題を解消するため、`AppBar` 内（`地デジ ⇄ BS ⇄ 番組検索 ⇄ 更新`）と日付チップ列・表示領域内先頭タイル間の明示的 D-pad 遷移を制御（`左メニュー` 復帰＆戻る／メニューでの一発上部ジャンプも維持）。
   - **右ペイン上キー制御 (`lib/ui/app_shell.dart`)**: `_rightPaneFocusNode` により、`ホーム` 上端（`本体情報` カード等）や `TV視聴`（`地デジ/BS` タブ）から上キーを押した際、`NavigationRail` へ逃げずにその画面の `AppBar`「更新」ボタン等へ確実に移動するよう改善。
   - **予約画面 `新規予約` ボタンの上部バー移動＆D-pad 時刻選択**: 到達困難だった右下の `FloatingActionButton` を廃し `AppBar` 上部（`更新` 横）へ配置。`schedule_form.dart` のアナログ時計ピッカーを D-pad 増減ボタン式 `FireTvTimePickerDialog` へ置換。
   - **設定／録画済み詳細／各種ダイアログのフォーカス統一**: `登録済み nasne` 行全体をタップで操作メニュー（切替／検証／解除）が開くよう改善し、バッファ選択ダイアログの二重フォーカスを単一ノード (`_BufferOptionTile`) へ解消。録画済み詳細の「保護」行を単一フォーカス＋黄枠強調 (`_ProtectionRow`) 化。削除確認・エラー・再生確認・番組詳細 (`EpgEventDetailDialog` 上下スクロール＋既定ボタン `autofocus`) および `ChipThemeData` / `InputDecorationTheme` のフォーカス枠を統一。
2. **TV視聴・番組表の表示時シームレス自動更新 (`lib/ui/live_screen.dart`, `lib/ui/epg_screen.dart`, `lib/ui/widgets.dart`)**:
   - タブ切り替え表示時およびアプリ復帰 (`AppLifecycleState.resumed`) 時、ならびに番組表 `地デジ ⇄ BS` 切替時に `skipLoadingOnReload: true` 付きで裏更新を行い、スクロール位置・選択状態・フォーカスを保ったまま最新番組・予約状態を反映。
3. **複数台 nasne 統合モード（1台環境は現行仕様を 100% 維持）(`lib/ui/multi_nasne_policy.dart`, `lib/ui/live_recording_policy.dart`, `lib/ui/live_screen.dart`, `lib/ui/player_screen.dart`, `lib/ui/schedules_screen.dart`, `lib/ui/schedule_form.dart`, `lib/ui/titles_screen.dart`, `lib/ui/epg_screen.dart`, `lib/ui/epg_search_screen.dart`, `lib/ui/home_screen.dart`, `lib/ui/tailscale_guard.dart`)**:
   - 登録 nasne が 1 台のみの環境では追加ラベルや切替 UI・追加通信を一切行わず従来どおり動作し、**2 台以上登録時のみ** 以下の統合モードを有効化。
   - **TV視聴・視聴中自動フェイルオーバー**: 全稼働 nasne のチャンネルをサービス統合表示し、開始時に空きチューナー（次点：同チャンネル録画中）の nasne を自動選択。視聴中に録画開始でチューナーが奪われた際、別 nasne に空きがあれば視聴を止めず自動切替＋右上 5 秒通知（全台録画中の場合のみ競合ダイアログを表示）。
   - **録画予約・自動振り分け**: 全 nasne の予約を `[nasne名]` 付きで統合表示（複合キーで ID 重複分離）。新規・番組表からの予約は既定「自動選択」とし、全 nasne で競合チェック後、競合せず HDD 空き容量が最大の nasne へ自動登録。
   - **録画済み・番組表・ホーム・Tailscale**: 録画済み一覧を全 nasne 横断統合（「全 nasne / 個別 nasne」フィルタ＆シリーズまとめ対応、`Map.identity` で ID 衝突安全分離）。番組表／検索は全 nasne の予約・録画状態を合算表示。ホーム画面上部に機器切替バーを追加し、Tailscale ガードはいずれかの登録 nasne に到達できれば待機ダイアログを抑止。
   - テスト追加・更新後、`dart analyze` 問題ゼロ＆全 647 テスト合格を確認。

### 第21弾: Live OSD 録画開始／停止・番組表録画停止・右上30秒通知・OSDバッジ統一・デフォルト録画画質・録画失敗管理
1. **Live 視聴中 OSD の録画開始／停止＆番組表詳細の録画停止 (`lib/ui/live_recording_policy.dart`, `lib/ui/player_screen.dart`, `lib/ui/live_screen.dart`, `lib/ui/epg_screen.dart`)**:
   - `buildImmediateLiveRecordingSchedule` と `isScheduleCurrentlyRecording` を追加し、Live OSD に未録画時は「この番組を録画」（確認ダイアログで番組名＋既定録画画質を表示→`X_GetConflictList` 衝突検査・EPG 一致時は `eventId` 連携で `X_CreateRecordSchedule`、複数台環境で衝突時は別空き nasne 自動振り分け）、録画中は「録画を停止」（確認ダイアログ→`X_DeleteRecordSchedule`）を追加。
   - 番組表／検索詳細ダイアログ (`EpgEventDetailDialog` / `showEpgEventDetail`) で、現在録画中の番組に限り「録画中」小バッジと「録画を停止」ボタンを表示。
2. **Live 右上録画通知の 30 秒延長＆OSD バッジ統一 (`lib/ui/live_recording_policy.dart`, `lib/ui/player_screen.dart`)**:
   - `liveRecordingCornerNoticeDuration = Duration(seconds: 30)` を定義し、視聴中チャンネルでの録画開始・終了に伴う画面右上通知を 5 秒 → 30 秒に延長。
   - `buildPlayerOsdStatusBadge` を追加し、OSD ヘッダー内の「録画中」バッジを `LIVE` と同じ角丸 4px 箱・余白・12px 太字フォント・同一高さに統一。
3. **デフォルト録画画質設定 (`lib/app/providers.dart`, `lib/ui/settings_screen.dart`, `lib/ui/schedule_form.dart`)**:
   - `defaultRecordingQualityProvider` (`firetv_default_recording_quality`, `DR`=100 / `3倍`=230, 既定 `DR`) を追加し、設定画面「録画・予約」の切替・予約作成フォーム初期値（非同期復元追従＋手動変更時固定ガード）・Live 即時録画へ連動。
4. **予約画面での「録画失敗 (`recNgList`)」管理＆ホーム画面同期 (`lib/core/models/live_status.dart`, `lib/ui/format.dart`, `lib/ui/multi_nasne_policy.dart`, `lib/app/providers.dart`, `lib/ui/schedules_screen.dart`, `lib/ui/home_screen.dart`)**:
   - `RecNgItem` へ `desiredQualityMode` / `ngID` 解析と `recNgQualityModeLabel` (`101`/`230` → `3倍`) を追加し、同一 `id` 重複を防ぐ複合キー `recNgDismissKey`・時系列マージ `mergeAndFilterRecNgItems`・永続化 `dismissedRecNgKeysProvider` を実装。
   - `SchedulesScreen` 上部に「予約一覧 / 録画失敗 (N)」切替、詳細ページ／2 ペイン詳細、個別削除「この履歴を削除」、一括「すべて削除」を追加し、ホーム画面 `_RecNgSection` とも即時同期。
5. **現状差分ドキュメント作成・テスト強化 (`FIRETV_CHANGES.md`, `test/firetv_mod_test.dart`)**:
   - 公式 v1.5.0 からの現在の変更仕様一覧＋今回追加機能の別枠解説をまとめたローカル専用資料 `FIRETV_CHANGES.md` を新規作成（公開ブランチ `firetv` には非掲載）。
   - Phase 22 単体・ウィジェットテスト 5 件を追加し、`dart analyze` 問題ゼロおよび全 652 テスト合格を確認。

### 第22弾: Live 起動45秒遅延対策・停止状態即時反映・OSD バッファデザイン統一・Live 追いつきボタン・左右 2 段階チャンネル切替カード
1. **Live 起動時間短縮 (`lib/core/dtcp/dtcp_proxy.dart`, `lib/ui/player_cache_policy.dart`, `lib/ui/player_screen.dart`, `lib/ui/live_screen.dart`)**:
   - `DtcpProxy._handleLegacy` で `HEAD`（`Accept-Ranges: none` 付き `200 OK`）および `Range:`（`416 Range Not Satisfiable` + `Accept-Ranges: none`）プローブを `_claimed` / `_legacyGeneration` と切り離して即応し、`mpv`/`FFmpeg` の初回プローブによる 1 本目 Live ストリーム誤切断を解消。
   - Live MPEG-TS 再生開始時に `demuxer-lavf-analyzeduration=1.5` および品質別 `demuxer-lavf-probesize`（モバイル `512 KiB` / DR `2 MiB`）を設定し、初回フレーム到達計測ログを追加。
   - `_fetchFreshSchedules` に 4 秒タイムアウト＋キャッシュフォールバックを付与。
2. **Live 視聴中「録画を停止」後の状態・バッジ即時反映 & 右上カスタム通知バグ修正 (`lib/ui/live_recording_policy.dart`, `lib/ui/live_screen.dart`, `lib/ui/player_screen.dart`)**:
   - nasne が録画ファイル確定・一覧反映を終える前の再取得で停止済み予約が復活する現象を防ぐため、`schedulesWithoutId` / `schedulesExcludingIds` / `ensureSchedulePresent` および `reconcileLiveRecordingSchedules`（停止済み ID ガード `_stoppedScheduleIds`）を導入。
   - `shouldShowPlayerCornerNotice`（`PlayerCornerNotice`）に分離し、`_cornerRecordingNotice == null` のときでも `_customCornerNoticeText` が確実に表示されるよう修正。
3. **OSD バッファバッジデザイン統一 (`lib/ui/player_screen.dart`)**:
   - `buildPlayerOsdStatusBadge` に `textColor` / `border` 引数を追加し、`_buildBufferBadge()` を `Color(0xB3000000)`（暗い半透明黒）＋ `Colors.white24` 枠＋白文字・角丸 `4px`・`fontSize: 12`・`height: 1.2` で `LIVE` / `録画中` と完全統一。
4. **Live 一時停止後「最新に追いつく」ハイブリッド機能 (`lib/core/services/interfaces.dart`, `lib/core/dtcp/dtcp_proxy.dart`, `lib/core/services/dtcp_playback.dart`, `lib/ui/player_screen.dart`)**:
   - 世代安全な `_pumpGeneration` 付きの `LiveEdgeResettable.resetToLiveEdge()` を `DtcpProxy` / `_DtcpPlaybackSession` に追加。
   - `canSeekWithinLiveCache` により、Live バッファあり＆停止時間 <= バッファ設定時間かつキャッシュ末尾に余裕がある場合は mpv キャッシュ末尾シークで無中断ジャンプ、それ以外は AKE 再認証なしでプロキシの上流を張り直し最新放送時刻へ即再接続。
5. **Live 左右キー 2 段階チャンネル切替カード (`lib/ui/live_channel_switch_policy.dart`, `lib/ui/live_screen.dart`, `lib/ui/player_screen.dart`)**:
   - 放送波（地デジ／BS／CS）内の前後チャンネルをループ解決する `LiveChannelSwitchEntry` / `adjacentLiveChannelIndex` と、TV視聴／EPG 双方の起動経路およびフェイルオーバー後にも切替リストを引き継ぐ `_resolveLiveSwitchContext` / `_switchLivePlayerToChannel`（旧セッション停止前競合チェック＋キャンセル時再生継続＋複数台空きチューナー選択）を実装。
   - `PlayerScreen` に `LiveChannelSwitchPreviewCard`（左右端スライドカード・チャンネル名／番組名／放送時間・5 秒自動消灯・`PlayerBackOutcome.closeChannelPreview`・決定／2 回目押し切替）を実装。
   - `test/firetv_proxy_reconnect_test.dart`・`test/firetv_mod_test.dart` にテスト追加後、`dart analyze` 問題ゼロ・全 658 テスト合格を確認（直後の緊急修正 `d2f3b22` で FFmpeg 初回 `Range: bytes=0-` を `416` で弾かないよう `_parseRangeStart` による `rangeStart > 0` 判定へ改善）。

### 第23弾: チャンネル切替カード「コの字」枠線なし＆ライト白背景・OSD画質切替・追いかけ再生＆可変倍速自動追いつき
1. **チャンネル切替カードの「コの字」・枠線なし・ライト／ナイト配色 (`lib/ui/player_screen.dart`)**:
   - `LiveChannelSwitchPreviewCard` の外側余白・アンバー枠線（`border`）を撤去し、画面端（`left == 0` / `right == 1280`）へ密着させ、内側 2 角のみ `14px` 角丸・画面端側内側パディング `22px` に調整。
   - `Theme.of(context).brightness` に連動し、ダーク時は `Color(0xD90D1117)`＋白文字、ライト時は高不透明白背景（`Color(0xF5FFFFFF)`）＋インディゴ見出し（`#3949AB`）＋黒系文字へ切替。
2. **視聴中 OSD 画質切替（Live・録画済み両方） (`lib/ui/player_screen.dart`, `lib/ui/live_screen.dart`, `lib/ui/titles_screen.dart`)**:
   - `PlayerScreen` に `canSwitchQuality` / `currentUseMobile` / `onSwitchQuality` と `osdQualityButtonLabel`（`画質: 元画質` / `画質: モバイル`）および `_suppressResumeReportOnDispose`（切替元終了時のレジューム誤上書き防止）を追加し、確認ダイアログなしの即時画質切替 `_executeQualitySwitch()`（共通停止ヘルパー `_stopPlaybackForReplacement()` 共有）を実装。
   - `live_screen.dart` では単一チューナー解放後に新画質を試し、録画中エンコーダー競合時は `NasneError` を捕捉して元画質へ安全復帰＋右上通知・後続の左右チャンネル切替／フェイルオーバーへ新画質を引き継ぎ。
   - `titles_screen.dart` では `_buildRecordedPlayerScreen` と `ProviderContainer` ベースの `_reportResumePositionWithContainer` を切り出し、`pushReplacement` 後も途中再生位置（`initialStart`）とレジューム保存・チャプター取得が安全に維持されるよう配線。
3. **Live 一時停止〜未追いつき限定「追いかけ再生」UI・現在位置へ・可変倍速自動追いつき (`lib/ui/player_cache_policy.dart`, `lib/ui/player_screen.dart`)**:
   - `computeMpvBufferPlan` に `liveUseMobile` と `MpvBufferPlan.cachePause` を追加し、Live バッファ `0 秒` でも `cache=yes` / `cache-on-disk=yes` / `readaheadSeconds >= 300`（モバイル `21 MiB/分`・DR `110 MiB/分`、空き `512 MiB` 保護クランプ）＋ `cache-pause-initial=no` / `cache-pause=no` で起動待ちゼロのまま最大 5 分の一時停止蓄積に対応（`test/player_cache_policy_test.dart` 保護のため `mpvCacheMode` は不変）。
   - `liveCatchUpSpeedForLagSeconds`（`>120秒: 2倍`, `>30秒: 1.5倍`, `>1.5秒: 1.25倍`, 下りヒステリシス付き）と `osdLiveStatusBadgeSpec`（`LIVE` 赤 vs 一時停止中 `一時停止` / 再生中 `追いかけ再生` / `追いかけ再生 X倍` `#EF6C00`）を追加。
   - `PlayerScreen` に一時停止検知 `_markLivePaused`・500ms 追従タイマー `_liveCatchUpTimer`・自動変速 `_updateLiveCatchUpSpeed`（Live 設定バッファ分を差し引いた超過バッファ＋推定ラグで判定）・`等速に戻す`/`倍速追いかけ` トグル `_toggleLiveAutoCatchUp`・自動追いつき完了時 OSD フォーカス保護 `_finishLiveCatchUp` を実装し、`現在位置へ` ボタンおよび `追いかけ再生` バッジを一時停止後〜追いつき完了までの間のみ表示するよう改善。
4. **検証 (`test/firetv_mod_test.dart`)**:
   - `plans live initial buffering and timeouts`（DR 時の 512 MiB 保護クランプ含む）および `LiveChannelSwitchPreviewCard` テスト（枠線なし・画面端接地・Light 白背景）を更新し、Phase 25 ポリシーテストを追加して `dart analyze` (`No issues found!`) および全 659 テスト合格を確認。

### 第24弾：テレビ並み字幕サイズ・書体/縁取り/背景カスタマイズ & 放送局準拠 ARIB 字幕表示修正
1. **同梱フォント & 設定 UI / 永続化 (`assets/fonts/`, `pubspec.yaml`, `lib/app/providers.dart`, `lib/ui/settings_screen.dart`, `lib/ui/subtitle_settings_screen.dart`)**:
   - `assets/fonts/` に Google Fonts 由来の `LINESeedJP-Regular.ttf`（SIL OFL 1.1）および `KosugiMaru-Regular.ttf`（Apache 2.0）と各ライセンス文書を同梱し、`pubspec.yaml` へ `LINESeedJP` / `KosugiMaru` として登録。
   - `SubtitleSettingsNotifier`（`firetv_subtitle_settings`、`!ref.mounted` 破棄ガード付き）を `providers.dart` に追加し、`SettingsScreen` の `再生` セクションから開ける `SubtitleSettingsScreen`（上部 190dp ライブプレビュー＋サイズ 3 段階・フォント 5 種・縁取り 3 段階・背景色 3 種・透明度 5 段階・`初期設定に戻す`）を実装。
2. **放送局準拠 ARIB ASS パーサ・段差なし描画・消去タイミング修正 (`lib/ui/subtitle_style_policy.dart`, `lib/ui/subtitle_overlay.dart`, `lib/ui/player_screen.dart`)**:
   - `PlayerScreen` では `SubtitleViewConfiguration(visible: false)` と `sub-ass=yes` / `sub-visibility=no` / `sub-fix-timing=yes` / `sub-clear-on-seek=yes` を設定し、`PlayerSubtitleOverlay` へ移行。
   - `parseAssPlayRes` / `parseAribAssSubtitle` / `resolveRawSubtitleCues` により `\pos`・`\an`・`\1c`/`\c`・同一 Y 行の X 順マージを解析し、`{\p1}...{\p0}` ベクトル描画や制御文字・`\uFFFD` を除去しつつ ARIB 囲み記号（`[字]` 等）や矢印（`→`）を正規化（Android `libaribb24` 非対応のビットマップ DRCS 外字は `〓` に統一）。
   - `TextStyle.backgroundColor` を使わずブロック単位 `Container`＋`StrutStyle(forceStrutHeight: true)`＋枠線＋塗り `Stack` により背景段差を根絶し、`sub-text`/`sub-text-ass` の 250ms 同期ポーリングと `SubtitleActiveWindowTracker`（900ms 超の新発話で過去 7 行滞留を抑止しつつ 2 行バーストや接頭辞更新・plain→ASS 昇格を統合、再生経過時計に基づく 5.5〜9.5 秒自動消去で一時停止中は維持）を実装。
3. **検証 (`test/firetv_mod_test.dart`)**:
   - Phase 26 の単体・ウィジェットテスト 8 件（設定永続化・サイズ／縁取り計算・ARIB 正規化・ASS 解析・ウィンドウ追跡・`SettingsScreen` → `SubtitleSettingsScreen` 操作・`PlayerSubtitleOverlay` 配置／`StrutStyle` 検証）を追加し、`dart analyze` (`No issues found!`) および全 667 テスト合格を確認。

### 第25弾（Phase 27：ARIB TS 座標・消去抽出、`aribb24` 数分後滞留・白文字化修正、1 行ごとピル＆左寄せ＆サイズ再調整、字幕 ON/OFF 永続化、Live バッファ表示統一、左メニュー→右ペインフォーカス遷移）

1. **生 MPEG-TS / TTS からの ARIB 座標・消去抽出 (`lib/core/dtcp/arib_ts_caption_tap.dart`, `lib/core/services/interfaces.dart`, `lib/core/dtcp/dtcp_proxy.dart`, `lib/core/services/dtcp_playback.dart`)**:
   - FFmpeg 6.0 `libavcodec/libaribb24.c`（L277 `// TODO: positioning`）が座標を ASS `\pos` へ出力しない実態を特定し、`DtcpProxy` の平文出力（`_handleLegacy` / `_handleSeekable` / `resetToLiveEdge`）に `AribTsCaptionTap`（188B TS / 192B TTS 自動同期、マルチパケット PAT/PMT による caption PID 特定、ARIB PES 境界の即時フラッシュ、`data_group_id` 第1言語フィルタ、CSI `SWF`/`SDF`/`SDP`/`SSM`/`SHS`/`SVS`/`ACPS`/`APS` 座標解析、`SS3 0x60` デフォルトマクロのゼロ幅処理、および `TIME`+`CS` / 単独 `CS` 消去イベント抽出）を実装し、`AribCaptionLayoutSource` 境界経由で `PlayerScreen` へ供給。
2. **`aribb24` 累積リークによる滞留・白文字化対策、サイズ再調整、1 行ごと左寄せピル＆ON/OFF 永続化 (`lib/ui/subtitle_style_policy.dart`, `lib/ui/subtitle_overlay.dart`, `lib/ui/subtitle_settings_screen.dart`, `lib/app/providers.dart`, `lib/ui/player_screen.dart`)**:
   - `nkoriyama/aribb24` `decoder.c` の `i_control_time +=` 累積リークが `mpv/sub/sd_ass.c` の固定 500 バイト `last_text` バッファを溢れさせて数分後に滞留・音ズレ／字幕ズレ・色タグ落ち（白文字化）を起こす根本原因を特定。`sub-fix-timing=no`、常時 250ms 同期ポーリング、途切れ ASS 末尾クリーンアップ、`shouldResetAribSubtitleDecoder` による映像／音声無影響な字幕トラック単独リセット（`sid=no`→`sid=id`）、`SubtitleActiveWindowTracker`（`mpvSubStartSeconds` 変化・3 行上限）および TS 座標・消去照合（`resolveAribPtsOffset` / `findMatchingAribLayoutEvent` / `hasAribClearSinceCaption` / `applyAribLayoutToCues`）を実装。
   - 文字サイズプリセットを `小 (3.8%)` / `中（標準）(4.8%)` / `大 (6.0%)` へ再調整し、`splitSubtitleCueLines`＋`PlayerSubtitleOverlay` で 1 行ごと個別の角丸ピル背景・左寄せ（`TextAlign.left` / `CrossAxisAlignment.start`）・上下/X 座標追従へ刷新（`SubtitleSettingsScreen` プレビューも同様）。
   - `SubtitlesEnabledNotifier`（`subtitlesEnabledProvider`、`firetv_subtitles_enabled`、既定 `false`）を追加し、`SubtitleSettingsScreen` 先頭スイッチおよび `PlayerScreen` のチャンネル切替・録画切替・再起動を跨いで字幕 ON/OFF を維持。
3. **Live バッファリング表示統一 & 左メニュー右ペインフォーカス遷移 (`lib/ui/player_screen.dart`, `lib/ui/app_shell.dart`)**:
   - `shouldLatchInitialPlaybackStarted` の早期ラッチ抑止と `liveLoadingOverlaySpec`・連続ポーリングにより、Live 開始時（`0 秒` 設定含む）から途中再バッファまで全ケースを **`バッファ蓄積中… X秒`（目標時 `X秒 / Y秒`）＋進捗バー** に統一。
   - `AppShellState.select` に `_focusRightPaneFirst()` を追加し、初回起動時の左メニュー `'ホーム'` 初期フォーカスおよび右ペインからの戻るキー復帰を維持したまま、左メニュー項目押下時に右ペイン先頭へ自動遷移。
4. **検証 (`test/firetv_mod_test.dart`)**:
   - `AribTsCaptionTap`（188B/192B、`SDP`+`SS3 0x60` 座標、副言語 `data_group_id=2` 除外、DTS/PTS ラップアラウンド、デコーダ自動リセット条件、途中切れ ASS 除去）、行分割ピル描画、字幕 ON/OFF 永続化、`liveLoadingOverlaySpec` / 早期ラッチ抑止、`AppShell` 左メニュー→右ペインフォーカス遷移のテストを追加し、`dart analyze` (`No issues found!`) および全 673 テスト合格を確認。

### 第26弾（Phase 28：字幕色復帰＆表示ブレ根絶、左右話者分離、`LINE Seed JP 太字`・影 2 種・16:9 プレビュー、Live 0 秒表示整理、TV 風 Live OSD）

1. **字幕の色保持・表示ブレ根絶・左右話者ブロック分離 (`lib/ui/subtitle_style_policy.dart`, `lib/ui/subtitle_overlay.dart`, `lib/ui/player_screen.dart`)**:
   - `_player.stream.subtitle` が `sub-text-ass` / `sub-start` より先に届いた際の白文字先行登録＆ `SubtitleCue.dedupeKey` 同一判定による色付き ASS 破棄バグを修正：`SubtitleActiveWindowTracker` で同一テキストの色付き ASS 到着時に色・スタイルをインプレース昇格させ、`player_screen.dart` では `Future.wait` による 5 プロパティ一括同時取得と最大 2 回（45ms）の不整合・`sub-start` 据え置き待避ガードにより、表示直後の座標・幅ブレと白文字化を同時に解消。
   - `resolveRawSubtitleCues(atomicSnapshot: true)` による柔軟な ASS/プレーン照合、`findMatchingAribLayoutEvent` の将来先行 TS イベント誤マッチ抑止（`preferredMaxFutureSeconds: 0.6`）、および `PlayerSubtitleOverlay._clusterSubtitleBlocks` の横位置（`xThreshold = 0.14`）分離により、左右の別話者が 1 ブロックへ合体しないよう改善。
2. **フォント追加・表記整理・サイズ微調整・影 2 種・16:9 等比率プレビュー (`assets/fonts/LINESeedJP-Bold.ttf`, `pubspec.yaml`, `lib/ui/subtitle_style_policy.dart`, `lib/ui/subtitle_settings_screen.dart`)**:
   - `LINESeedJP-Bold.ttf`（SIL OFL 1.1）を同梱・登録し、`LINE Seed JP（太字）` を追加（`丸ゴシック` の表記も簡潔化）。サイズ倍率を `小 (4.2%)` / `中（標準）(5.2%)` / `大 (6.4%)` へ微調整。
   - `SubtitleEdgeStyle` に排他 5 択（`なし` / `縁取り（細め）` / `縁取り（太め）` / `影（右下）` / `影（ズレなし・厚め）`）＋ `resolveSubtitleTextShadows` を導入し、設定画面を `ChoiceChip` 選択および仮想 `960×540` `FittedBox` 内蔵の **16:9 比率プレビュー** へ刷新（`小` と `中` の下限張り付きを解消）。
3. **Live 0 秒待機表示の整理 & TV 風 Live OSD (`lib/ui/player_screen.dart`, `lib/ui/live_screen.dart`)**:
   - `liveLoadingOverlaySpec` / `_shouldPollLiveBuffering` を更新し、Live バッファ `0 秒` 設定時は `'読み込み中…'`（秒数・バーなし）、`>= 5 秒` 設定時のみ `'バッファ蓄積中… X秒 / Y秒'`＋進捗バーに統一。
   - `PlayerOsdClockOverlay`（OSD 表示中の左上 `HH:mm` 時刻）、`LiveOsdProgramInfo` / `resolveLiveOsdProgramInfo`、`LiveOsdProgramSection`（現番組名・放送予定時間・残り分数・進行グラフバー・次番組名＆放送時間）を実装し、`live_screen.dart` `_buildLivePlayerScreen` から既存 EPG キャッシュ＆バックグラウンド取得を配線。
4. **検証 (`test/firetv_mod_test.dart`)**:
   - 色昇格・先行イベント除外・左右話者分離・影 2 種描画・16:9 プレビュー拡大縮小・TV 風 Live OSD（番組切替跨ぎ含む）および `0 秒` 時 `'読み込み中…'` の単体／ウィジェットテストを更新・追加し、`dart analyze` (`No issues found!`) および全 676 テスト合格を確認。

---

## 3. 全変更・追加ファイル一覧 (vs アップストリーム `78d74a8`)

| 種別 / ファイル | 主な変更・追加内容 |
| :--- | :--- |
| `README.md` | 非公式 Fire TV フォークの明記・MIT ライセンス／共存注記を追加 |
| `CLEANUP_BUILD_ENV.md` | ビルド用に一時導入したツール・キャッシュ・作業ディレクトリの削除手順（ローカル用） |
| `FIRETV_CHANGES.md` | 公式 v1.5.0 からの現在の変更仕様まとめ＋追加機能別枠ドキュメント（ローカル専用） |
| `FIRETV_MOD_LOG.md` | 本ドキュメント（Fire TV 改修ログ・技術知見・再ビルド手順・ローカル専用） |
| `assets/fonts/` (`LINESeedJP-Regular.ttf`, `LINESeedJP-Bold.ttf`, `KosugiMaru-Regular.ttf` ほかライセンス) | 字幕選択用フォント（LINE Seed JP Regular/Bold・Kosugi Maru）のバンドルアセット |
| `pubspec.yaml` | `LINESeedJP` (Regular 400 / Bold 700) / `KosugiMaru` フォントファミリーのアセット登録を追加 |
| `android/app/build.gradle.kts` | `applicationId` を `com.markun.tmhb.firetv`、`versionName` を `-firetv` に変更 |
| `android/app/src/main/AndroidManifest.xml` | TV 用 `LEANBACK_LAUNCHER` / `tv_banner`（`<application>` ＋ `<activity>` 双方） / `READ_EXTERNAL_STORAGE` + `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion="32"`) + `MANAGE_EXTERNAL_STORAGE` 宣言 |
| `android/app/src/main/res/drawable/tv_banner.png` / `drawable-xhdpi/tv_banner.png` | Fire TV ホーム画面用バナー画像 |
| `android/app/src/main/cpp/CMakeLists.txt` | `tmhb_aes.c` (`-O3`) のビルド対象追加 |
| `android/app/src/main/cpp/tmhb_aes.c` | ネイティブ C T-table AES-128-CBC 復号実装 (`tmhb_aes128_cbc_decrypt` 等) |
| `android/app/src/main/kotlin/com/markun/tmhb/MainActivity.kt` | `com.markun.tmhb/firetv_helper` MethodChannel（音量最大化・VPN/Tailscale・`MANAGE_EXTERNAL_STORAGE` 判定/設定誘導＋ファイルスキャン・`StatFs` 残容量 `getCacheAvailableBytes`） |
| `lib/app/bootstrap.dart` | `fileStoreContainer` に `mpvCacheDirectory` オプション引数を追加 |
| `lib/app/firetv_helper.dart` | Fire TV 向け Platform Channel ラッパー（`getCacheAvailableBytes()` ほか） |
| `lib/app/providers.dart` | `PlaybackQualityNotifier` 任意設定化（既定 `元画質`）、`DefaultRecordingQualityNotifier`（既定 `DR`）、`DismissedRecNgKeysNotifier`、`NightModeNotifier`、`GroupTitlesNotifier`（既定 ON）、`EpgReservedStyleNotifier`（既定 `fill`）、`SubtitleSettingsNotifier`（`firetv_subtitle_settings`、`!ref.mounted` ガード付き）、`SubtitlesEnabledNotifier`（`firetv_subtitles_enabled`、既定 OFF）、`mpvCacheDirectoryProvider`、録画/Live バッファ設定、`autoReconnect` 有効化 |
| `lib/core/models/live_status.dart` | `RecNgItem` へ `desiredQualityMode` / `ngID` 解析を追加 |
| `lib/core/dtcp/arib_ts_caption_tap.dart` | 生 MPEG-TS (188B) / TTS (192B) から PAT/PMT/ARIB PES・CSI 座標 (`SDP`/`SSM`/`SVS`/`ACPS`/`APS`) と `TIME`/`CS` 消去イベントを直接抽出 (`AribTsCaptionTap`) |
| `lib/core/dtcp/native_aes.dart` | `libtmhb_fcntl.so` の Dart FFI バインディング |
| `lib/core/dtcp/dtcp_crypto.dart` | Android でのネイティブ AES 復号優先パス |
| `lib/core/dtcp/dtcp_proxy.dart` | 4ms ループ譲歩、`resetClient()`、`autoReconnect` 無制限バックオフ復帰（一時エラー時のタイムシーク保持）、AKE 再認証、Live 再オープン `409` 回避・旧ハンドラ解放、`HEAD`/`Range`(`416`+`Accept-Ranges: none`) プローブ分離、世代安全 `_pumpGeneration` ＋ `resetToLiveEdge()`、`bufferOutput = false`、`isLive` 限定 EOF 再接続、Seekable 正常 EOF 打ち切り & `_eofByte` 416、転送カウンタ公開、`_aribCaptionTap` 平文 TS 字幕抽出配線 |
| `lib/core/services/dtcp_playback.dart` | `PlaybackKeySource.forceReauthenticate()`、`DtcpPlaybackEngine(autoReconnect: ...)`、`isLive` 伝播、`_DtcpPlaybackSession` の `StreamTransferMetrics` / `LiveEdgeResettable` / `AribCaptionLayoutSource` 実装 |
| `lib/core/services/interfaces.dart` | 任意実装の転送メトリクス境界 `StreamTransferMetrics`、最新エッジ再接続境界 `LiveEdgeResettable`、および ARIB TS 座標／消去取得境界 `AribCaptionLayoutSource` を追加 |
| `lib/main.dart` | `mpv_cache` 初期化/清掃、`ja-JP` ロケール固定 + `DefaultTextStyle` 補完、ライト/ナイトモード両テーマ + フォーカス枠 (`ChipThemeData` / `InputDecorationTheme` / `FloatingActionButtonThemeData` 含む)・`SegmentedButton` 個別セグメント反転強調テーマ |
| `lib/ui/app_shell.dart` | Fire TV ナビゲーション/シェル調整、`TailscaleGuard` 統合、`OrderedTraversalPolicy` + `ExcludeFocus` による起動／ホーム初回読み込み時左メニューフォーカス固定、`_rightPaneFocusNode` ＋ `_focusRightPaneFirst()` によるメニュー選択時の右ペイン先頭への自動遷移・上キーの `AppBar` 遷移、戻るキーの左メニュー該当項目復帰・ルート終了確認ダイアログ |
| `lib/ui/dtcp_credential_screen.dart` | 2 カラム入力（`FireTvTextInputField` 化）・上部アクション・アプリ内ファイルピッカー・各ダイアログ `autofocus` 改善 |
| `lib/ui/epg_screen.dart` | 広幅画面 `AppBar` 1 列統合・スクロール後タイル横取り防止付き上部バー/日付チップ/表示内グリッド明示 D-pad 遷移＆左メニュー復帰維持、表示時/復帰時/帯域切替時シームレス自動更新 (`skipLoadingOnReload`)、整数局幅フィット＋右端吸着修正、`EpgEventDetailDialog` 上下スクロール・既定ボタン `autofocus`・録画中「録画を停止」ボタン、複数台 nasne 予約・録画合算表示 (`findMatchingOwnedSchedule`)、時刻列 `_TimeRuler` 右端赤太ボーダー、現在時刻赤ライン 15 秒リアルタイム更新 (`EpgNowIndicatorLine`) |
| `lib/ui/epg_search_screen.dart` | `FireTvTextInputField` (`autofocus` 有効化・決定キー入力)、複数台 nasne 横断の予約済み赤ドット＆詳細 `'予約を編集'` / `'録画を停止'` 連動 |
| `lib/ui/format.dart` | WebAPI `recNgListGet` 用の録画画質表記 `recNgQualityModeLabel` を追加 |
| `lib/ui/home_screen.dart` | タイトルを `torne HB FireTV` に統一、2 台以上登録時の上端 nasne 切替バー、600dp 以上 2 カラム配置、全 6 カード D-pad フォーカス＆`scrollCacheExtent` 最下部スクロール対応、録画失敗カードのアプリ内削除同期 |
| `lib/ui/live_channel_switch_policy.dart` | Live 視聴中の左右 2 段階チャンネル切替モデル・インデックス計算 (`LiveChannelSwitchEntry`, `ChannelSwitchDirection`, `adjacentLiveChannelIndex`) |
| `lib/ui/live_recording_policy.dart` | チューナー録画競合検知・Live チャンネル照合・画面端録画通知 (`LiveRecordingCornerNotice` / 30 秒)・複数台フェイルオーバー候補保持・即時録画作成・停止直後除外/合成ヘルパー (`schedulesWithoutId` / `schedulesExcludingIds` / `ensureSchedulePresent`)・録画実行中判定 |
| `lib/ui/live_screen.dart` | 表示時/復帰時シームレス自動更新、複数台 nasne チャンネル統合・空きチューナー自動選択・視聴中自動フェイルオーバー、4 秒予約取得タイムアウト、OSD 即時録画／録画停止配線、Live OSD 用現/次番組 EPG キャッシュ＋裏取得配線 (`_serviceEventsFromGuide`)、バンド内チャンネル切替コンテキスト解決＆事前競合チェック付き切替コールバック、OSD 画質切替（競合フォールバック・左右 CH 引き継ぎ付き）、デフォルト画質追従＋都度切替、`● 録画中` バッジ表示 |
| `lib/ui/multi_nasne_policy.dart` | 複数台 nasne 統合用ポリシー（サービス統合・空きチューナー優先選択・予約統合＆HDD 空き容量優先自動振り分け・`recNgList` 複合キー＆統合フィルタ・複合キー分離） |
| `lib/ui/playback_launcher.dart` | エラー／資格情報案内／未実装ダイアログの初期ボタン `autofocus` 対応 |
| `lib/ui/player_cache_policy.dart` | Android 向けデマクサバッファ削減設定、Live/録画別長時間バッファ・ディスクキャッシュ配分ポリシー (`MpvBufferPlan` / `computeMpvBufferPlan`：Live バッファ 0 秒時も起動待ちゼロのまま裏タイムシフト 5 分＋空き 512 MiB 保護)、可変倍速追いかけ判定 (`liveCatchUpSpeedForLagSeconds`)、Live MPEG-TS 初期プローブ短縮定数 |
| `lib/ui/player_screen.dart` | フルスクリーン D-pad 操作（録画: ±10秒統一 / Live: 左右 2 段階「コの字」枠線なし＆ライト白背景 `LiveChannelSwitchPreviewCard`）、シークバー HUD、OSD（右上時刻連携ではなく左上 `PlayerOsdClockOverlay` `HH:mm`、Live 現番組/時間/進行バー/次番組 `LiveOsdProgramSection`、Live 一時停止時限定 `一時停止` / `追いかけ再生` オレンジバッジ・`現在位置へ`・`等速に戻す`/`倍速追いかけ` 自動追いつき制御・Live/録画両対応 `画質: 元画質/モバイル` 即時切替・暗い半透明黒70%統一 `_buildBufferBadge`・`'この番組を録画'`/`'録画を停止'`〔停止ID即除外 `reconcileLiveRecordingSchedules`〕）、独自 `PlayerSubtitleOverlay`（既定 `SubtitleView` 無効化・`sub-fix-timing=no`・一括同時同期取得＋不整合リトライ・`sub-text-ass`/`sub-ass-extradata` 解析・常時 250ms 同期ポーリング・`shouldResetAribSubtitleDecoder` 自動再初期化・`AribCaptionLayoutSource` 座標/消去照合・`subtitlesEnabledProvider` ON/OFF 永続化・`SubtitleActiveWindowTracker` 滞留防止＆色昇格）、Live 0 秒 `'読み込み中…'` / `>=5秒` `'バッファ蓄積中… X秒 / Y秒'` ＋進捗バー統一 (`shouldLatchInitialPlaybackStarted` / `liveLoadingOverlaySpec`)、`PlayerCornerNotice`（右上30秒録画＆5秒カスタム通知）、Live 初期プローブ短縮設定・競合検知、終了確認、事前バッファ、`cache-on-disk`、無制限自動再開 |
| `lib/ui/schedule_form.dart` | `FireTvTextInputField` 化、`FireTvTimePickerDialog`（D-pad 時刻設定）、デフォルト録画画質連動、競合警告キャンセル `autofocus`、2 台以上登録時の「録画する nasne」指定／空き容量＆競合考慮の自動振り分け |
| `lib/ui/schedules_screen.dart` | `新規予約` の `AppBar` 上部移動（FAB 廃止）、詳細 `autofocusEdit`、複数台 nasne 予約時刻順統合一覧＆複合キー管理、「予約一覧 / 録画失敗」管理（詳細・個別削除・すべて削除） |
| `lib/ui/settings_screen.dart` | 手動登録欄 `FireTvTextInputField` 化、登録済み nasne 行タップメニュー（切替/検証/解除）、単一フォーカス `_BufferOptionTile`、ナイトモード・番組表予約表示設定・デフォルト録画画質・デフォルト再生画質切替・Live/録画バッファ設定・`字幕表示設定` エントリ・バージョン表記統一 |
| `lib/ui/subtitle_overlay.dart` | ARIB 字幕用独自オーバーレイ `PlayerSubtitleOverlay`（1 行ごと個別角丸ピル背景・X 座標差による話者ブロック分離・左寄せ・上下/X 放送局座標追従、`StrutStyle(forceStrutHeight: true)`、縁取り 2 種＋影 2 種描画） |
| `lib/ui/subtitle_settings_screen.dart` | 16:9 比率（仮想 `960×540` `FittedBox`）上部常時ライブプレビュー＋先頭 `字幕表示（再生時の既定）` スイッチ付き `SubtitleSettingsScreen`（サイズ 3 段階・書体 6 種・縁取り/影 5 種・背景色 3 種・透明度 5 段階・初期設定リセット） |
| `lib/ui/subtitle_style_policy.dart` | 字幕プリセット定義（`0.042`/`0.052`/`0.064`・`LINE Seed JP 太字`・`影（右下）`/`影（ズレなし・厚め）`＋`resolveSubtitleTextShadows`）、`SubtitleSettings`、`normalizeAribSubtitleSymbols`、`parseAssPlayRes` / `parseAribAssSubtitle`、`splitSubtitleCueLines`、`subtitleTextMatchesAss`、`resolveRawSubtitleCues`、`SubtitleActiveWindowTracker`（色昇格維持）、TS 照合・デコーダリセット判定 |
| `lib/ui/tailscale_guard.dart` | LAN 未到達/VPN オフ時の Tailscale 接続補助ガード（複数台時はいずれか到達で待機抑止） |
| `lib/ui/title_list_filter.dart` | 番組タイトル正規化 (`extractSeriesBaseTitle`)・2パス自動まとめ (`groupRecordedTitles` / `TitleGroup`) を追加 |
| `lib/ui/titles_screen.dart` | 1/4 サムネ詳細 UI、デフォルト画質追従＋都度切替、再生中 OSD 画質切替向け `_buildRecordedPlayerScreen` ＆ `ProviderContainer` レジューム報告、保護行 `_ProtectionRow` の単一フォーカス＆黄枠強調、削除不能ダイアログ `autofocus`、検索欄 `FireTvTextInputField`、`'番組まとめ'` フォルダ化、2 台以上登録時の複数台横断一覧＆nasne フィルタ（ID 重複安全分離） |
| `lib/ui/widgets.dart` | `FireTvTextInputField` (`autofocus` 対応)、`confirmDialog` キャンセル `autofocus`、`asyncSection` `skipLoadingOnReload` 対応、`SectionCard` フォーカス枠・スクロール連動 |
| `test/credential_flow_test.dart` | 資格情報画面の `FireTvTextInputField` ダイアログ入力へ追従 |
| `test/dtcp_streaming_test.dart` | `DtcpProxy` の `servedBytes` / `firstByteServedAt` / `lastByteServedAt` 転送カウンタ検証を追加 |
| `test/epg_search_test.dart` | 番組検索画面の `FireTvTextInputField` ダイアログ入力・デバウンス動作へ追従 |
| `test/epg_test.dart` | `resolveEpgChannelWidth` 導入後の動的列幅境界スナップ検証へ追従 |
| `test/firetv_mod_test.dart` | Fire TV 改修全般（入力UI・ネイティブAES・バッファ設計・設定・ナイトモード・`SegmentedButton`・10秒シーク・EPG全般/赤塗り/時刻バー/検索更新D-pad移動・録画まとめ・戻る導線・録画競合検知＆通知・Home 2カラム＆初期フォーカス固定・全画面フォーカス総点検・自動更新・複数台 nasne 統合・Live停止即時反映/通知修正/左右枠なしコの字CH切替カード/OSD画質切替/追いかけ再生可変倍速追いつき/Phase 26〜28 字幕カスタマイズ・生 TS ARIB 解析・色昇格＆話者分離・影 2 種・16:9 プレビュー・Live 0秒表示・TV 風 Live OSD・左メニュー右ペインフォーカス遷移）のテスト |
| `test/firetv_proxy_reconnect_test.dart` | 純 Dart 環境（実ループバック HTTP）での `DtcpProxy` 無制限自動再接続テスト（録画途中切断・Live 再オープン非 `409`・`HEAD`/`Range` 非切断 & `resetToLiveEdge`・Seekable 短め EOF 打ち切り・非 Seekable 録画 EOF 非再接続） |
| `test/playback_quality_test.dart` | 画質固定解除・初期 `元画質`・詳細都度切替非永続化へのテスト更新 |
| `test/ui_test.dart` | Fire TV UI 構成・ダイアログ入力・画質設定仕様・日本語 Material ローカライズ (`BackButton`) 反映 |
| `test/widget_test.dart` | `torne HB FireTV` タイトル統一への追従 |

---

## 4. アップストリーム作者様向け技術メモ（Fire OS 8 / `AFTKRT` 実機知見）

1. **録画再生時の 30 秒 `reason=6 ANR`（32-bit ARMv7 + Flutter 3.50）**:
   - `AFTKRT` は 64-bit ではなく 32-bit `armeabi-v7a` 環境であり、さらに Flutter 3.50 では Dart UI とプラットフォームスレッドが統合されています。
   - 純 Dart の `pointycastle` で DTCP-IP PCP パケットを連続復号すると UI スレッドの CPU を 99% 占有してしまい、再生開始約 30 秒で OS の ANR 強制終了 (`reason=6`) を踏みます。
   - `tmhb_aes.c` によるネイティブ C 復号（`-O3`）と `DtcpProxy` の定期的なイベントループ譲歩（4ms ごと）を組み合わせることで劇的に解消しました。
2. **Fire OS 8 における漢字の中華フォント（「中華グリフ」）問題**:
   - Fire OS 8 の `/system/etc/fonts.xml` を確認したところ、`NotoSansCJK-Regular.ttc` に対して `<family lang="zh-Hans">`（TTC index 2）が `<family lang="ja">`（TTC index 0）よりも前に定義されています。
   - Dart/Flutter 側で明示的に日本語ロケールを渡さないと、Skia/Impeller が上位の `zh-Hans` グリフを選択し、多くの漢字が中国語字形で描画されます。
   - `MaterialApp` に `locale: const Locale('ja', 'JP')`, `supportedLocales: const [Locale('ja', 'JP')]`, `localizationsDelegates: GlobalMaterialLocalizations.delegates`（および保険として `DefaultTextStyle.merge(style: const TextStyle(locale: Locale('ja', 'JP')))`）を指定することで、確実に `lang="ja"` (index 0) が選択されるようになります。
   - ※副作用として Material の `BackButton` ツールチップが `'Back'` から `'戻る'` へ正しく日本語化されるため、テストで `tester.pageBack()`（英語ツールチップ決め打ち）を使っていた箇所は `find.byType(BackButton)` へ置き換える必要があります。
3. **Fire TV 固有の入力・フォーカス・OS 制約への配慮**:
   - **露出 `TextField` と `FireTVIME` フォーカス閉じ込め**: Fire OS では D-pad でフォーカスが `TextField` に当たっただけで IME キーボードが自動起動し、さらに矢印キーが IME 側に吸われて抜け出せなくなる挙動があります。入力欄を通常時は表示用ボックス (`FireTvTextInputField`) にし、決定キー押下時だけ `AlertDialog` 内の `TextField` を開くことで完全に回避できました。
   - **番組表 (EPG) タイルの選択視認性**: 番組タイルがジャンル別に色分けされているため、`focusColor` による薄い背景オーバーレイでは選択位置が非常に見づらくなります。`focusColor: Colors.transparent`＋前面 `DecoratedBox` の太枠線が有効でした。
   - **ファイル選択**: Fire OS は標準 `DocumentsUI` を持たない機種が多く、通常のファイルピッカー Intent が失敗します。アプリ内候補スキャンが有効でした。なお Fire OS 8 の「すべてのファイル」設定画面 (`ManageAppPermissionsActivity.grantStoragePermissionV2`) は `READ_EXTERNAL_STORAGE` と併せて `WRITE_EXTERNAL_STORAGE` も付与しようとするため、`MANAGE_EXTERNAL_STORAGE` 単独宣言では設定アプリ側が `SecurityException` でクラッシュします（`maxSdkVersion="32"` 付きで両方宣言することで回避）。
   - **サイドロード時のホーム画面バナー＆右上背景画像**: Fire OS 8 標準ランチャー (`com.amazon.tv.launcher`) は Amazon Appstore 経由のアプリについてサーバー側から横長バナーとフォーカス時右上背景画像 (`1920x1080`) を取得するため、サイドロード APK の場合は `android:banner` を `<application>` / `<activity>` 双方に設定しても標準ランチャー上ではグレー枠＋正方形アイコン表示にフォールバックし、右上背景も表示されない（Android TV や Projectivy 等のカスタムランチャーでは `android:banner` がそのまま有効になる）。
   - **中断バナー・エラー画面の `FocusNode` 喪失**: 再生中断バナーやエラー画面が出現した際、明示的に `FocusNode.requestFocus()` を行わないとリモコンで「再開」「戻る」が押せなくなります。
   - **車載・不安定回線とストレージ保護**: `libmpv.so` が `cache-on-disk` / `demuxer-cache-dir` に対応しているため、空き容量の少ない Fire TV Stick でも `StatFs` で `512 MiB` 以上の空きを死守しつつ長時間先読みを確保できます。また不安定回線での途中切断に備え、プロキシ側の自動再接続（AKE 再認証含む）＋ Live 再オープン許容が有効です。

---

## 5. アップストリーム更新時の再適用＆クリーン APK ビルド手順

### 5.1 リベース / 再適用時の注意箇所
アップストリーム更新後に `firetv-mod` をリベース／チェリーピックする際は、主に以下の競合ポイントを確認してください。
- `lib/ui/player_screen.dart` / `lib/ui/player_error_policy.dart`（フルスクリーン OSD / ±10秒シーク / シークバー HUD / 事前バッファ / 自動再開・フォーカス / 録画終了時自動復帰 / 戻るキー二重発火抑止）
- `lib/ui/title_list_filter.dart` / `lib/ui/titles_screen.dart` / `lib/ui/live_screen.dart` / `lib/ui/multi_nasne_policy.dart`（番組自動まとめ・折りたたみフォルダ・保護行単一フォーカス・自動更新・複数台チューナー選択/フェイルオーバー/横断タイトル統合）
- `lib/ui/dtcp_credential_screen.dart` / `lib/ui/settings_screen.dart` / `lib/ui/home_screen.dart` / `lib/ui/epg_screen.dart` / `lib/ui/epg_search_screen.dart` / `lib/ui/schedules_screen.dart` / `lib/ui/schedule_form.dart` / `lib/ui/widgets.dart` / `lib/ui/app_shell.dart`（各入力ダイアログ・D-pad 時刻選択・全画面フォーカス遷移・EPG 上部バー到達/自動更新・複数台予約統合/自動振り分け・Home 切替バー）
- `lib/core/dtcp/dtcp_proxy.dart` / `dtcp_crypto.dart` / `lib/core/services/dtcp_playback.dart`
- `lib/app/providers.dart` / `lib/main.dart` / `android/app/build.gradle.kts` / `AndroidManifest.xml` / `MainActivity.kt`

### 5.2 クリーン APK ビルド＆実機 Download 配置手順（個人情報をビルドに埋め込まない方式）
第11弾以降はビルド時プリセット注入を行わず、秘密情報ゼロのクリーンな APK をビルドします。資格情報は端末の `Download` フォルダへ `.env` ファイルを配置し、アプリ内ピッカー（「Download フォルダの権限を許可」→ 全ファイルアクセス許可後に選択）から取り込みます。

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME="$HOME/development/jdk-21/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
# リリース署名を使う場合のみ設定（未設定時は debug 鍵で署名）
export TMHB_KEY_PROPERTIES="$HOME/.android/tmhb-firetv-key.properties"

cd <repo-dir>
flutter build apk --release

# 出力 APK を任意の場所へコピーして Fire TV へインストール
cp build/app/outputs/flutter-apk/app-release.apk \
   ../TorneMobileHomeBrew/TorneMobileHomeBrew-1.5.0-firetv.apk
"$ANDROID_HOME/platform-tools/adb" connect <FIRETV_IP>:5555
"$ANDROID_HOME/platform-tools/adb" -s <FIRETV_IP>:5555 install -r \
   ../TorneMobileHomeBrew/TorneMobileHomeBrew-1.5.0-firetv.apk

# 必要に応じて資格情報ファイルを Fire TV の Download フォルダへ転送（取込後は端末から削除推奨）
"$ANDROID_HOME/platform-tools/adb" -s <FIRETV_IP>:5555 push \
   /path/to/credentials.env /sdcard/Download/credentials.env
```
