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

バージョンは指定どおり `v0.01` です。詳細は英語の[README](../README.md)・[設計](DESIGN.md)をご覧ください。
