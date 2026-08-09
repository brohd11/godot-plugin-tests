extends SceneTree
## Clean-compile headless entry for the syntax_plus suites, exiting with a CI code.
##     godot --headless --path . --script res://tests/syntax_plus/run_headless.gd
##
## Only the parser-facing helpers are covered here. The highlighter itself is an
## EditorSyntaxHighlighter driven per rendered line by a live script editor, so its colouring is
## checked by hand in the editor.

const SUITES:PackedStringArray = [
	"res://tests/syntax_plus/line_data_test.gd",
]

func _init() -> void:
	var success = true
	var output:Array[String] = []

	for path in SUITES:
		var res:Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)

	print("\n".join(output))
	quit(0 if success else 1)
