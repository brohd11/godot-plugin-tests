extends SceneTree
## Headless (full, including frame-dependent prompt completion): python3 tests/editor_console/run_headless.py
## Editor console: `test editor_console` runs the frame-free checks.
const Suite = preload("res://tests/editor_console/runtime_suite.gd")


func _initialize():
	_run.call_deferred()


func _run():
	var suite = Suite.new()
	suite.run_sync()
	await suite.run_frames()
	print("\n".join(suite.finish()))
	quit(1 if suite.failures else 0)


## Editor console entry. GDSh commands cannot await, so frame-dependent checks only run headless.
static func run_tests() -> Dictionary:
	var suite = Suite.new()
	suite.run_sync()
	suite.report.append("(skipped frame-dependent prompt completion; run tests/editor_console/run_headless.py)")
	return {"result": suite.failures, "output": suite.finish()}
