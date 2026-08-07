extends SceneTree
## Clean-compile headless entry for the dep_graph layout suite, exiting with a CI code.
##     godot --headless --path . --script res://tests/dep_graph/run_headless.gd
##
## Only the layout is covered here - it is pure math over a DepGraph. The panel is a
## GraphEdit and needs a live editor, so it is checked with DepGraphPanel.preview_window().

const SUITES:PackedStringArray = [
	"res://tests/dep_graph/layout_test.gd",
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
