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
                src/ASTHelpers.pas src/CompilerDirectives.pas \
                src/FPCSymbols.pas src/RawpacoConfig.pas src/LintDriver.pas \
                src/Rules/RuleDefense001.pas \
                src/Rules/RuleSec001.pas src/Rules/RuleSec002.pas \
                src/Rules/RuleDepr001.pas src/Rules/RuleDepr002.pas \
                src/Rules/RuleHalluc001.pas src/Rules/RuleStyle001.pas \
                src/Rules/RuleDefense002.pas src/Rules/RuleStyle002.pas \
                src/Rules/RuleMode001.pas src/Rules/RuleMode002.pas \
                src/Rules/RuleMem001.pas \
                src/Rules/AllRules.pas

.PHONY: all clean test selflint probe

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

# 文法プローブ(tools/ts_probe.c)。FPC 不要で、tree-sitter-pascal が受け付けない
# 構文を ERROR ノードの粒度で確かめる。tests/probes/ 配下のサンプルに対して
# `build/ts_probe [-s] <file.pas>` で使う。CI には組み込まない(lint 結果の
# 検証ではなく、文法カバレッジ調査用のため)。
probe: $(BUILD)/ts_probe

$(BUILD)/ts_probe: tools/ts_probe.c $(TS_OBJ) $(TSP_OBJ)
	$(CC) $< $(TS_OBJ) $(TSP_OBJ) -I $(VENDOR_TS)/include -o $@

# CLAUDE.mdルール4: 本ツール自身のソースをlintし警告ゼロを維持する。
# --fail-on=warningが必須(設計書4.1.4節): 重要度別終了コード制御の既定は
# 寛容(error階層のみが既定でビルドを落とす)になったが、自己lintは
# 従来どおりの無妥協な方針(診断1件でも失敗)を維持する必要があるため、
# 既定に頼らず明示的に激辛モードを指定する。これを忘れると9ルール中
# 5ルール(Warning階層)がこのゲートを静かに素通りするようになる。
selflint: src/rawpaco
	./src/rawpaco --fail-on=warning src/*.pas src/Rules/*.pas src/rawpaco.lpr

clean:
	rm -rf $(BUILD)
	rm -f src/rawpaco src/*.o src/*.ppu src/Rules/*.o src/Rules/*.ppu
