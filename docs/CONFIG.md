# 設定ファイル (`rawpaco.json`)

rawpaco の設定は JSON ファイル `rawpaco.json` に書きます。現時点で設定を使うルールは `RAWPACO-STYLE-001`（命名規則）だけです。

実装は `src/RawpacoConfig.pas`、ルール本体は `src/Rules/RuleStyle001.pas` です。

## 探索順

1. `--config=<path>` が指定されていればそのファイル。読めない・壊れている場合は**エラーで終了**します（終了コード 2）。明示指定を黙って無視すると事故になるためです。
2. 指定が無ければ、カレントディレクトリから親方向へ `rawpaco.json` を探します。
3. どこにも無ければ全て既定値で動作します。

設定ファイルに **未知のキーがあるとエラー**になります。設定のタイプミスが「黙って何も起きない」になるのが最悪の失敗モードなので、寛容に無視しません。

## スキーマ

以下は既定値をそのまま書き下したものです。

```json
{
  "naming": {
    "enabled": true,
    "class":        ["T", "E"],
    "object":       ["T"],
    "record":       ["T"],
    "interface":    ["I"],
    "enum":         ["T"],
    "pointer":      ["P"],
    "privateField": ["F"]
  }
}
```

| キー | 対象 |
|---|---|
| `naming.enabled` | `false` にすると命名規則チェック全体を無効化する |
| `naming.class` | `TFoo = class ... end`。`class helper` / `record helper` もここに含む |
| `naming.object` | `TFoo = object ... end` |
| `naming.record` | `TFoo = record ... end` |
| `naming.interface` | `IFoo = interface ... end` |
| `naming.enum` | `TFoo = (a, b)` |
| `naming.pointer` | `PFoo = ^TFoo` |
| `naming.privateField` | `class` の `private` / `protected` セクションのフィールド |

各カテゴリの値には「許可する接頭辞」を書きます。書ける形は次の4通りです。

- 文字列の配列（例: `["T", "E"]`）— いずれかで始まれば OK
- 単一の文字列（例: `"T"`）— 要素1個の配列と同じ
- `false` — そのカテゴリのチェックを無効化
- `null` / `[]` — 同上

## 既定で見ないもの

既定 on にしているのは、Delphi と Lazarus/FPC の双方で広く合意されている範囲だけです。以下は意図的に対象外にしています（理由は `src/Rules/RuleStyle001.pas` 冒頭のコメントにも記載）。

- **record / object のフィールド**: `F` 接頭辞の慣習はクラスの非公開フィールド（プロパティのバッキング）に対するものであって、レコードのフィールドには当てはまりません（RTL の `TFormatSettings` がまさにそうです）。
- **public / published / 可視性指定なしのクラスフィールド**: `F` は非公開フィールドの目印であり、公開フィールドに要求する慣習はありません。
- **ジェネリック型の型引数** (`generic TBox<T>` の `T`、`TKey` / `TValue` 等): 型名ではないので対象外です。型名側（`TBox`）は見ます。
- **型別名・手続き型・配列型・集合型・`class of`** (`MyInt = Integer` 等): カテゴリを設けていません。RTL 自身が `RawByteString` のように接頭辞なしの別名を多用しており、既定で警告するとノイズになるためです。
- **引数の `A` 接頭辞・定数の UPPER_CASE・グローバル変数の `g` 接頭辞・列挙値の接頭辞**: コミュニティで揺れているため既定 off にしており、現時点では設定で有効化することもできません（対象ノードを増やす別の作業になります）。

## よくある調整

**接頭辞の照合は大文字小文字を区別します。** `T` を要求している以上 `tFoo` は違反とみなすのが自然だからです。一方で、接頭辞の直後が大文字であることは要求しません（Lazarus で一般的な `TfrmMain` を弾かないため）。

FPC のコードベースには `fBuffer` のような小文字始まりの非公開フィールドも多くあります。その流儀のプロジェクトでは次のように両方を許可してください。

```json
{ "naming": { "privateField": ["F", "f"] } }
```

C ヘッダの機械的な移植や JVM/Android のバインディングを多く含むプロジェクト（FPC 本体の `rtl/java`、`packages/winunits-*` 等がそうです）では、命名規則チェックを丸ごと切るのが現実的です。

```json
{ "naming": { "enabled": false } }
```
