extends SceneTree
## Guards the per-member metadata every cross-script lookup is built on: `member_data[SCRIPT_PATH]`
## (the owning script of each member / constant / inner class) and the inner-class `TYPE` path.
##
## These are stamped at parse time - by the regex path in GDScript, by the native tree-sitter parser
## from the path handed to parse_script() - and are then copied verbatim into the disk cache. A blank
## script_path is therefore invisible to serialization_roundtrip.gd (it compares a rehydrated parser
## against the live one, and "" == ""), yet it silently breaks get_gdscript_constants(), has_preload()
## and the inherited branch of get_member_type(), which all resolve a parser from that field.
##
## So: assert the values are RIGHT, in both parse modes, live and rehydrated.
##
##     Godot --headless --path . --script res://tests/gdscript_parser/member_metadata_test.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const Keys = GDScriptParser.Keys
const UString = GDScriptParser.UString

const DIR := "res://tests/gdscript_parser/"
const TEST_CACHE_DIR := "res://.godot/addons/gdscript_parser/parse_cache_meta_test"
const FIXTURES := [
	DIR + "fixtures/gp_base.gd",     # enum + const alias + inner class
	DIR + "fixtures/gp_service.gd",  # inner class with its own enum
	DIR + "scenarios/scenario_basic.gd",
	DIR + "scenarios/scenario_inheritance.gd",
]
const DERIVED := DIR + "fixtures/gp_derived.gd" # extends GpBase: State / StateAlias / Handle
const BASE := DIR + "fixtures/gp_base.gd"

# Headless entry point. quit() lives ONLY here so the static path below is safe to call from the
# editor console / aggregator without killing the editor.
func _init() -> void:
	var res := run_tests()
	print("\n".join(res.output))
	quit(1 if res.result > 0 else 0)


## Runs the suite; returns {result: fail count (0 == all good), output: report lines}.
static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	_ensure_global_class_registry()
	_clear_test_cache_dir()
	var failures := 0

	# Tree-sitter is a GDExtension that isn't registered under `--headless --script`; the parser keys
	# its own default off this (gdscript_parser.gd). Force it on only when present, else the forced
	# parse yields an empty parser (0 classes, write_cache() returns false). Plain-text always runs.
	var ts := ClassDB.class_exists("GDScriptTreeSitter")
	var modes: Array = [false, true] if ts else [false]
	if not ts:
		out.append("  (GDScriptTreeSitter not registered - tree-sitter parse mode skipped)")

	for path in FIXTURES:
		for use_tree_sitter in modes:
			var parser := _make_parser(path, use_tree_sitter)
			var label: String = "tree-sitter" if use_tree_sitter else "plain-text"
			failures += _check_parser(out, parser, path, "%s (%s)" % [path.get_file(), label])

	# The same assertions after a disk round-trip: the cache must not drop or blank the fields.
	# Round-trips whichever parse mode is available (tree-sitter in-editor, plain-text headless).
	for path in FIXTURES:
		var parser := _make_parser(path, ts)
		if not parser.write_cache():
			out.append("  FAIL  %s (cached) -> write_cache() returned false" % path.get_file())
			failures += 1
			continue
		var rehydrated: GDScriptParser = parser.read_cache(path)
		if rehydrated == null:
			out.append("  FAIL  %s (cached) -> read_cache() returned null" % path.get_file())
			failures += 1
			continue
		failures += _check_parser(out, rehydrated, path, "%s (cached)" % path.get_file())

	failures += _check_inherited_constants(out)

	out.append("")
	if failures == 0:
		out.append("MEMBER METADATA: ALL PASS")
	else:
		out.append("MEMBER METADATA: %d FAILURE(S)" % failures)
	_clear_test_cache_dir()
	return failures


## Every member / constant / inner class of every class in `parser` must name `script_path` as its
## owning script, and every inner-class entry must carry the full type path of the class it declares.
static func _check_parser(out: Array, parser: GDScriptParser, script_path: String, label: String) -> int:
	var failures := 0
	for access_path in parser.get_classes():
		var class_obj = parser.get_class_object(access_path)

		if class_obj.main_script_path != script_path:
			out.append("  FAIL  %s -> class '%s' main_script_path '%s' != '%s'"
				% [label, access_path, class_obj.main_script_path, script_path])
			failures += 1

		for kind in [[&"member", class_obj.members], [&"const", class_obj.constants], [&"inner", class_obj.inner_classes]]:
			var dict: Dictionary = kind[1]
			for name in dict.keys():
				var member_data = dict[name]
				if member_data is not Dictionary:
					continue # ParserFunc objects carry their data under .member_data; covered via members
				var stamped := str(member_data.get(Keys.SCRIPT_PATH, ""))
				if stamped != script_path:
					out.append("  FAIL  %s -> %s '%s' in class '%s' has script_path '%s' (expected '%s')"
						% [label, kind[0], name, access_path, stamped, script_path])
					failures += 1

		# inner_classes is a visibility dict - a class declared in an outer scope is listed in the
		# nested scopes that can see it - so an entry's type names where it was DECLARED, not
		# access_path + name. What must hold is that the path is anchored to this script and resolves
		# to a real class object: that is the value get_gdscript_constants() and the access resolver
		# hand back, and the whole thing collapses if script_path is blank.
		for name in class_obj.inner_classes.keys():
			var type_path := str(class_obj.inner_classes[name].get(Keys.TYPE, ""))
			var prefix: String = script_path + "."
			if not type_path.begins_with(prefix) or not type_path.ends_with("." + name):
				out.append("  FAIL  %s -> inner class '%s' (in class '%s') type '%s', expected a '%s'-anchored path ending in '%s'"
					% [label, name, access_path, type_path, script_path, name])
				failures += 1
				continue
			var declared: String = type_path.trim_prefix(prefix)
			if not parser.has_class(declared):
				out.append("  FAIL  %s -> inner class '%s' type names '%s', which the parser has no class object for"
					% [label, name, declared])
				failures += 1

			# An inner class resolves to itself: get_member_type_rich sets origin = the same class path
			# (parser_class.gd, MEMBER_TYPE_CLASS branch). origin is what dict_key.gd looks metadata up
			# by, and what gives this entry its cache dependency (its member_stack is empty).
			var origin := str(class_obj.get_member_type_rich(name).get("origin", ""))
			if origin != type_path:
				out.append("  FAIL  %s -> inner class '%s' origin '%s' != its type path '%s'"
					% [label, name, origin, type_path])
				failures += 1

		# A resolved member with an empty origin is a silent cliff: parser_func.gd only caches a local's
		# resolve when origin != "", and the completions layer has nothing to look metadata up by.
		for name in class_obj.members.keys():
			var tr = class_obj.get_member_type_rich(name)
			if str(tr.get("type", "")) == "":
				continue # unresolvable type - a separate concern, not an origin failure
			if str(tr.get("origin", "")) == "":
				out.append("  FAIL  %s -> member '%s' in class '%s' resolved to type '%s' with an empty origin"
					% [label, name, access_path, tr.get("type", "")])
				failures += 1

	if failures == 0:
		out.append("  PASS  %s  (%d classes)" % [label, parser.get_classes().size()])
	return failures


## The symptom that surfaced the bug: an inherited constant is dropped when its member data cannot
## name the script that owns it (parser_class.gd::get_gdscript_constants can't get a parser for it).
static func _check_inherited_constants(out: Array) -> int:
	var parser := _make_parser(DERIVED, ClassDB.class_exists("GDScriptTreeSitter"))
	var class_obj = parser.get_class_object("")
	var constants: Dictionary = class_obj.get_gdscript_constants(true)

	var failures := 0
	# State / StateAlias / Handle come from GpBase; Local is declared on GpDerived itself.
	for name in ["State", "StateAlias", "Handle", "Local"]:
		if not constants.has(name):
			out.append("  FAIL  get_gdscript_constants(gp_derived) -> missing '%s'" % name)
			failures += 1

	for name in ["State", "StateAlias", "Handle"]:
		var type_path := str(constants.get(name, ""))
		if not type_path.begins_with(BASE):
			out.append("  FAIL  get_gdscript_constants(gp_derived) -> inherited '%s' resolved to '%s', expected a path into %s"
				% [name, type_path, BASE])
			failures += 1

	if failures == 0:
		out.append("  PASS  get_gdscript_constants(gp_derived)  (%d constants, inherited resolved to gp_base)" % constants.size())
	return failures


static func _make_parser(script_path: String, use_tree_sitter := true) -> GDScriptParser:
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.set_parse_cache_dir(TEST_CACHE_DIR)
	parser.set_use_tree_sitter(use_tree_sitter) # before parse(); forces the parse path under test
	parser.active_parser = parser
	var script: GDScript = load(script_path)
	parser.set_current_script(script)
	parser.set_source_code(script.source_code)
	parser.parse()
	return parser


static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


static func _clear_test_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute(TEST_CACHE_DIR):
		return
	var dir := DirAccess.open(TEST_CACHE_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
