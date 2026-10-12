; RAWPACO-SEC-001(SQL 文字列連結)を tree-sitter クエリだけで近似する試作。
; build/ts_query で使う。HANDOFF.md「外部ツールとの比較・統合検討」参照。
;
; 構造(文字列リテラル + 識別子 の連結、左右どちら向きも)は表現できるが、
; 「リテラルが SQL キーワードを含む」という条件は #match? 述語が要る。
; tools/ts_query.c は述語を評価しないので、この版は SEC-001 の positive
; サンプル('Hello, ' + UserName)にも一致する。それが既知の差分。
(exprBinary lhs: (literalString) operator: (kAdd) rhs: (identifier)) @hit
(exprBinary lhs: (identifier) operator: (kAdd) rhs: (literalString)) @hit
