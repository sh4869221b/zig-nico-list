# zig-nico-list

niconicoのユーザー投稿・マイリストから動画IDを取得するZig製CLIです。go-nico-list v0.29.0をもとに、実行スケジューラ・メモリ所有権・JSON読み取り・数値ソートを再設計しています。

## インストール

[Releases](https://github.com/sh4869221b/zig-nico-list/releases)からWindows x86-64用ZIPまたはLinux x86-64用tar.gzを取得し、SHA256SUMSで確認して展開します。実行時にZig、Go、Pythonのインストールは不要です。

WindowsではPowerShellで `.\zig-nico-list.exe --help`、Linuxでは `./zig-nico-list --help` を実行してください。

```sh
zig-nico-list https://www.nicovideo.jp/user/123
zig-nico-list --json -T3 -P4 -H8 https://www.nicovideo.jp/mylist/123
zig-nico-list --dedupe --stdin < targets.txt
```

動画ID・JSONは標準出力へ、ログ・進捗・サマリー・エラーは標準エラーへ出力します。`--url`で視聴URL、`--no-sort`で順序変更なし、`--comment`でコメント数、`--dateafter`・`--datebefore`で投稿日の範囲を指定できます。日付は両端を含みます。

`-T`は対象数、`-P`は対象内のページ数、`-H`はHTTPリクエスト数を制御します。`-A`は明示固定されていない層を自動調整します。サービスのレート制限に配慮してください。

## 開発

Zig 0.17.0を使用します。

```sh
zig build -Doptimize=fast -Dcpu=baseline
zig build test -Doptimize=safe
python tests/integration.py zig-out/bin/zig-nico-list
```

Windowsのテスト実行時は末尾を `zig-nico-list.exe` にします。

CIはWindows/Linuxのネイティブ環境でユニット・ローカルHTTP統合テストを実行します。実サービスへアクセスするテストではありません。ログ文面、時刻表示、進捗表示、HTTPメトリクスの詳細形式はGo版と異なります。Windowsのコンソール割り込みは通常のOS終了動作を使用します。

バージョンは `v0.03` です。詳細は英語の[README](../README.md)・[設計](DESIGN.md)をご覧ください。

## CIのキャッシュと再現性検証

通常CIはReleaseSafeユニットテストとReleaseFast実行ファイルビルドの両方にキャッシュを使用し、OSごとに別runnerで並列実行します。キャッシュがあっても毎回新しい出力先へbuildし、commit・ソース・設定・SHA-256を検証し、統合テストを実行します。releaseもこの検証を使用します。

空のlocal/global cacheで2回buildする検査は、手動専用の「Manual cold reproducibility」へ分離しました。通常CI・releaseの成功だけではcold buildの再現性を保証しません。既存v0.01のタグと配布物は変更していません。詳細は[CI検証契約](../scripts/README.md)を参照してください。

## CIの起動条件

通常の「Test CI」はmainへのpush、main宛PRの作成・更新・再オープン・編集、または手動実行で起動します。feature branchへのpush単独やタグpushでは起動しません。変更ファイルに応じてユニット、実行ファイル＋統合テスト、Python、Zig整形、文書チェックを選び、文書のみの変更ではZigビルドを省略します。手動実行は全検証です。集約チェック「CI」は省略されたジョブと失敗を区別します。

releaseはv＋数字で始まるタグpushまたは明示的な手動実行で、変更箇所にかかわらず全検証を実施してからdraftを作成します。cold再現性検証は引き続き手動専用です。定期実行、branch protection、権限やsecretsの設定は変更していません。

再利用した接続が応答ヘッダーを一切返さず終了した場合に限り、元のタイムアウト期限内で新しい接続へGETを1回だけ再送します。再送開始数は`transport_replays`で記録し、通常の試行・再試行数と区別します。部分的なヘッダー、403/429などの応答、本文エラーやタイムアウトはこの再送の対象外です。ローカル再現で確認した改善であり、過去のWindows実行の原因を確定するものではありません。
