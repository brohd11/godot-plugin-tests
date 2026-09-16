extends RefCounted
# Fixture for nameless_enum_lambda_test.gd - line numbers are asserted, append only.

enum { A, B = 3, C }
enum {
	NEG = -3, # comment, with a comma
	NEXT,
	BITS = 1 << 4,
	AFTER,
}
enum Named { HIDDEN, OTHER = 5 }
const ORDINARY: int = 42

var typed_lambda = func(a: int, b := 2.0) -> String:
	var inside := a + b
	return str(inside)

var one_liner = func(x): return x


func real(a: int, b := 2.0) -> String:
	return str(a + b)


func with_locals() -> void:
	var before := 1
	var local_lambda = func(n: int) -> int:
		var nested_local := n * 2
		return nested_local
	var after = local_lambda.call(before)
	print(after)


class Inner:
	enum { INNER_A, INNER_B }
	var inner_lambda = func(): return INNER_A + A
