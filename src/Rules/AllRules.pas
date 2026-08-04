unit AllRules;

{$mode objfpc}{$H+}

// FPCには実行時のアセンブリスキャンやアノテーション自動収集の仕組みが
// ない。ルールユニットの`initialization`セクション(RuleRegistry.Register
// 呼び出し)は、そのユニットが実際にどこかから`uses`されて初めて実行される。
// そのため「ユニットを置くだけで自動的に有効になる」プラグイン方式は
// 実現できず、新しいルールを追加するたびに、このユニットの`uses`節へ
// 追記することが必須になる。忘れると静かに無効なまま(コンパイルは通るが
// ルールが一度も発火しない)になるので注意。

interface

uses
  RuleDefense001, RuleSec001, RuleSec002, RuleDepr001, RuleDepr002, RuleHalluc001,
  RuleStyle001, RuleDefense002, RuleStyle002;

implementation

end.
