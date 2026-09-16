extends Node

const Workloads = preload("workloads.gd")
const CASES = ["allocation", "arithmetic", "script_calls", "engine_calls", "vectors", "inline_calls"]

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var iterations := int(args[0]) if not args.is_empty() else 200000
	var results := {"engine": Engine.get_version_info().string, "debug": OS.is_debug_build(),
		"editor": OS.has_feature("editor"), "iterations": iterations, "cases": {}}
	var workloads: Variant = Workloads
	for method: String in CASES:
		workloads.call(method, maxi(1, floori(iterations * 0.1)))
		var start := Time.get_ticks_usec()
		var checksum: float = workloads.call(method, iterations)
		results.cases[method] = {"usec": Time.get_ticks_usec() - start, "checksum": checksum}
	print("BENCH_RESULT " + JSON.stringify(results))
	get_tree().quit()
