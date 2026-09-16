@tool
extends RefCounted
## Shape that breaks between parses: every function's LAST body line is a comment, so tree-sitter
## ends the function at the statement above it. Typing a real statement underneath extends the
## function, but func_lines only learns about it on the next full parse.
##
## The suite edits the BUFFER (parser.code_edit.text), never this file - keep the trailing comment
## bodies intact or live_edit_lines_test loses its repro.

@warning_ignore_start("unused_variable", "unused_private_class_variable")

## Root member, so the suite can seed the resolve cache and prove a sync leaves it alone.
var label := "x"

class Inner:
	var thing := 0

	func inner_do() -> void:
		var a := 0
		#var b = 0

func _click() -> void:
	var count := 0
	#var old = 0
