extends RefCounted

const Optimizer = preload("res://addons/addon_lib/gdscript_optimizer/optimizer.gd")
const FIXTURE = "res://tests/gdscript_optimizer/fixtures/struct_reference_types.gd"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var original = load(FIXTURE)
	for allowed in [false, true]:
		for reads_allowed in [false, true]:
			for mode in 3:
				var context = Optimizer.Context.new()
				context.scalar_replacement = true
				context.scalar_replacement_allow_ref_counted = allowed
				context.struct_read_types_allow_ref_counted = reads_allowed
				context.struct_read_types = mode as Optimizer.Context.StructReadTypes
				var optimizer = Optimizer.new()
				var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, context)
				if not prepared.errors.is_empty():
					failures.append(str(prepared.errors))
					continue
				var result:Dictionary = optimizer.apply(FIXTURE, Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
				var script := GDScript.new()
				script.source_code = "\n".join(result.lines)
				if script.reload() != OK:
					failures.append("reference compile failed: allowed=%s mode=%d" % [allowed, mode])
					continue
				for method:String in ["scalar", "surviving", "cross_file", "nested", "constructor_reference", "objects"]:
					if script.call(method) != original.call(method):
						failures.append("reference result changed: %s scalar=%s reads=%s mode=%s actual=%s expected=%s" % [method, allowed, reads_allowed, mode, script.call(method), original.call(method)])
				if (result.stats.get("scalar_structs", 0) > 0) != allowed:
					failures.append("reference scalar eligibility incorrect: %s %s" % [allowed, prepared.warnings])
				if mode != 0:
					var stat:String = "struct_typed_captures" if mode == 1 else "struct_read_casts"
					if (result.stats.get(stat, 0) >= 8) != reads_allowed:
						failures.append("reference reads missing: %s %s" % [allowed, result.stats])
	var context = Optimizer.Context.new()
	context.scalar_replacement_allow_ref_counted = true
	context.struct_read_types_allow_ref_counted = true
	context.scalar_replacement = true
	context.map_path = func(key:String): return "res://relocated/" + key + ".gd"
	var optimizer = Optimizer.new()
	var prepared:Dictionary = optimizer.prepare({"main": FIXTURE,
		"payload": "res://tests/gdscript_optimizer/fixtures/reference_payload.gd"}, context)
	var relocated:Dictionary = optimizer.apply("main", Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
	if not prepared.errors.is_empty() or not "\n".join(relocated.lines).contains('preload("res://relocated/payload.gd")'):
		failures.append("reference type dependency ignored source identity/output mapping")
	return {"result": failures.size(), "output": ["struct references: %d failures" % failures.size()] + failures}
