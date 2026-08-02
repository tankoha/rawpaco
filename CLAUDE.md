# CLAUDE.md

このリポジトリは tree-sitter-pascal を用いた FPC/Lazarus Pascal 向け静的解析（lint）ツール rawpaco の実装です。実装言語は FPC (Object Pascal) 自身で、tree-sitter の C API を cdecl 外部宣言で直接呼び出します。

セッション間の引き継ぎ事項は HANDOFF.md を参照してください。決着した論点は都度 HANDOFF.md から削除し、git history に委ねます。

## 開発ルール

### 1. FPC RTL関数使用時の検証ルール

使用頻度の低い RTL 関数・プラットフォーム固有 API を使う場合は、実装前に freepascal.org のドキュメントで存在を確認すること。確認できない場合は、コード内コメントまたは HANDOFF.md にその旨を明記し、コンパイルが成功することのみをもって正しさの根拠としない。

### 2. tree-sitter-pascal のバージョン固定方針

tree-sitter-pascal はバージョンをピン留めする。更新する際は差分を確認し、既存ルールへの影響をチェックしてから取り込む。

### 3. ルール追加時のテスト方針

lint ルールを追加する際は、positive サンプル（誤検知してはいけないコード）と negative サンプル（検知すべきコード）の両方を必須とする。

### 4. 自己lintのCI組み込み

本ツールで自身のソースを lint し、警告ゼロを維持するステップを CI に追加する。

### 5. 誤検知時の基本姿勢

false positive の回避を優先する。疑わしきは見逃す（検知しない）方針とする。

### 6. スコープ外の明記

Oxygene は対象外。tree-sitter-pascal は Delphi/FPC 系 Pascal のみを対象とする。

### 7. クロスプラットフォームビルド確認

Windows / Linux 両環境でのビルド確認を CI に組み込む。

### 8. コードコメント方針

コメントは「なぜ」を残すために書く。設計判断の理由（特に複数の方針がありえた箇所での選択理由）、tree-sitter-pascal の制約回避のための実装、false positive 回避のための緩め実装については、コメントを必須とする。それ以外の自明なコメントは書かない。
