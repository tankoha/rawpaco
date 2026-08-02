# HANDOFF.md

このファイルはセッション間の引き継ぎ用です。決着した論点は都度削除し、git historyに委ねてください（詳細な運用ルールはCLAUDE.mdを参照）。

## 実装済みルール一覧

| ID | 内容 | 状態 | 備考 |
|---|---|---|---|
| (未着手) | | | |

## 見送ったルール（検討済み・意図的に未実装）

- (該当なし)

## tree-sitter-pascal 文法カバレッジの既知の穴

- (未検証。着手後、パース失敗・誤認識した構文とサンプルコードをここに追記)

## 自己lint到達状況

- 本ツール自身のソースへの自己適用: 未実施
- 鶏卵問題の解消範囲: N/A（lintルールが1つも存在しないため、CIへの自己lintステップ追加は次回以降に見送り。CLAUDE.mdルール4は最初のルール実装後に着手）

## tree-sitter本体・tree-sitter-pascalのvendoring方針（確定）

- 方式: OS提供の共有ライブラリ（apt/choco等）には依存せず、ソースをリポジトリにvendoringしCコンパイラで静的リンクする。CLAUDE.mdルール2（バージョン固定）にも合致。
- `vendor/tree-sitter/`: tree-sitter本体ランタイムを `v0.24.7` で固定。`lib/src/lib.c`（単一ファイル版アマルガメーション）と `lib/include/tree_sitter/api.h` を取り込み済み。ABIバージョンは14（`TREE_SITTER_LANGUAGE_VERSION`）。
- `vendor/tree-sitter-pascal/`: `v0.10.2` で固定。生成済み `src/parser.c` を取り込み済み（外部スキャナ(scanner.c)なし）。生成時ABIも14で一致（`LANGUAGE_VERSION 14`）。tree-sitter本体はABI13〜14を互換サポートしており組み合わせ上の問題なし。
- ビルド: リポジトリルートの `Makefile` が `vendor/*/src/*.c` を `gcc` でコンパイルし `build/*.o` を生成、`src/TSBindings.pas` の `{$L ../build/tree-sitter.o}` 等で静的リンクする。`make` 一発で `src/rawpaco` まで生成される。
- 既知の落とし穴: `-k` 経由で手動に `-lc` を渡すとFPCがダイナミックリンカのパスを誤検出し（このUbuntu環境では存在しない `/lib/ld64.so.1` になる）実行不能バイナリが生成される。`{$linklib c}` ディレクティブでFPC自身にlibcリンクを解決させることで回避（`TSBindings.pas` にコメントあり）。
- Windows CI初回実行（2026-08-02, run 30759838476）: `build-linux` は成功。`build-windows` は `fpc: command not found` で失敗。原因はchocoインストールによるマシンPATH（レジストリ）更新が、GitHub Actionsの同一ジョブ内後続ステップ（別プロセスとして起動）に反映されないため。gccが動いていたのは、mingwインストールが効いたのではなく、Windowsランナーに元々含まれる別経路のgcc（Strawberry Perl等）がPATHにあったためと推測。対策として、chocoインストール直後に `fpc.exe` / `gcc.exe` の実際の設置場所を検索し `$GITHUB_PATH` に明示追記した。
- Windows CI 2回目実行（run 30760907748）: `fpc` は見つかるようになったが今度は `Illegal COFF Magic`（32bit/64bitのオブジェクト形式不一致）と `Import library not found for c` で失敗。`{$linklib c}` はLinux固有の対処（ld64.so.1問題の回避）であり、Windowsには対応する`c`という名のインポートライブラリが存在せずエラーになるため `{$IFDEF LINUX}` で囲みLinux限定にした（`TSBindings.pas`。これは3回目実行でも解消を確認）。
- Windows CI 3回目実行（run 30761222949）: `Illegal COFF Magic` 対策として `-Px86_64 -Twin64` を試したが `ppcx64.exe can't be executed`（error code 2 = ファイルが存在しない）で失敗。chocoの `freepascal` パッケージのインストールスクリプト(`ChocolateyInstall.ps1`)を直接取得して確認したところ、64bit OS向けに `fpc-3.2.2.win32.and.win64.exe`（win64コンポーネント追加インストーラ）を実行してはいるが、共有の `setup.inf`（`Components=base,binutils,docs,ide,utils,make,demo,gdb,units,examples`）はこのインストーラのコンポーネントID体系と一致しておらず、実際には `ppcx64.exe` が配置されないと判明。
- 対策1（64bit側を諦め32bitに統一する方針）: `ppc386.exe`にgcc側を合わせる。`choco install` 前に `$env:ChocolateyForceX86 = 'true'` を設定して試みたが、Windows CI 4回目実行（run 30761437586）で確認したところ効果がなく、mingwパッケージは相変わらずx86_64ビルドをダウンロードしていた（ログで確認）ため、依然`Illegal COFF Magic`で失敗。
- 対策2: Chocolatey公式ドキュメントを確認したところ、32bit強制の正しい方法は環境変数ではなく `choco install ... --x86` というコマンドラインオプションだった。`--x86`に切り替えたところ、Windows CI 5回目実行（run 30761651380）で `Illegal COFF Magic` は解消し32bit同士でリンクできるようになった。
- Windows CI 5回目実行の残課題: 今度は `malloc`/`memcpy`/`QueryPerformanceCounter`/`___mingw_vsnprintf`/`___udivdi3` 等28個の `Undefined symbol` でリンク失敗。原因はFPC自身のリンカ(ld.exe)がgccと違いlibgcc/libmingwex/libmingw32/CRT(ucrt)/kernel32を暗黙にリンクしないため。対策として、CI側でchocoのmingwインストール先から該当する`.a`ファイル(libmingwex.a, libmingw32.a, libgcc.a, libkernel32.a, libucrt.a等)の実際の設置ディレクトリを動的検索し`-Fl`でFPCに渡すようにし、`TSBindings.pas`側に`{$IFDEF MSWINDOWS}`で`{$linklib mingwex/mingw32/gcc/ucrt/kernel32}`を追加した。pinしているmingw(niXman mingw-builds 16.1.0)がucrtランタイムなので`ucrt`を指定（`msvcrt`ではない）。
- 32bit方針の再検討: 「32bit強制がChocolatey環境変数ではなくCLIオプションだった」という経緯を踏まえ、64bit側で同様の見落としがないか再確認した（ユーザー指摘）。SourceForgeの配布物一覧を調べたところ、chocoが使う共有setup.infに依存しない単機能のwin64クロスコンパイラ追加インストーラ `fpc-3.2.2.i386-win32.cross.x86_64-win64.exe` が別途配布されていると判明。これを直接ダウンロードし`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /DIR=C:\tools\freepascal`でサイレントインストールする方式に変更し、mingw側も32bit強制(`--x86`)をやめてネイティブのx86_64ビルドに戻した。fpc呼び出しは`-Px86_64 -Twin64`。
- Windows CI 6回目実行（run 30761956791）: `Invoke-WebRequest` でのダウンロードが実行可能ファイルとして壊れており（SourceForgeのミラー選択リダイレクトを正しく辿れなかったと推測）、`Start-Process`が「corrupted and unreadable」で失敗。ダウンロード手段を`curl.exe`（Windowsランナー標準搭載）に切替え。
- Windows CI 7回目実行（run 30762105705）: `curl.exe`でのダウンロード自体は成功したが、サイレントインストール後も`ppcx64.exe`が見つからず失敗。Windows実機がなくInno Setupのサイレントインストール引数（`/DIR=`の形式や必要な`/COMPONENTS=`指定など）を検証できず、これ以上64bit側を追うのはCI往復での試行錯誤になり非効率と判断。ユーザーと相談の上、64bit方針は断念し32bitに戻すことで合意（`choco install -y freepascal mingw --x86`、fpc呼び出しはプレーンな`fpc src/rawpaco.lpr`に戻す）。5回目実行で32bit同士のアーキテクチャ一致は既に確認済みなので、残るは5回目で判明したUndefined symbol対策（mingwランタイムライブラリの動的検索+linklib、既に実装済み・bitness非依存）のみのはず。
- Windows CI 8回目実行（run 30762263102）: mingwランタイムライブラリの動的検索+linklib対策により28個あったUndefined symbolはほぼ解消したが、`atexit`だけが未解決で残った。原因はlibmingw32/libmingwex/libgccが互いに依存し合う循環参照（mingw-w64で既知の構造）で、`{$linklib}`を並べる素朴な方式ではGNU ldが1回の左→右走査で解決しきれないため。
- Windows CI 9回目実行（run 30762403167）: 対策として`{$linklib}`ディレクティブをやめ、CI側のfpc呼び出しで`-k"--start-group" -lmingwex -lmingw32 -lgcc -lucrt -lkernel32 -k"--end-group"`という生ld引数として渡す方式を試したが、28個のUndefined symbolが全て復活（8回目より悪化）。`-k`経由での`--start-group`/`--end-group`受け渡しが機能していないと判明（fpcの`-k`オプションでの二重ダッシュ引数の扱いに問題がある可能性。原因未特定）。対策として`-k`方式は撤回し、8回目で27/28まで解決していた`{$linklib}`方式に戻した上で、循環依存のあるmingwex/mingw32/gccをucrt/kernel32の後にもう一度並べる（`--start-group`が登場する以前からの古典的な2周回避策）よう変更。
- Windows CI 10回目実行（run 30763225203）: 2周回避策でも`atexit`だけは変化なく未解決のまま。つまりmingwex/mingw32/gcc/ucrt/kernel32のいずれにもatexitは存在しないと判明。pinしているmingw(niXman mingw-builds 16.1.0)は"posix"スレッディングモデルのビルド（ダウンロードURLに`-posix-`と明記）であり、posixスレッディング版mingw-w64はatexitのスレッドセーフな登録処理をlibwinpthreadに依存することが多いという仮説のもと、`libwinpthread.a`を検索対象に追加し`{$linklib winpthread}`を足した。
- Windows CI 11回目実行（run 30763379093）: `libwinpthread`追加でも`atexit`は変化なし。推測での対処が限界に達したため、CI上に一時的な診断ステップ（`nm`で全`.a`ファイルを直接調べる）を追加して実機で確認する方針に切替え。
- 診断結果（run 30763650485、詳細ログは会話内に記録）: pinしているmingw-w64全体（mingwex/mingw32/gcc/ucrt/kernel32/winpthread/msvcrt系/crtdll等、opt配下含め探索した全`.a`）を`nm`で走査したが、プレーンな`atexit`という名の定義済みシンボルはどこにも存在しなかった。関連シンボルとして`__crt_atexit`（`libmsvcrt.a`等に`T`=定義済みで実在）、`___cxa_atexit`、`__register_thread_local_exe_atexit_callback`は見つかった。これはUCRT環境の既知の仕様で、`atexit()`は`<stdlib.h>`のインライン展開でのみ提供され実体は`_crt_atexit`であり、ヘッダ経由を通らない形でコンパイルされたコード（vendorのCソースをgcc -cで直接コンパイルしている今回のケース）ではプレーンな`atexit`シンボル自体がどのライブラリにも存在しないため原理的に解決不可能と判明。
- 対策（第1版）: `src/win32_atexit_shim.c`を新設し、`atexit`から`_crt_atexit`へ転送する薄いラッパーを自前で提供する（`extern int _crt_atexit(void (*)(void));`を呼ぶだけ）。CI側で`gcc -c src/win32_atexit_shim.c -o build/win32_atexit_shim.o`としてコンパイルし、`TSBindings.pas`の`{$IFDEF MSWINDOWS}`ブロックに`{$L ../build/win32_atexit_shim.o}`を追加してリンクする。診断用の一時ステップ（`Diagnose atexit symbol location`）は原因判明のため削除済み。
- Windows CI 12回目実行（run 30764064796）: 上記のCシム自体はコンパイル成功したが、`{$L}`で埋め込んだ途端に`ppc386.exe`自体が`Compilation raised exception internally / EAccessViolation`でクラッシュした。原因はおそらく極小オブジェクトファイル（1関数のみ）に対するFPC側のCOFFリーダーのエッジケースバグ（{$L}はFPC自身がオブジェクトを事前解析するため）。ユーザー提案で「ローカルクロスコンパイルした成果物をコミット」も検討したが、ビルド成果物を非gitignore対象にする案はCLAUDE.mdのバージョン固定・再現可能ビルド方針（ソースから再現できることが前提）に反するため不採用。
- 対策（第2版）: C側の実装と`{$L}`埋め込みを完全にやめ、`src/win32_atexit_shim.c`は削除。代わりに`TSBindings.pas`のimplementation部で、Pascal側から`_crt_atexit`へ転送する関数を書き`cdecl; public name 'atexit';`でエクスポートする方式に変更（`WindowsAtExitShim`関数）。FPC自身のCOFFリーダーを経由する外部オブジェクトファイルが一切不要になり、クラッシュ要因は解消。
- Windows CI 13回目実行（run 30764301814）: クラッシュは解消したが、まだ`Undefined symbol: _atexit`が残った（1個のみ、クラッシュなし）。原因は`public name`が明示的な名前をそのまま使うため、win32ターゲットでcdecl関数の名前省略時のみ自動付与される先頭アンダースコアの恩恵を受けなかったこと。エクスポート名を`public name 'atexit'`から`public name '_atexit'`へ変更（アンダースコアを明示）して解決を試みる。未検証・要フォローアップ。

## 直近セッションのメモ

- FPC開発環境をローカルに導入済み（Ubuntu 24.04、apt経由: fpc 3.2.2+dfsg-32, fpc-source, lazarus 3.0）。
- tree-sitter本体・tree-sitter-pascalのvendoring、Makefileによるビルド、`src/rawpaco.lpr` からのtree-sitter-pascal経由パース（自己チェック用の最小プログラム）まで動作確認済み（Linux）。詳細は上記セクション参照。
- `.github/workflows/ci.yml` を追加（Linux/Windowsの2ジョブ）。LinuxはCI相当のローカル手順（apt install fpc → make → 実行）を確認済み。Windows側は未検証（上記参照）。
- 次のステップ: Windows CIジョブの実機検証、実際のlintルール第1号の実装（positive/negativeサンプル込み、CLAUDE.mdルール3）、ルール実装後に自己lintのCI組み込み（ルール4）。

## 関連プロジェクト（参考・棚卸し対象外）

- CodeTools方式によるFPC/Lazarus向け静的解析ツールは別リポジトリで構想のみ管理（GPL-3.0-or-later予定、実装未着手）。詳細は当該リポジトリのREADME参照。本HANDOFF.mdでは追跡しない。
