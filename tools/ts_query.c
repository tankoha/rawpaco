/*
 * ts_query: tree-sitter のクエリ(S 式パターン)を Pascal ファイルに当て、
 * `@hit` という名前のキャプチャに一致したノードの位置とテキストを出力する。
 *
 * なぜあるのか: 「ルールを Pascal コードではなくデータとして書く」方式が
 * rawpaco で成り立つかを確かめる試作(2026-10、HANDOFF.md「外部ツールとの
 * 比較・統合検討」参照)。Opengrep を改造して Pascal 対応させる案と比べ、
 * vendoring 済みの tree-sitter ランタイムに既に入っているクエリ機能
 * (api.h の ts_query_new / ts_query_cursor_exec / ts_query_cursor_next_match)
 * だけで済むため、新しい依存が増えない。
 *
 * 既知の制約(試作のまま残している理由でもある):
 *   - `#match?` や `#eq?` のようなテキスト述語は C ランタイムが評価しない
 *     (api.h の ts_query_predicates_for_pattern で取り出して呼び出し側が
 *     実装する設計)。本ツールは未実装なので、述語を書いても無視される。
 *     そのため tests/probes/queries/sec001_approx.scm は SQL キーワードの
 *     有無を判定できず、RAWPACO-SEC-001 の positive サンプルにも一致する。
 *   - 本体に取り込む場合は FPC 側から同じ API を cdecl で呼び、述語を
 *     Pascal で実装する想定。このツールはその前段の実験用。
 *
 * ビルド: make probe   (build/ts_query)
 * 使い方: build/ts_query <query.scm> <file.pas> [<file.pas> ...]
 * 終了コード: 0=正常(一致の有無を問わない) / 2=引数・入力・クエリのエラー
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_pascal(void);

static char *slurp(const char *path, long *size) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); return NULL; }
  fseek(f, 0, SEEK_END);
  *size = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc(*size + 1);
  if (fread(buf, 1, *size, f) != (size_t)*size) { perror(path); fclose(f); free(buf); return NULL; }
  buf[*size] = 0;
  fclose(f);
  return buf;
}

static const char *query_error_name(TSQueryError e) {
  switch (e) {
    case TSQueryErrorSyntax: return "syntax";
    case TSQueryErrorNodeType: return "unknown node type";
    case TSQueryErrorField: return "unknown field";
    case TSQueryErrorCapture: return "capture";
    case TSQueryErrorStructure: return "structure";
    case TSQueryErrorLanguage: return "language";
    default: return "unknown";
  }
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: ts_query <query.scm> <file.pas> ...\n"); return 2; }

  long qsize;
  char *qsrc = slurp(argv[1], &qsize);
  if (!qsrc) return 2;

  uint32_t err_offset;
  TSQueryError err_type;
  TSQuery *query = ts_query_new(tree_sitter_pascal(), qsrc, (uint32_t)qsize, &err_offset, &err_type);
  if (!query) {
    fprintf(stderr, "%s: query error (%s) at byte %u\n", argv[1], query_error_name(err_type), err_offset);
    return 2;
  }

  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, tree_sitter_pascal());
  TSQueryCursor *cursor = ts_query_cursor_new();
  int rc = 0, total = 0;

  for (int i = 2; i < argc; i++) {
    long ssize;
    char *src = slurp(argv[i], &ssize);
    if (!src) { rc = 2; continue; }
    TSTree *tree = ts_parser_parse_string(parser, NULL, src, (uint32_t)ssize);
    ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree));

    TSQueryMatch m;
    while (ts_query_cursor_next_match(cursor, &m)) {
      for (uint16_t c = 0; c < m.capture_count; c++) {
        uint32_t len;
        const char *name = ts_query_capture_name_for_id(query, m.captures[c].index, &len);
        /* `@hit` 以外のキャプチャは、将来の述語(#match? 等)の引数として
           部分ノードに名前を付ける用途を想定して出力しない */
        if (len != 3 || strncmp(name, "hit", 3) != 0) continue;
        TSNode n = m.captures[c].node;
        TSPoint p = ts_node_start_point(n);
        uint32_t a = ts_node_start_byte(n), b = ts_node_end_byte(n);
        printf("%s:%u:%u: %.*s\n", argv[i], p.row + 1, p.column + 1, (int)(b - a), src + a);
        total++;
      }
    }
    ts_tree_delete(tree);
    free(src);
  }

  printf("matches=%d\n", total);
  ts_query_cursor_delete(cursor);
  ts_parser_delete(parser);
  ts_query_delete(query);
  free(qsrc);
  return rc;
}
