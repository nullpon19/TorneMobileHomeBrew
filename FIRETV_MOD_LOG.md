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

### 第5弾: 操作性・UI改善（10秒シーク統一・画質選択解除・IME閉じ込め防止・EPG枠フォーカス・ナイトモード）（本コミット）
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

---

## 3. 全変更・追加ファイル一覧 (vs アップストリーム `78d74a8`)

| 種別 / ファイル | 主な変更・追加内容 |
| :--- | :--- |
| `CLEANUP_BUILD_ENV.md` | ビルド用に一時導入したツール・キャッシュ・作業ディレクトリの削除手順 |
| `FIRETV_MOD_LOG.md` | 本ドキュメント（Fire TV 改修ログ・技術知見・再ビルド手順） |
| `android/app/build.gradle.kts` | `applicationId` を `com.markun.tmhb.firetv` に変更 |
| `android/app/src/main/AndroidManifest.xml` | TV 用 `LEANBACK_LAUNCHER` / `tv_banner` / ストレージ権限宣言 |
| `android/app/src/main/res/drawable-xhdpi/tv_banner.png` | Fire TV ホーム画面用バナー画像 |
| `android/app/src/main/cpp/CMakeLists.txt` | `tmhb_aes.c` (`-O3`) のビルド対象追加 |
| `android/app/src/main/cpp/tmhb_aes.c` | ネイティブ C T-table AES-128-CBC 復号実装 (`tmhb_aes128_cbc_decrypt` 等) |
| `android/app/src/main/kotlin/com/markun/tmhb/MainActivity.kt` | `com.markun.tmhb/firetv_helper` MethodChannel（音量最大化・VPN/Tailscale・ストレージ/ピッカー・`StatFs` 残容量 `getCacheAvailableBytes`） |
| `lib/app/bootstrap.dart` | `fileStoreContainer` に `mpvCacheDirectory` オプション引数を追加 |
| `lib/app/firetv_helper.dart` | Fire TV 向け Platform Channel ラッパー（`getCacheAvailableBytes()` ほか） |
| `lib/app/firetv_preset.dart` | ビルド時プリセット投入 (`FireTvPreset`, `applyFireTvPresetsIfNeeded`) |
| `lib/app/providers.dart` | `PlaybackQualityNotifier` 任意設定化（既定 `元画質`）、`NightModeNotifier` / `nightModeProvider`、`mpvCacheDirectoryProvider`、録画/Live バッファ設定、`autoReconnect` 有効化 |
| `lib/core/dtcp/native_aes.dart` | `libtmhb_fcntl.so` の Dart FFI バインディング |
| `lib/core/dtcp/dtcp_crypto.dart` | Android でのネイティブ AES 復号優先パス |
| `lib/core/dtcp/dtcp_proxy.dart` | 4ms ループ譲歩、`resetClient()`、`autoReconnect` 無制限バックオフ復帰（一時エラー時のタイムシーク保持）、AKE 再認証、Live 再オープン `409` 回避・旧ハンドラ解放、`bufferOutput = false`（auto-gzip 抑止） |
| `lib/core/services/dtcp_playback.dart` | `PlaybackKeySource.forceReauthenticate()`、`DtcpPlaybackEngine(autoReconnect: ...)` |
| `lib/main.dart` | `mpv_cache` 初期化/清掃、`ja-JP` ロケール固定 + `DefaultTextStyle` 補完、ライト/ナイトモード両テーマ + フォーカス枠テーマ |
| `lib/ui/app_shell.dart` | Fire TV ナビゲーション/シェル調整、`TailscaleGuard` 統合 |
| `lib/ui/dtcp_credential_screen.dart` | 2 カラム入力（`FireTvTextInputField` 化）・上部アクション・アプリ内ファイルピッカー・プリセット復元ボタン |
| `lib/ui/epg_screen.dart` | `_EventTile` の `focusColor` 無効化＋3px 前面フォーカス枠線描画 |
| `lib/ui/epg_search_screen.dart` | `FireTvTextInputField` 化（`autofocus` 解除・決定キーで検索語入力） |
| `lib/ui/live_screen.dart` | Fire TV 操作調整、デフォルト画質追従＋詳細画面都度切替（既定値非破壊） |
| `lib/ui/player_cache_policy.dart` | Android 軽量既定値、録画(0〜60分)/Live(0〜5分) バッファ選択肢、`computeMpvBufferPlan`（ディスクキャッシュ上限 & 512 MiB 保護） |
| `lib/ui/player_screen.dart` | フルスクリーン D-pad 操作（左右 ±10 秒統一）、シークバー HUD、OSD、事前バッファ蓄積表示、ディスクキャッシュ適用/掃除、無制限自動再開、中断バナー/エラー画面フォーカス修正 |
| `lib/ui/schedule_form.dart` | 長さ/条件 ID/録画先の 3 欄を `FireTvTextInputField` 化 |
| `lib/ui/settings_screen.dart` | 手動登録欄 `FireTvTextInputField` 化、「表示」→ナイトモードスイッチ、「再生」→デフォルト画質切替＆Live 上・録画下バッファ設定 |
| `lib/ui/tailscale_guard.dart` | LAN 未到達/VPN オフ時の Tailscale 接続補助ガード |
| `lib/ui/titles_screen.dart` | 1/4 サムネ詳細 UI、デフォルト画質追従＋都度切替、`knownDuration` 引き渡し、検索欄 `FireTvTextInputField` 化 |
| `lib/ui/widgets.dart` | 決定キーでダイアログ入力を開く共通 `FireTvTextInputField` / `_FireTvTextInputDialog` 追加 |
| `test/credential_flow_test.dart` | 資格情報画面の `FireTvTextInputField` ダイアログ入力へ追従 |
| `test/epg_search_test.dart` | 番組検索画面の `FireTvTextInputField` ダイアログ入力・デバウンス動作へ追従 |
| `test/firetv_mod_test.dart` | Fire TV 改修全般（入力UI・プリセット・ネイティブAES・バッファ設計・設定・ナイトモード・10秒シーク・EPG枠フォーカス・ロケール）のテスト |
| `test/firetv_proxy_reconnect_test.dart` | 純 Dart 環境（実ループバック HTTP）での `DtcpProxy` 無制限自動再接続テスト（録画途中切断 & Live 再オープン非 `409`） |
| `test/playback_quality_test.dart` | 画質固定解除・初期 `元画質`・詳細都度切替非永続化へのテスト更新 |
| `test/ui_test.dart` | Fire TV UI 構成・ダイアログ入力・画質設定仕様・日本語 Material ローカライズ (`BackButton`) 反映 |
| `test/widget_test.dart` | アプリタイトル/初期化更新への追従 |

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
   - **ファイル選択**: Fire OS は標準 `DocumentsUI` を持たない機種が多く、通常のファイルピッカー Intent が失敗します。アプリ内候補スキャンが有効でした。
   - **中断バナー・エラー画面の `FocusNode` 喪失**: 再生中断バナーやエラー画面が出現した際、明示的に `FocusNode.requestFocus()` を行わないとリモコンで「再開」「戻る」が押せなくなります。
   - **車載・不安定回線とストレージ保護**: `libmpv.so` が `cache-on-disk` / `demuxer-cache-dir` に対応しているため、空き容量の少ない Fire TV Stick でも `StatFs` で `512 MiB` 以上の空きを死守しつつ長時間先読みを確保できます。また不安定回線での途中切断に備え、プロキシ側の自動再接続（AKE 再認証含む）＋ Live 再オープン許容が有効です。

---

## 5. アップストリーム更新時の再適用＆個人プリセット APK ビルド手順

### 5.1 リベース / 再適用時の注意箇所
アップストリーム更新後に `firetv-mod` をリベース／チェリーピックする際は、主に以下の競合ポイントを確認してください。
- `lib/ui/player_screen.dart`（フルスクリーン OSD / ±10秒シーク / シークバー HUD / 事前バッファ / 自動再開・フォーカス）
- `lib/ui/titles_screen.dart` / `lib/ui/live_screen.dart`（1/4 サムネレイアウト・画質都度切替・`knownDuration`・検索入力ダイアログ）
- `lib/ui/dtcp_credential_screen.dart` / `lib/ui/settings_screen.dart` / `lib/ui/epg_screen.dart` / `lib/ui/epg_search_screen.dart` / `lib/ui/schedule_form.dart` / `lib/ui/widgets.dart` / `lib/ui/app_shell.dart`
- `lib/core/dtcp/dtcp_proxy.dart` / `dtcp_crypto.dart` / `lib/core/services/dtcp_playback.dart`
- `lib/app/providers.dart` / `lib/main.dart` / `android/app/build.gradle.kts` / `MainActivity.kt`

### 5.2 個人プリセット APK ビルド手順（秘密情報をソースに残さない方式）
一時ファイル（例: `/tmp/tmhb_firetv_preset.json`、権限 `0600`）に以下のキーを格納してビルドし、ビルド直後に削除します（以下の値は**すべてダミーのプレースホルダ**です）。

```json
{
  "TMHB_PRESET_CERT_HEX": "<176-hex-cert>",
  "TMHB_PRESET_KEY_HEX": "<40-hex-key>",
  "TMHB_PRESET_NASNE_HOST": "<192.168.x.x>",
  "TMHB_PRESET_NASNE_UDN": "<uuid:...>",
  "TMHB_PRESET_NASNE_NAME": "<nasne-name>",
  "TMHB_PRESET_NASNE_MAC": "<XX:XX:XX:XX:XX:XX>"
}
```

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME="/Users/nullpon/development/jdk-21/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"

cd /Users/nullpon/Documents/Git/nasne/TorneMobileHomeBrew-FireTV
flutter build apk --release --dart-define-from-file=/tmp/tmhb_firetv_preset.json
rm -f /tmp/tmhb_firetv_preset.json

# 出力 APK を親フォルダへ配置し Fire TV へインストール
cp build/app/outputs/flutter-apk/app-release.apk \
   /Users/nullpon/Documents/Git/nasne/TorneMobileHomeBrew/TorneMobileHomeBrew-1.5.0-firetv.apk
"$ANDROID_HOME/platform-tools/adb" connect <FIRETV_IP>:5555
"$ANDROID_HOME/platform-tools/adb" -s <FIRETV_IP>:5555 install -r \
   /Users/nullpon/Documents/Git/nasne/TorneMobileHomeBrew/TorneMobileHomeBrew-1.5.0-firetv.apk
```
