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
  - 配信画質: nasne 側のモバイル画質 (`quality=mobile`) 固定（DTCP-IP over LAN / Tailscale VPN / モバイル回線車載利用を想定）

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
  - 画質選択は nasne モバイル画質 (`quality=mobile`) 固定化。
- **再生画面 (`lib/ui/player_screen.dart`, `lib/main.dart`)**:
  - フルスクリーン再生、D-pad リモコンによる再生/一時停止/シーク/チャプター送り/音声切替・情報 OSD、全体的な Amber フォーカス枠 (`_buildTheme`) を実装。

### 第2弾: ビルド時個人プリセット対応 (`a1307e1`)
- `--dart-define-from-file` 経由で個人の DTCP-IP 証明書・秘密鍵・nasne 登録情報をビルド時に注入できる `FireTvPreset` (`lib/app/firetv_preset.dart`) を追加。
- 初回起動時のみ自動投入（`firetv_preset_cred_applied` / `firetv_preset_nasne_applied` フラグで管理）し、手動削除・編集や再復元ボタン (`dtcp_credential_screen.dart`) と共存できるよう設計。

### 第3弾: 実機録画再生 ANR・クラッシュ解消 (`b6cce9a`)
- **事象**: Live は読み込み中くるくるが出ず黒画面のまま待機し、録画再生は音声のみ約 30 秒流れた後、`reason=6 ANR`（メインスレッド CPU 99%）でアプリが落ちる問題を実機ログから特定。
- **原因**: Fire OS 8 (`armeabi-v7a` 32-bit) ＋ Flutter 3.50（UI/プラットフォームスレッド統合）環境では、純粋 Dart の `pointycastle` による AES-128-CBC 復号が DTCP-IP バースト転送時にメインスレッド CPU を占有し続けていた。
- **対策**:
  1. C 言語 FIPS-197 T-table 実装のネイティブ AES-128-CBC (`android/app/src/main/cpp/tmhb_aes.c`, `CMakeLists.txt` `-O3`, `lib/core/dtcp/native_aes.dart`, `dtcp_crypto.dart`) を導入し、`libtmhb_aes.so` へ FFI オフロード。
  2. `DtcpProxy` (`lib/core/dtcp/dtcp_proxy.dart`) に 4ms ごとの協調的イベントループ譲歩を追加し、UI/入力応答を確保。
  3. メモリ制約のある Android/Fire TV 向けに初期録画デマクサバッファを軽量化 (`player_cache_policy.dart`: `androidRecordingDemuxerMaxBytes` = 8 MiB / `Back` = 4 MiB)。
  4. `PlayerScreen` に Live/録画共通の初期読み込み＆バッファリング中スピナー表示を追加。

### 第4弾: シークバー HUD・車載用長時間バッファ・無制限自動再接続・中華フォント修正（本コミット）
1. **録画再生シークバー HUD (`lib/ui/player_screen.dart`, `lib/ui/titles_screen.dart`)**:
   - 下部オーバーレイ型のシークバー HUD（左/右などの操作で表示し 3 秒後に自動消灯、リモコンフォーカスを奪わないため左右連打・長押しが可能）。
   - 操作バッジ（`+30秒` / `-10秒` / 連続加算 `+1分30秒` / `再生` / `一時停止` / チャプタースキップ）、番組タイトル、`現在位置 / 総時間`、残り時間、先読み済みバッファバー、チャプター目盛り、シーク直後のプレビュー＆700ms 保持を表示。
   - nasne メタデータ由来の `knownDuration` フォールバックを `titles_screen.dart` から受け渡し。
   - フル OSD 下部とシークバーセクション（`_buildSeekBarSection`）を共通化し、設定中バッファ表示バッジも併記。
2. **録画・Live 別バッファ時間設定とディスクキャッシュ (`lib/ui/player_cache_policy.dart`, `settings_screen.dart`, `MainActivity.kt`, `bootstrap.dart`, `main.dart`)**:
   - **録画のバッファ時間（先読み）**: `標準 (0秒)` / `30秒` / `1分` / `3分` / `5分`（デフォルト）/ `10分` / `15分` / `30分` / `45分` / `60分` を設定画面「再生」から選択可能。
     - 再生開始は約 5 秒 (`cache-pause-wait` <= 5) で素早く始めつつ、バックグラウンドで設定時間まで先読み。
     - 60 秒以上の設定時は `mpv` の `cache-on-disk=yes` ＋ `demuxer-cache-dir=<tempDir>/mpv_cache`（前方最大 `1200 MiB`、後方最大 `150 MiB`）を有効化。
     - Android `StatFs` (`getCacheAvailableBytes`) で `/data` 空き容量を計測し、必ず **`512 MiB` 以上の空き容量 (`minFreeDiskReserveBytes`)** を残すよう自動制限・低容量時 RAM フォールバックを実施。アプリ起動時・プレイヤー終了時にキャッシュディレクトリを清掃。
   - **Live のバッファ時間（遅延再生）**: `標準 (0秒)`（デフォルト）/ `15秒` / `30秒` / `1分` / `3分` / `5分` から選択可能。radiko のように事前蓄積 (`cache-pause-initial=yes`, `cache-pause-wait=bufferSeconds`) を行い、蓄積中は「バッファ蓄積中… X / Y秒」＋プログレスバーを表示。
3. **2 段階無制限自動再接続＆Fire TV フォーカス修正 (`lib/core/dtcp/dtcp_proxy.dart`, `dtcp_playback.dart`, `lib/app/providers.dart`, `player_screen.dart`)**:
   - **プロキシ層 (`DtcpProxy` / `DtcpMediaFetcher` / `PlaybackKeySource`)**:
     - Android (`autoReconnect: Platform.isAndroid`) ではリトライ上限を設けず（バックオフ `3秒 -> 5秒 -> 8秒 -> 10秒`、受信再開でリセット）、`DtcpMediaFetcher.resetClient()` ＋ `PlaybackKeySource.forceReauthenticate()`（AKE 再認証）を挟んで録画（途中切断/早期 EOF）・Live の双方で自動復旧。
     - Live 再オープン時の `409 Conflict` を抑止するため、`autoReconnect` 有効時は `_handleLegacy` で既存接続を安全に差し替え可能に変更（通常デスクトップ等の既存動作 `autoReconnect == false` は不変）。
   - **プレイヤー層 (`PlayerScreen`)**:
     - ネットワーク断を検知してもプレイヤー画面が開いている間は何度でも無制限で自動再開カウントダウン＆再開ウォッチドッグを動作させ、オフライン巻き戻し可能範囲は既存バッファでの視聴を継続可能。
     - Fire TV で発生していた中断バナー・エラー画面上のフォーカストラップを解消（`_resumeButtonFocusNode` / `_closeBannerFocusNode` / `_errorBackFocusNode` への明示的な `requestFocus()`、`FocusTraversalGroup` 配置、Select/Enter キーで即時再開）。
4. **Fire OS 中華フォント（「中華グリフ」）対策 (`lib/main.dart`)**:
   - `TmhbApp` の `MaterialApp` に `locale: const Locale('ja', 'JP')`, `supportedLocales: const [Locale('ja', 'JP')]`, `localizationsDelegates: GlobalMaterialLocalizations.delegates` を設定し、`builder` 内でも `DefaultTextStyle.merge(style: const TextStyle(locale: Locale('ja', 'JP')))` を補完。

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
| `lib/app/providers.dart` | `mpvCacheDirectoryProvider`, `recordedBufferSecondsProvider`, `liveBufferSecondsProvider`, `autoReconnect` 有効化 |
| `lib/core/dtcp/native_aes.dart` | `libtmhb_aes.so` の Dart FFI バインディング |
| `lib/core/dtcp/dtcp_crypto.dart` | Android でのネイティブ AES 復号優先パス |
| `lib/core/dtcp/dtcp_proxy.dart` | 4ms ループ譲歩、`resetClient()`、`autoReconnect` 無制限バックオフ復帰（一時エラー時のタイムシーク保持）、AKE 再認証、Live 再オープン `409` 回避・旧ハンドラ解放、`bufferOutput = false`（auto-gzip 抑止） |
| `lib/core/services/dtcp_playback.dart` | `PlaybackKeySource.forceReauthenticate()`、`DtcpPlaybackEngine(autoReconnect: ...)` |
| `lib/main.dart` | `mpv_cache` 初期化/清掃、`ja-JP` ロケール固定 + `DefaultTextStyle` 補完、Amber フォーカス枠テーマ |
| `lib/ui/app_shell.dart` | Fire TV ナビゲーション/シェル調整、`TailscaleGuard` 統合 |
| `lib/ui/dtcp_credential_screen.dart` | 2 カラム入力・上部アクション・アプリ内ファイルピッカー・プリセット復元ボタン |
| `lib/ui/live_screen.dart` | Fire TV 操作調整・`mobile` 画質固定 |
| `lib/ui/player_cache_policy.dart` | Android 軽量既定値、録画(0〜60分)/Live(0〜5分) バッファ選択肢、`computeMpvBufferPlan`（ディスクキャッシュ上限 & 512 MiB 保護） |
| `lib/ui/player_screen.dart` | フルスクリーン D-pad 操作、シークバー HUD、OSD、事前バッファ蓄積表示、ディスクキャッシュ適用/掃除、無制限自動再開、中断バナー/エラー画面フォーカス修正 |
| `lib/ui/settings_screen.dart` | 「再生」セクションへの録画/Live バッファ選択ダイアログ追加ほか |
| `lib/ui/tailscale_guard.dart` | LAN 未到達/VPN オフ時の Tailscale 接続補助ガード |
| `lib/ui/titles_screen.dart` | 1/4 サムネ詳細 UI、`mobile` 画質固定、`knownDuration` 引き渡し |
| `test/firetv_mod_test.dart` | Fire TV 改修（UI・プリセット・ネイティブAES・バッファ設計・設定画面・ロケール）の単体/ウィジェットテスト |
| `test/firetv_proxy_reconnect_test.dart` | 純 Dart 環境（実ループバック HTTP）での `DtcpProxy` 無制限自動再接続テスト（録画途中切断 & Live 再オープン非 `409`） |
| `test/playback_quality_test.dart` | Fire TV 画質固定仕様に合わせたテスト更新 |
| `test/ui_test.dart` | Fire TV UI 構成 & 日本語 Material ローカライズ (`BackButton`) 反映 |
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
3. **Fire TV 固有の入力・OS 制約への配慮**:
   - **ファイル選択**: Fire OS は標準 `DocumentsUI` を持たない機種が多く、通常のファイルピッカー Intent が失敗します。アプリ内候補スキャンが有効でした。
   - **`FireTVIME` と `FocusNode` 喪失**: エラー画面や再生中断バナーが出現した際、明示的に `FocusNode.requestFocus()` を行わないと `FireTVIME` や背後にフォーカスが抜けてリモコンで「再開」「戻る」が一切押せなくなる罠がありました。
   - **車載・不安定回線とストレージ保護**: `libmpv.so` が `cache-on-disk` / `demuxer-cache-dir` に対応しているため、空き容量の少ない Fire TV Stick でも `StatFs` で `512 MiB` 以上の空きを死守しつつ 60 分前後の先読み・オフライン巻き戻しキャッシュを安全に確保できます。また不安定回線での途中切断に備え、プロキシ側の自動再接続（AKE 再認証含む）＋ Live 再オープン許容が有効です。

---

## 5. アップストリーム更新時の再適用＆個人プリセット APK ビルド手順

### 5.1 リベース / 再適用時の注意箇所
アップストリーム更新後に `firetv-mod` をリベース／チェリーピックする際は、主に以下の競合ポイントを確認してください。
- `lib/ui/player_screen.dart`（フルスクリーン OSD / シークバー HUD / 事前バッファ / 自動再開・フォーカス）
- `lib/ui/titles_screen.dart` / `lib/ui/live_screen.dart`（1/4 サムネレイアウト・画質固定・`knownDuration` 引き渡し）
- `lib/ui/dtcp_credential_screen.dart` / `lib/ui/settings_screen.dart` / `lib/ui/app_shell.dart`
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
