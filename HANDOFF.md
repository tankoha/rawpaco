# HANDOFF.md

このファイルはセッション間の引き継ぎ用です。決着した論点は都度削除し、git historyに委ねてください（詳細な運用ルールはCLAUDE.mdを参照）。

## 実装済みルール一覧

| ID | 内容 | 状態 | 備考 |
|---|---|---|---|
| (未着手) | | | |

## 見送ったルール（検討済み・意図的に未実装）

- (該当なし)

## tree-sitter-pascal 文法カバレッジの既知の穴

- (未検証。着手後、パース失敗・誤認識した構文とサンプルコードをここに追記)

## 自己lint到達状況

- 本ツール自身のソースへの自己適用: 未実施
- 鶏卵問題の解消範囲: N/A（lintルールが1つも存在しないため、CIへの自己lintステップ追加は次回以降に見送り。CLAUDE.mdルール4は最初のルール実装後に着手）

## tree-sitter本体・tree-sitter-pascalのvendoring方針（確定）

- 方式: OS提供の共有ライブラリ（apt/choco等）には依存せず、ソースをリポジトリにvendoringしCコンパイラで静的リンクする。CLAUDE.mdルール2（バージョン固定）にも合致。
- `vendor/tree-sitter/`: tree-sitter本体ランタイムを `v0.24.7` で固定。`lib/src/lib.c`（単一ファイル版アマルガメーション）と `lib/include/tree_sitter/api.h` を取り込み済み。ABIバージョンは14（`TREE_SITTER_LANGUAGE_VERSION`）。
- `vendor/tree-sitter-pascal/`: `v0.10.2` で固定。生成済み `src/parser.c` を取り込み済み（外部スキャナ(scanner.c)なし）。生成時ABIも14で一致（`LANGUAGE_VERSION 14`）。tree-sitter本体はABI13〜14を互換サポートしており組み合わせ上の問題なし。
- ビルド: リポジトリルートの `Makefile` が `vendor/*/src/*.c` を `gcc` でコンパイルし `build/*.o` を生成、`src/TSBindings.pas` の `{$L ../build/tree-sitter.o}` 等で静的リンクする。`make` 一発で `src/rawpaco` まで生成される。
- 既知の落とし穴: `-k` 経由で手動に `-lc` を渡すとFPCがダイナミックリンカのパスを誤検出し（このUbuntu環境では存在しない `/lib/ld64.so.1` になる）実行不能バイナリが生成される。`{$linklib c}` ディレクティブでFPC自身にlibcリンクを解決させることで回避（`TSBindings.pas` にコメントあり）。
- Windows CI初回実行（2026-08-02, run 30759838476）: `build-linux` は成功。`build-windows` は `fpc: command not found` で失敗。原因はchocoインストールによるマシンPATH（レジストリ）更新が、GitHub Actionsの同一ジョブ内後続ステップ（別プロセスとして起動）に反映されないため。gccが動いていたのは、mingwインストールが効いたのではなく、Windowsランナーに元々含まれる別経路のgcc（Strawberry Perl等）がPATHにあったためと推測。対策として、chocoインストール直後に `fpc.exe` / `gcc.exe` の実際の設置場所を検索し `$GITHUB_PATH` に明示追記するよう修正済み。再実行結果は未確認（要フォローアップ）。

## 直近セッションのメモ

- FPC開発環境をローカルに導入済み（Ubuntu 24.04、apt経由: fpc 3.2.2+dfsg-32, fpc-source, lazarus 3.0）。
- tree-sitter本体・tree-sitter-pascalのvendoring、Makefileによるビルド、`src/rawpaco.lpr` からのtree-sitter-pascal経由パース（自己チェック用の最小プログラム）まで動作確認済み（Linux）。詳細は上記セクション参照。
- `.github/workflows/ci.yml` を追加（Linux/Windowsの2ジョブ）。LinuxはCI相当のローカル手順（apt install fpc → make → 実行）を確認済み。Windows側は未検証（上記参照）。
- 次のステップ: Windows CIジョブの実機検証、実際のlintルール第1号の実装（positive/negativeサンプル込み、CLAUDE.mdルール3）、ルール実装後に自己lintのCI組み込み（ルール4）。

## 関連プロジェクト（参考・棚卸し対象外）

- CodeTools方式によるFPC/Lazarus向け静的解析ツールは別リポジトリで構想のみ管理（GPL-3.0-or-later予定、実装未着手）。詳細は当該リポジトリのREADME参照。本HANDOFF.mdでは追跡しない。
