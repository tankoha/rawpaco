/* mingw-w64 (UCRT) では plain な `atexit` シンボルをどのインポートライブラリも
   公開していない。UCRT環境の atexit は <stdlib.h> のインライン定義としてのみ
   提供され、実体は `_crt_atexit` である。vendor の C ソースを gcc -c で直接
   コンパイルしている本プロジェクトでは、mingw のランタイムライブラリ内部から
   参照される `atexit` が原理的に解決できないため、転送用のシムを自前で用意する。
   詳細な調査経緯は HANDOFF.md を参照。 */

extern int _crt_atexit(void (*func)(void));

int atexit(void (*func)(void))
{
  return _crt_atexit(func);
}
