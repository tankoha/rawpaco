unit TSBindings;

{$mode objfpc}{$H+}

// tree-sitter 本体はCライブラリのため、ABI互換のためcdeclで宣言する。
// 型・関数シグネチャは tree-sitter 公式ヘッダ(api.h)未照合のブートストラップ版。
// 実利用前に freepascal.org / tree-sitter 側ドキュメントで要検証（CLAUDE.md ルール1）。

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

function ts_parser_new: TSParser; cdecl; external 'tree-sitter';
procedure ts_parser_delete(parser: TSParser); cdecl; external 'tree-sitter';
function ts_parser_set_language(parser: TSParser; language: TSLanguage): Boolean; cdecl; external 'tree-sitter';
function ts_parser_parse_string(parser: TSParser; old_tree: PTSTree; const source: PAnsiChar; length: LongWord): PTSTree; cdecl; external 'tree-sitter';
function ts_tree_root_node(tree: PTSTree): TSNode; cdecl; external 'tree-sitter';
procedure ts_tree_delete(tree: PTSTree); cdecl; external 'tree-sitter';
function ts_node_string(node: TSNode): PAnsiChar; cdecl; external 'tree-sitter';

implementation

end.
