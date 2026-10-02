/*
 * ts_probe: vendoring済み tree-sitter-pascal で1ファイルを構文解析し、
 * ERROR/MISSING ノードの位置と、必要なら木全体の S 式を出力する。
 *
 * なぜ別ツールなのか: rawpaco 本体は lint 結果しか出さず、文法が受け付けない
 * 構文を「どのノードが ERROR になるか」の粒度で確かめる手段が無かった。
 * HANDOFF.md の「文法カバレッジの既知の穴」は従来その場限りのプローブで
 * 調べていたので、再現可能な形で残す。FPC 不要(gcc のみ)で動くのは、
 * 文法の確認が本体ビルドに依存しないほうが CI 環境の都合に左右されないため。
 *
 * ビルド: make probe   (build/ts_probe)
 * 使い方: build/ts_probe [-s] <file.pas>
 *   -s  ERROR 一覧に加えて木全体の S 式(ts_node_string)も出力する
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_pascal(void);

static void print_errors(TSNode node, const char *src, int *count) {
  if (ts_node_is_error(node) || ts_node_is_missing(node)) {
    TSPoint s = ts_node_start_point(node);
    TSPoint e = ts_node_end_point(node);
    uint32_t sb = ts_node_start_byte(node), eb = ts_node_end_byte(node);
    uint32_t len = eb - sb;
    if (len > 60) len = 60;
    printf("  %s %u:%u-%u:%u  %s\n",
           ts_node_is_missing(node) ? "MISSING" : "ERROR",
           s.row + 1, s.column + 1, e.row + 1, e.column + 1,
           ts_node_is_missing(node) ? ts_node_type(node) : "");
    if (!ts_node_is_missing(node)) {
      printf("    text: %.*s%s\n", (int)len, src + sb, (eb - sb) > 60 ? "..." : "");
      /* ERROR ノード直下の子種別を列挙する。HANDOFF.md の `raise;` の例の
         ように「ERROR の中に kRaise が残る」といった形を見るため。 */
      uint32_t n = ts_node_child_count(node);
      printf("    children:");
      for (uint32_t i = 0; i < n; i++)
        printf(" %s", ts_node_type(ts_node_child(node, i)));
      printf("\n");
    }
    (*count)++;
    /* ERROR 配下の更なる ERROR は同じ原因の派生なので数えない */
    return;
  }
  uint32_t n = ts_node_child_count(node);
  for (uint32_t i = 0; i < n; i++) print_errors(ts_node_child(node, i), src, count);
}

int main(int argc, char **argv) {
  int sexp = 0;
  const char *path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-s") == 0) sexp = 1; else path = argv[i];
  }
  if (!path) { fprintf(stderr, "usage: ts_probe [-s] <file.pas>\n"); return 2; }

  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); return 2; }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *src = malloc(size + 1);
  if (fread(src, 1, size, f) != (size_t)size) { perror("fread"); return 2; }
  src[size] = 0;
  fclose(f);

  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, tree_sitter_pascal());
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, (uint32_t)size);
  TSNode root = ts_tree_root_node(tree);

  int has_error = ts_node_has_error(root);
  printf("%s: has_error=%s\n", path, has_error ? "true" : "false");
  int count = 0;
  print_errors(root, src, &count);
  printf("  error_nodes=%d\n", count);
  if (sexp) {
    char *s = ts_node_string(root);
    printf("%s\n", s);
    free(s);
  }

  ts_tree_delete(tree);
  ts_parser_delete(parser);
  free(src);
  return has_error ? 1 : 0;
}
