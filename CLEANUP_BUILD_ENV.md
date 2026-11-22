# Fire TV 暫定ビルド環境のクリーンアップ手順

今回、ローカルで `TorneMobileHomeBrew-1.5.0-firetv.apk` をビルドするために導入したツール類を、後から綺麗に削除したい場合は以下のコマンドを実行してください。

## 1. Flutter SDK と JDK 21 を削除（約 2.5〜3GB 回復）
```bash
rm -rf ~/development
```
（今回の環境では `~/development/flutter` と `~/development/jdk-21` のみを配置しており、システム領域への常駐設定や `~/.zshrc` の書き換えは行っていません。）

## 2. Dart / Flutter / Gradle のビルドキャッシュを削除（数 GB 回復）
他の Flutter / Android 開発を行っていない場合は、キャッシュも削除できます。
```bash
rm -rf ~/.pub-cache ~/.gradle ~/.flutter-devtools ~/.dart-tool ~/.config/flutter
```

## 3. ビルド用に自動取得された Android SDK コンポーネントを確認・削除（任意）
既存の `~/Library/Android/sdk` 自体を残しつつ、今回ビルドで追加ダウンロードされた `platforms/android-*`、`ndk`、`cmake` 等だけ整理したい場合は、以下の中身を確認のうえ不要なバージョンのみ削除してください。
```bash
ls -la ~/Library/Android/sdk/platforms ~/Library/Android/sdk/ndk ~/Library/Android/sdk/cmake
```

## 4. ソースコード作業ディレクトリの削除（APK だけ残す場合）
完成した APK は `/Users/nullpon/Documents/Git/nasne/TorneMobileHomeBrew/TorneMobileHomeBrew-1.5.0-firetv.apk` に保存済みのため、ソース一式が不要になれば以下で削除できます。
```bash
rm -rf /Users/nullpon/Documents/Git/nasne/TorneMobileHomeBrew-FireTV
```
