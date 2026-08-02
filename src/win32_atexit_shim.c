/*
 * pinしているmingw-w64(niXman mingw-builds 16.1.0, UCRT)は、プレーンな
 * `atexit`シンボルをどのインポートライブラリにも公開していない
 * （<stdlib.h>のインライン展開経由でのみ提供され、実体は`_crt_atexit`）。
 * vendorのC objectはgcc -cで直接コンパイルしているため、libmingwex.a等の
 * 内部コードが参照するプレーンな`atexit`が未解決のままリンクに失敗する
 * (詳細はHANDOFF.md参照)。`_crt_atexit`（libmsvcrt.a等に実在することを
 * nmで確認済み）へ転送する薄いシムをここで提供する。
 */
extern int _crt_atexit(void (*func)(void));

int atexit(void (*func)(void)) {
  return _crt_atexit(func);
}
