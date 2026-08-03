# vendor/配下のtree-sitter本体・tree-sitter-pascal文法をCコンパイルし、
# その後FPCでrawpaco本体をビルドする。
#
# tree-sitter-pascalに外部スキャナ(scanner.c)は存在しない(v0.10.2時点)ため、
# コンパイル対象はparser.cのみでよい。追加された場合はここにも追記が必要。

CC ?= gcc
FPC ?= fpc

VENDOR_TS := vendor/tree-sitter
VENDOR_TSP := vendor/tree-sitter-pascal
BUILD := build

TS_OBJ := $(BUILD)/tree-sitter.o
TSP_OBJ := $(BUILD)/tree-sitter-pascal.o

RULE_SOURCES := src/Diagnostics.pas src/RuleRegistry.pas src/ASTWalker.pas \
                src/LintDriver.pas src/Rules/RuleDefense001.pas src/Rules/AllRules.pas

.PHONY: all clean test

all: src/rawpaco

$(BUILD):
	mkdir -p $(BUILD)

$(TS_OBJ): $(VENDOR_TS)/src/lib.c | $(BUILD)
	$(CC) -c $< -I $(VENDOR_TS)/include -I $(VENDOR_TS)/src -o $@

$(TSP_OBJ): $(VENDOR_TSP)/src/parser.c | $(BUILD)
	$(CC) -c $< -I $(VENDOR_TSP)/src -I $(VENDOR_TS)/include -o $@

# TSBindings.pasの{$L ../build/*.o}がこの2ファイルを直接参照するため、
# fpc呼び出し自体はオブジェクト経路を意識しない単純な形のままにできる。
# -Fusrc/Rules は src/Rules/ 配下のユニット(AllRules等)をFPCが見つける
# ためのユニット検索パス追加(rawpaco.lprと同じsrc/直下のユニットは
# このフラグなしでも見つかる)。
src/rawpaco: src/rawpaco.lpr src/TSBindings.pas $(RULE_SOURCES) $(TS_OBJ) $(TSP_OBJ)
	$(FPC) -Fusrc/Rules src/rawpaco.lpr

test: src/rawpaco
	bash tests/run_tests.sh

clean:
	rm -rf $(BUILD)
	rm -f src/rawpaco src/*.o src/*.ppu src/Rules/*.o src/Rules/*.ppu
