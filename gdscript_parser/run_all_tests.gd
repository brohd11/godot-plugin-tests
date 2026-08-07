@tool
extends EditorScript
## Single entry that runs all four gdscript-parser test suites and prints one aggregate report.
##
##   - Editor "Run" (Ctrl+Shift+X) / File > Run    -> _run() below.
##   - Editor console (reusable static):
##         load("res://tests/gdscript_parser/run_all_tests.gd").run_all()   # -> String report
##         load("res://tests/gdscript_parser/run_all_tests.gd").run_tests() # -> {result, output}
##   - Headless (all suites, with exit code):      run_all_headless.gd
##
## Every suite exposes the same `static _run(out: Array) -> int` contract (appends its report lines to
## `out`, returns its fail count), so each is executed exactly once here.

const SUITES := [
	{"name": "Access Path",              "script": "res://tests/gdscript_parser/access_path_test.gd"},
	{"name": "Inference",                "script": "res://tests/gdscript_parser/inference_test.gd"},
	{"name": "Cross-Script Cache",       "script": "res://tests/gdscript_parser/cross_script_cache_test.gd"},
	{"name": "Serialization Round-Trip", "script": "res://tests/gdscript_parser/serialization_roundtrip_test.gd"},
	{"name": "Member Metadata",          "script": "res://tests/gdscript_parser/member_metadata_test.gd"},
	{"name": "Warmup",                   "script": "res://tests/gdscript_parser/warmup_test.gd"},
	{"name": "Declaring Script",         "script": "res://tests/gdscript_parser/declaring_script_test.gd"},
	{"name": "Global Enum",              "script": "res://tests/gdscript_parser/global_enum_test.gd"},
	{"name": "Builtin Return",           "script": "res://tests/gdscript_parser/builtin_return_test.gd"},
	{"name": "Class At Line",            "script": "res://tests/gdscript_parser/class_at_line_test.gd"},
]


func _run() -> void:
	print(run_all())


## Returns the full aggregate report as text (does not quit / print). Reusable from the console.
static func run_all() -> String:
	var out: Array = []
	fill(out)
	return "\n".join(out)


## Runs all suites and returns a structured result for the editor-console `test` command:
## `{"result": int, "output": Array}` where `result` is the total failure count (0 == all good) and
## `output` holds the report lines (the caller decides whether/how to render them). Does not print.
static func run_tests() -> Dictionary:
	var out: Array = []
	var total := fill(out)
	return {"result": total, "output": out}


## Runs every suite once into `out`; returns the summed failure count. Shared by run_all_headless.gd.
static func fill(out: Array) -> int:
	var total := 0
	for s in SUITES:
		out.append("\n########## %s ##########" % s.name)
		total += load(s.script)._run(out)
	out.append("\n================= TOTAL FAILURES: %d =================" % total)
	return total
