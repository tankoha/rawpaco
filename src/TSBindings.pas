unit TSBindings;

{$mode objfpc}{$H+}

// tree-sitter 本体はCライブラリのため、ABI互換のためcdeclで宣言する。
// 型・関数シグネチャは tree-sitter 公式ヘッダ(api.h)未照合のブートストラップ版。
// 実利用前に freepascal.org / tree-sitter 側ドキュメントで要検証（CLAUDE.md ルール1）。
//
// tree-sitter本体・tree-sitter-pascal文法はソースをvendor/配下にvendoringし、
// build/*.o としてCコンパイル済みのものを{$L}で静的リンクする（CLAUDE.mdルール2:
// バージョン固定方針）。build/*.o は `make`（またはビルドスクリプト）で
// vendor/ 配下のCソースから事前生成すること。
//
// {$linklib c} は必須: -k経由で手動に-lcを渡すとFPCがダイナミックリンカの
// パスを誤検出し(このUbuntu環境では存在しない/lib/ld64.so.1になる)実行不能な
// バイナリが生成される。{$linklib c}でFPC自身にlibcリンクを解決させることで
// 正しいインタプリタパス(/lib64/ld-linux-x86-64.so.2等)が設定される。
{$linklib c}
{$L ../build/tree-sitter.o}
{$L ../build/tree-sitter-pascal.o}

interface

type
  TSParser = Pointer;
  PTSTree = Pointer;
  TSLanguage = Pointer;

  TSNode = record
    Context: array[0..3] of LongWord;
    Id: Pointer;
    Tree: PTSTree;
  end;

function ts_parser_new: TSParser; cdecl; external;
procedure ts_parser_delete(parser: TSParser); cdecl; external;
function ts_parser_set_language(parser: TSParser; language: TSLanguage): Boolean; cdecl; external;
function ts_parser_parse_string(parser: TSParser; old_tree: PTSTree; const source: PAnsiChar; length: LongWord): PTSTree; cdecl; external;
function ts_tree_root_node(tree: PTSTree): TSNode; cdecl; external;
procedure ts_tree_delete(tree: PTSTree); cdecl; external;
function ts_node_string(node: TSNode): PAnsiChar; cdecl; external;

function tree_sitter_pascal: TSLanguage; cdecl; external name 'tree_sitter_pascal';

implementation

end.
