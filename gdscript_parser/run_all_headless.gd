extends SceneTree
## Clean-compile headless entry that runs ALL 14 gdscript-parser suites and exits with a CI code.
##     Godot --headless --path . --script res://tests/gdscript_parser/run_all_headless.gd
##
## Delegates to the shared aggregator (run_all_tests.gd) so the suite list lives in one place; that
## EditorScript's `static` funcs load and run fine under bare --headless (verified).

## Runs from _initialize(), NOT _init(): during _init() the main loop is not registered yet, so
## Engine.get_main_loop() is null and GDScriptLSPService.get_instance() cannot attach - every
## native-mode suite would silently skip. Deferring lets the tree finish coming up first.
func _initialize() -> void:
	_run_suites.call_deferred()


func _run_suites() -> void:
	var res: Dictionary = load("res://tests/gdscript_parser/run_all_tests.gd").run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)
