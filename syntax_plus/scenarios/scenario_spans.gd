@tool
extends RefCounted
## Span shapes the highlighter has to project: two-level nesting, a same-level sibling class,
## functions with and without arguments, and trailing blank/comment lines - where the two parse
## paths legitimately disagree about a function's end line (see line_data_test.gd).

@warning_ignore_start("unused_variable", "unused_private_class_variable", "unused_parameter")

var root_member := 0


class Outer:
	var outer_member := 0

	class Inner:
		var inner_member := 0

		func inner_with_args(a: int, b: String) -> void:
			var local := a


	func outer_no_args() -> void:
		var local := 0


class Sibling:
	var sibling_member := 0

	func sibling_func(flag: bool) -> void:
		var local := flag


func root_func(value: int) -> void:
	var local := value


## Last body line is a comment. Measured on 4.6.3: plain text 38..41 (to the dedent), tree-sitter
## 38..40 (the body node). Both are correct for their path.
func root_trailing_comment() -> void:
	var local := 0
	#var commented_out := 1
