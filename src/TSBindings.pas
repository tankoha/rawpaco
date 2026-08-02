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
// {$linklib c} はLinuxでのみ必須: -k経由で手動に-lcを渡すとFPCがダイナミック
// リンカのパスを誤検出し(このUbuntu環境では存在しない/lib/ld64.so.1になる)
// 実行不能なバイナリが生成される。{$linklib c}でFPC自身にlibcリンクを解決
// させることで正しいインタプリタパス(/lib64/ld-linux-x86-64.so.2等)が設定
// される。Windowsには対応する'c'という名のインポートライブラリが存在せず
// 「Import library not found for c」でリンクエラーになるため対象外とする。
{$IFDEF LINUX}
{$linklib c}
{$ENDIF}
// Windows(mingw)側でも同様の理由でCランタイムのリンクが必要。ただしFPC自身の
// リンカ(ld.exe)はgccと違いlibgcc/libmingwex/libmingw32/CRT/kernel32を暗黙に
// 追加しないため、vendorのCソースが使うmalloc/memcpy/QueryPerformanceCounter
// 等のシンボルが「Undefined symbol」になる。個別に列挙してリンクする
// （CI(.github/workflows/ci.yml)側でmingwの実際のインストール場所から
// 各.aファイルの検索パスを動的取得し-Flで渡している）。choco経由でpin
// しているmingw(niXman mingw-builds 16.1.0)はucrtランタイムなので
// crtは`ucrt`を指定する。
//
// mingwex/mingw32/gcc/ucrt/kernel32を一通り並べてもatexitだけが
// Undefined symbolとして残った。mingwex/mingw32/gccをucrt/kernel32の後に
// もう一度並べる2周目の走査（循環参照対策の古典的回避策）も試したが
// 変化がなく、そもそもこの5つのいずれにもatexitが存在しないと判明。
// pinしているmingw(niXman mingw-builds 16.1.0)は"posix"スレッディング
// モデルのビルドであり、posixスレッディング版mingw-w64はatexitの
// スレッドセーフな登録処理をlibwinpthreadに依存することが多いため、
// これを追加する。
{$IFDEF MSWINDOWS}
{$linklib mingwex}
{$linklib mingw32}
{$linklib gcc}
{$linklib ucrt}
{$linklib kernel32}
{$linklib winpthread}
{$linklib mingwex}
{$linklib mingw32}
{$linklib gcc}
{$ENDIF}
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
