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

.PHONY: all clean

all: src/rawpaco

$(BUILD):
	mkdir -p $(BUILD)

$(TS_OBJ): $(VENDOR_TS)/src/lib.c | $(BUILD)
	$(CC) -c $< -I $(VENDOR_TS)/include -I $(VENDOR_TS)/src -o $@

$(TSP_OBJ): $(VENDOR_TSP)/src/parser.c | $(BUILD)
	$(CC) -c $< -I $(VENDOR_TSP)/src -I $(VENDOR_TS)/include -o $@

# TSBindings.pasの{$L ../build/*.o}がこの2ファイルを直接参照するため、
# fpc呼び出し自体はオブジェクト経路を意識しない単純な形のままにできる。
src/rawpaco: src/rawpaco.lpr src/TSBindings.pas $(TS_OBJ) $(TSP_OBJ)
	$(FPC) src/rawpaco.lpr

clean:
	rm -rf $(BUILD)
	rm -f src/rawpaco src/*.o src/*.ppu
