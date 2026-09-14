extends SceneTree
## Headless (full, including frame-dependent console checks): python3 tests/gdsh/run_headless.py
## Editor console: `test gdsh` runs the frame-free checks.
const Suite = preload("res://tests/gdsh/runtime_suite.gd")


func _initialize():
	_run.call_deferred()


func _run():
	var suite = Suite.new()
	suite.run_sync()
	await suite.run_frames()
	print("\n".join(suite.finish()))
	quit(0 if suite.failures == 0 else 1)


## Editor console entry. GDSh commands cannot await, so frame-dependent checks only run headless.
static func run_tests() -> Dictionary:
	var suite = Suite.new()
	suite.run_sync()
	suite.report.append("(skipped frame-dependent console checks; run tests/gdsh/run_headless.py)")
	return {"result": suite.failures, "output": suite.finish()}
