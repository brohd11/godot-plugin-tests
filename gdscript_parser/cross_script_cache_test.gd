extends SceneTree
## Integration test for the live disk-cache path: a rehydrated CACHED_RESOLVED parser must serve
## resolve-cache hits with NO source loaded, lazily attach source only on a miss, be returned by
## get_parser_for_path's disk fallback without a re-parse, and upgrade to live when the file changes.
##
##     Godot_mono_463 --headless --path . --script res://tests/gdscript_parser/cross_script_cache_test.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser

const DIR := "res://tests/gdscript_parser/"
const TEST_CACHE_DIR := "res://.godot/addons/gdscript_parser/parse_cache_test"
const POISON := "__POISONED_CACHE_ENTRY__" # sentinel for _test_live_resolve_stays_live
const FIXTURES := [
	DIR + "scenarios/scenario_basic.gd",
	DIR + "fixtures/gp_service.gd",
	DIR + "scenarios/scenario_inheritance.gd",
]

# Headless entry point (`--script cross_script_cache_test.gd`). quit() lives ONLY here so the static path
# below is safe to call from the editor console / aggregator without killing the editor.
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
	_clear_dir()

	var fails := 0
	fails += _check(out, "hit serves without source", _test_hit_serves_without_source())
	fails += _check(out, "miss lazily loads source", _test_miss_lazy_loads())
	fails += _check(out, "dispatcher disk fallback", _test_dispatcher_disk_fallback())
	fails += _check(out, "tokenizer fetch lazily loads source", _test_tokenizer_fetch_loads_source())
	fails += _check(out, "resolution loads script resource", _test_resolution_loads_script_resource())
	fails += _check(out, "from_cache constructor", _test_from_cache_constructor())
	fails += _check(out, "inherited members persisted + invalidated", _test_inherited_members_cached())
	fails += _check(out, "real parent change clears inherited at read", _test_inherited_parent_mtime_clear())
	fails += _check(out, "prune drops orphaned cache files", _test_prune_orphans())
	fails += _check(out, "file change upgrades to live", _test_file_change_upgrades())
	fails += _check(out, "inner-class resolve valid in both states", _test_inner_class_resolve_symmetry())
	fails += _check(out, "rehydrated funcs keep their line range", _test_rehydrated_func_end_line())
	fails += _check(out, "origin survives the disk cache", _test_origin_survives_cache())
	fails += _check(out, "live resolve stays live on a rehydrated parser", _test_live_resolve_stays_live())

	out.append("")
	out.append("CROSS-SCRIPT CACHE: %s" % ("ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails))
	_clear_dir()
	return fails


static func _check(out: Array, name:String, err:String) -> int:
	if err == "":
		out.append("  PASS  %s" % name)
		return 0
	out.append("  FAIL  %s -> %s" % [name, err])
	return 1


# A rehydrated parser answers an already-resolved member from cache with no code_edit attached.
static func _test_hit_serves_without_source() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	var cached := _fresh_dispatcher().read_cache(pick.script)
	if cached == null:
		return "read_cache returned null"
	if cached.state != GDScriptParser.STATE_CACHED_RESOLVED:
		return "not CACHED_RESOLVED"
	if is_instance_valid(cached.code_edit):
		return "code_edit already loaded before any query"

	var cobj = cached.get_class_object(pick.access_path)
	var tr = cobj.get_member_type_rich(pick.name)
	if tr.get("type", "") != pick.expected:
		return "hit type '%s' != expected '%s'" % [tr.get("type", ""), pick.expected]
	if is_instance_valid(cached.code_edit):
		return "cache HIT loaded source (should not)"
	return ""


# A miss (resolve-cache entry gone) triggers lazy source load and still resolves correctly.
static func _test_miss_lazy_loads() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	var cached := _fresh_dispatcher().read_cache(pick.script)
	if cached == null:
		return "read_cache returned null"
	var cobj = cached.get_class_object(pick.access_path)
	cobj._resolve_cache.erase(pick.name) # force a miss

	if is_instance_valid(cached.code_edit):
		return "code_edit loaded before miss"
	var tr = cobj.get_member_type_rich(pick.name)
	if not is_instance_valid(cached.code_edit):
		return "miss did not lazily load source"
	if tr.get("type", "") != pick.expected:
		return "miss re-resolved '%s' != expected '%s'" % [tr.get("type", ""), pick.expected]
	return ""


# get_parser_for_path serves the parser from disk (no parse) and survives a second request.
static func _test_dispatcher_disk_fallback() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	var d := _fresh_dispatcher()
	var p:GDScriptParser = d.get_parser_for_path(pick.script)
	if p == null:
		return "get_parser_for_path returned null"
	if p.state != GDScriptParser.STATE_CACHED_RESOLVED:
		return "dispatcher did not use disk cache (state %d)" % p.state
	if is_instance_valid(p.code_edit):
		return "disk-fallback parser parsed source"
	# second request must not crash on the (code_edit-less) parse path
	var p2:GDScriptParser = d.get_parser_for_path(pick.script)
	if p2 == null or p2.state != GDScriptParser.STATE_CACHED_RESOLVED:
		return "second request did not return cached parser"
	return ""


# Regression: deep type_lookup paths fetch the tokenizer directly (bypassing get_member_type_rich's
# own guard). Both fetch choke points must lazily load source so line-reads never hit a null code_edit.
static func _test_tokenizer_fetch_loads_source() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	# choke 1: Utils.ParserRef.get_code_edit_parser (used by parser_class / func / caret / access)
	var c1 := _fresh_dispatcher().read_cache(pick.script)
	var cobj = c1.get_class_object(pick.access_path)
	if is_instance_valid(c1.code_edit):
		return "precondition: c1 already had source"
	var cep = GDScriptParser.Utils.ParserRef.get_code_edit_parser(cobj)
	if not is_instance_valid(cep):
		return "ParserRef.get_code_edit_parser returned null"
	if not is_instance_valid(c1.code_edit) or not is_instance_valid(cep.code_edit):
		return "ParserRef fetch did not lazily load source"

	# choke 2: TypeLookup._get_code_edit_parser (used by all type_lookup resolution)
	var c2 := _fresh_dispatcher().read_cache(pick.script)
	if is_instance_valid(c2.code_edit):
		return "precondition: c2 already had source"
	var cep2 = c2.get_type_lookup()._get_code_edit_parser()
	if not is_instance_valid(cep2) or not is_instance_valid(c2.code_edit):
		return "type_lookup fetch did not lazily load source"
	return ""


# Regression: resolution reads get_current_script().resource_path before any tokenizer fetch.
# A cold cached parser (null _script_resource) must lazily load it, and reaching
# _resolve_expression_to_val directly (bypassing the entry-point guards) must not crash.
static func _test_resolution_loads_script_resource() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	# choke: get_current_script lazily loads _script_resource on a cold cached parser
	var c1 := _fresh_dispatcher().read_cache(pick.script)
	var s = c1.get_current_script()
	if not is_instance_valid(s) or s.resource_path != pick.script:
		return "get_current_script did not lazily load the script resource"

	# end-to-end: reach _resolve_expression_to_val directly (bypassing entry-point guards) -> no crash
	var c2 := _fresh_dispatcher().read_cache(pick.script)
	var cobj = c2.get_class_object(pick.access_path)
	var line:int = cobj.line_indexes[0] + 1
	var tr = c2.get_type_lookup().resolve_expression_to_var_data_at_line(pick.name, line)
	if not (tr is Dictionary):
		return "direct type_lookup resolve did not return a type_rich"
	return ""


# from_cache: read-only hit -> CACHED_RESOLVED (no source); read-only miss + code_edit -> LIVE.
static func _test_from_cache_constructor() -> String:
	var live := _make_live()
	if live == null:
		return "no fixture yielded a resolved member"
	var pick:Dictionary = _find_resolved_member(live)
	if pick.is_empty():
		return "no resolved member found"
	live.write_cache()

	# read-only, cache present -> CACHED_RESOLVED with no source attached
	var c := GDScriptParser.from_cache(pick.script, TEST_CACHE_DIR)
	if c == null:
		return "from_cache (hit) returned null"
	if c.state != GDScriptParser.STATE_CACHED_RESOLVED:
		return "from_cache (hit) not CACHED_RESOLVED (state %d)" % c.state
	if is_instance_valid(c.code_edit):
		return "from_cache (hit) attached source before any query"
	var cobj = c.get_class_object(pick.access_path)
	if cobj.get_member_type_rich(pick.name).get("type", "") != pick.expected:
		return "from_cache (hit) served wrong type"

	# read-only, no cache file -> LIVE parse from disk source
	_clear_dir()
	var l := GDScriptParser.from_cache(pick.script, TEST_CACHE_DIR)
	if l == null:
		return "from_cache (miss) returned null"
	if l.state != GDScriptParser.STATE_LIVE:
		return "from_cache (miss) not LIVE (state %d)" % l.state
	if l._class_access.is_empty():
		return "from_cache (miss) did not parse"

	# code_edit given (holds the live buffer) -> always LIVE, bound to that CodeEdit
	var ce := CodeEdit.new()
	ce.text = load(pick.script).source_code
	var lc := GDScriptParser.from_cache(pick.script, TEST_CACHE_DIR, ce)
	var res := ""
	if lc == null:
		res = "from_cache (code_edit) returned null"
	elif lc.state != GDScriptParser.STATE_LIVE:
		res = "from_cache (code_edit) not LIVE (state %d)" % lc.state
	elif lc.code_edit != ce:
		res = "from_cache (code_edit) not bound to the given CodeEdit"
	elif lc._class_access.is_empty():
		res = "from_cache (code_edit) did not parse"
	ce.free()
	return res


# Inherited members must survive rehydrate (served with no source), and the existing mtime monitor
# must re-derive them when a parent script looks changed. Regression for the cross_arg cache bug.
static func _test_inherited_members_cached() -> String:
	var derived := DIR + "fixtures/gp_kit_derived.gd" # extends GpKitBase (has tf_simple, MT, ...)
	var base_member := "tf_simple"

	var live := _make_live_for(derived)
	live.write_cache()

	# rehydrate: inherited members present, straight from cache, no source loaded.
	var cached := _fresh_dispatcher().read_cache(derived)
	if cached == null:
		return "read_cache returned null"
	var cobj = cached.get_class_object("")
	if cobj.inherited_members.is_empty():
		return "inherited_members empty after rehydrate"
	if not cobj.inherited_members.has(base_member):
		return "inherited base member '%s' missing from cache" % base_member
	if is_instance_valid(cached.code_edit):
		return "inherited members loaded source (should serve from cache)"

	# invalidation: a stale mtime baseline (as if a parent changed) must clear + re-derive live.
	var cached2 := _fresh_dispatcher().read_cache(derived)
	var cobj2 = cached2.get_class_object("")
	cobj2.inherited_members["__STALE__"] = {}
	for k in cobj2._inherited_script_mod_cache.keys():
		cobj2._inherited_script_mod_cache[k] = -999 # force a mismatch vs the real file mtime
	var refreshed = cobj2.get_inherited_members()
	if refreshed.has("__STALE__"):
		return "stale inherited_members not invalidated on parent-mtime mismatch"
	if not refreshed.has(base_member):
		return "recompute did not re-derive inherited members"
	return ""


# Real parent-file change (not a faked mtime): the eager _check_inherited_valid sweep in _read must
# drop the child's cached inherited_members at rehydrate. Asserts detection only (the clear); content
# re-derive is covered by _test_inherited_members_cached, and re-loading the mutated parent's source
# is subject to Godot's resource cache, so we don't assert re-derived members here.
static func _test_inherited_parent_mtime_clear() -> String:
	var base := DIR + "tmp_inh_base.gd"
	var child := DIR + "tmp_inh_child.gd"
	if not _write_file(base, "extends RefCounted\nvar alpha: int = 1\n"):
		return "could not create temp base"
	if not _write_file(child, "extends \"%s\"\nvar own: int = 1\n" % base):
		_delete_file(base)
		return "could not create temp child"

	var res := ""
	var live := _make_live_for(child)
	live.get_class_object("").get_inherited_members() # force populate (inherits alpha)
	live.write_cache()

	# base unchanged -> eager check keeps inherited_members (alpha present, no accessor call needed).
	var c1 := _fresh_dispatcher().read_cache(child)
	if c1 == null:
		res = "read_cache returned null (unchanged base)"
	elif not c1.get_class_object("").inherited_members.has("alpha"):
		res = "inherited 'alpha' missing while base unchanged"
	else:
		# change the base (mtime moves past the 1s tick) -> rehydrate -> eager sweep must clear.
		OS.delay_msec(1100)
		if not _write_file(base, "extends RefCounted\nvar beta: int = 1\n"):
			res = "could not rewrite temp base"
		else:
			var c2 := _fresh_dispatcher().read_cache(child)
			if c2 == null:
				res = "read_cache returned null (changed base)"
			elif not c2.get_class_object("").inherited_members.is_empty():
				res = "changed parent did not clear child inherited_members at read"

	_delete_file(child)
	_delete_file(base)
	return res


# prune() removes cache files whose source script is gone, keeps ones still present.
static func _test_prune_orphans() -> String:
	_clear_dir()
	var keep_path := FIXTURES[1] # gp_service.gd, a real fixture that stays
	var tmp := DIR + "tmp_prune.gd"
	if not _write_file(tmp, "extends RefCounted\nvar x: int = 1\n"):
		return "could not create temp fixture"

	_make_live_for(keep_path).write_cache()
	_make_live_for(tmp).write_cache()

	var keep_bin := GDScriptParser.ScriptCache.cache_file_path(TEST_CACHE_DIR, keep_path)
	var tmp_bin := GDScriptParser.ScriptCache.cache_file_path(TEST_CACHE_DIR, tmp)
	if not FileAccess.file_exists(keep_bin) or not FileAccess.file_exists(tmp_bin):
		_delete_file(tmp)
		return "precondition: both .bin files should exist"

	# delete the temp source -> its cache is now orphaned.
	_delete_file(tmp)

	var removed:int = GDScriptParser.ScriptCache.prune(TEST_CACHE_DIR)
	var res := ""
	if removed != 1:
		res = "prune removed %d, expected 1" % removed
	elif FileAccess.file_exists(tmp_bin):
		res = "orphaned .bin not removed"
	elif not FileAccess.file_exists(keep_bin):
		res = "prune removed a valid (source-present) .bin"
	return res


# A changed source file invalidates the cache (mtime) and upgrades the parser to a live parse.
static func _test_file_change_upgrades() -> String:
	var tmp := DIR + "tmp_cache_fixture.gd"
	if not _write_file(tmp, "extends Node\nvar count: int = 1\n"):
		return "could not create temp fixture"

	var live := _make_live_for(tmp)
	live.get_class_object("").get_member_type_rich("count")
	live.write_cache()

	# read_cache succeeds while unchanged...
	if _fresh_dispatcher().read_cache(tmp) == null:
		_delete_file(tmp)
		return "read_cache null before change"

	# ...change the file (mtime moves) -> read_cache must reject, dispatcher must go live.
	# get_modified_time has 1s resolution, so wait past the tick before rewriting.
	OS.delay_msec(1100)
	if not _write_file(tmp, "extends Node\nvar count: int = 1\nvar name_: String = \"x\"\n"):
		_delete_file(tmp)
		return "could not rewrite temp fixture"
	var res := ""
	if _fresh_dispatcher().read_cache(tmp) != null:
		res = "read_cache served a stale (mtime-changed) file"
	else:
		var d := _fresh_dispatcher()
		var p:GDScriptParser = d.get_parser_for_path(tmp)
		if p == null or p.state != GDScriptParser.STATE_LIVE:
			res = "changed file did not produce a LIVE parser"
	_delete_file(tmp)
	return res


# An inner-class entry must get the SAME validity verdict from both parser states. The live check
# (cached_resolve_valid_for_member) and the cached one (ScriptCache.cached_resolve_valid) read the
# same entry through different paths, and a branch that writes no deps splits them: the live parser
# calls its own freshly-written entry invalid and re-resolves forever, the rehydrated one calls it
# valid forever. Neither is caught by comparing serialized output, so assert the verdicts here.
static func _test_inner_class_resolve_symmetry() -> String:
	var path := DIR + "fixtures/gp_base.gd" # class Handle
	var live := _make_live_for(path)
	var live_cobj = live.get_class_object("")
	if not live_cobj.inner_classes.has("Handle"):
		return "fixture has no inner class 'Handle'"

	var live_type:String = live_cobj.get_member_type_rich("Handle").get("type", "")
	if live_type == "":
		return "live parser did not resolve inner class 'Handle'"
	if not live_cobj.cached_resolve_valid_for_member("Handle"):
		return "live parser calls its own resolve of 'Handle' invalid (entry wrote no deps)"

	live.write_cache()
	var cached := _fresh_dispatcher().read_cache(path)
	if cached == null:
		return "read_cache returned null"
	var cached_cobj = cached.get_class_object("")
	if not GDScriptParser.ScriptCache.cached_resolve_valid(cached_cobj, "Handle"):
		return "rehydrated parser calls the cached resolve of 'Handle' invalid"

	var cached_type:String = cached_cobj.get_member_type_rich("Handle").get("type", "")
	if cached_type != live_type:
		return "rehydrated type '%s' != live type '%s'" % [cached_type, live_type]
	return ""


# end_line is derived from func_lines rather than stored, so a rehydrated func must still carry it.
static func _test_rehydrated_func_end_line() -> String:
	var path := DIR + "fixtures/gp_service.gd"
	var live := _make_live_for(path)
	live.write_cache()

	var cached := _fresh_dispatcher().read_cache(path)
	if cached == null:
		return "read_cache returned null"

	var checked := 0
	for access_path in cached.get_classes():
		var cobj = cached.get_class_object(access_path)
		for fname in cobj.functions.keys():
			var f = cobj.functions[fname]
			if f.func_lines.is_empty():
				return "'%s' rehydrated with no func_lines" % fname
			var expected:int = f.func_lines[f.func_lines.size() - 1]
			if f.end_line != expected:
				return "'%s' end_line %d != last func line %d" % [fname, f.end_line, expected]
			checked += 1
	if checked == 0:
		return "fixture yielded no functions to check"
	return ""


# type_rich.origin - the declaring-member path the completions layer keys metadata off
# (dict_key.gd -> get_member_data_from_origin) - is persisted inside CLASS_CACHE_TYPE and must come
# back byte-identical, for class members AND for function locals. parser_func.gd only caches a local's
# resolve when origin != "", so an origin lost in the cache is also a resolve that stops being cached.
static func _test_origin_survives_cache() -> String:
	var path := DIR + "fixtures/gp_service.gd"
	var live := _make_live_for(path)
	_resolve_locals(live)

	var live_origins := _collect_origins(live)
	if live_origins.is_empty():
		return "no origins resolved on the live parser (nothing to compare)"
	if not live_origins.values().any(func(o): return GDScriptParser.Utils.is_absolute_path(o)):
		return "no absolute-path origin resolved (fixture not exercising the interesting shape)"

	live.write_cache()
	var cached := _fresh_dispatcher().read_cache(path)
	if cached == null:
		return "read_cache returned null"

	# read the rehydrated cache entries directly - a re-resolve would hide a dropped origin
	var cached_origins := _collect_origins(cached)
	for key in live_origins.keys():
		if not cached_origins.has(key):
			return "'%s' lost its cached resolve entirely" % key
		if cached_origins[key] != live_origins[key]:
			return "'%s' origin '%s' != live '%s'" % [key, cached_origins[key], live_origins[key]]
	if is_instance_valid(cached.code_edit):
		return "reading cached origins loaded source (should serve from cache)"

	# Pin the one thing the cache DOES drop: trim_type_rich stores no member_stack (the deps it would
	# re-derive are persisted separately). That is safe ONLY because type resolution never serves a
	# cached type_rich - see _test_live_resolve_stays_live below, which pins that precondition.
	for entry in _collect_type_rich(cached).values():
		if not entry.get("member_stack", []).is_empty():
			return "expected an empty member_stack on a rehydrated type_rich"
	return ""


# THE precondition the whole cache scheme rests on: a live resolve stays live, even on a parser
# rehydrated from disk. resolve_expression_to_type_rich() builds its type_rich from scratch every call
# (type_lookup.gd) - it reads no _resolve_cache and no ParserFunc._cache - so its member_stack is
# always complete. Cached type_richs (member_stack dropped by trim_type_rich) are only ever handed out
# by get_member_type_rich / get_local_var_type_rich, which no completion path calls.
#
# Wire the resolve cache into the type walk and that quietly stops being true: dict_key.gd's
# _get_local_var_function_data reads member_stack.back() to find which local/arg an untyped dict was
# declared as, so it would start returning "" and dict-key completion would just go silent - no error,
# no failing test. This case is the tripwire for that.
## Poisoning is the only way to prove this. Simply comparing a rehydrated parser's resolve against a
## live one proves nothing: when the cache holds the RIGHT answer, a walk that reads it returns the
## right answer too, so the two agree whether or not the cache was consulted. So: fill every cached
## resolve entry with a sentinel, then resolve through the live entry point. If a single sentinel comes
## back, the type walk is reading _resolve_cache / ParserFunc._cache. The results must also still match
## the live parser's - the walk has to have re-derived them, poison and all.
static func _test_live_resolve_stays_live() -> String:
	var checked := 0
	for path in [DIR + "fixtures/gp_service.gd", DIR + "scenarios/scenario_basic.gd"]:
		var live := _make_live_for(path)
		live.write_cache()
		var cached := _fresh_dispatcher().read_cache(path)
		if cached == null:
			return "read_cache returned null for %s" % path.get_file()
		if cached.state != GDScriptParser.STATE_CACHED_RESOLVED:
			return "%s did not rehydrate as CACHED_RESOLVED" % path.get_file()
		if _poison_resolve_caches(cached) == 0:
			return "%s rehydrated with no cached resolve entries (nothing to poison)" % path.get_file()

		for access_path in live.get_classes():
			var live_cobj = live.get_class_object(access_path)
			for name in _member_names(live_cobj):
				var line: int = live_cobj.declaration_line
				var member_data = live_cobj.get_member_data(name)
				if member_data is Dictionary:
					line = member_data.get(GDScriptParser.Keys.LINE_INDEX, line)

				var live_tr = live.resolve_expression_to_type_rich(name, line)
				if not (live_tr is Dictionary):
					continue
				# same expression + line, through the LIVE entry point on the poisoned parser
				var tr: Dictionary = cached.resolve_expression_to_type_rich(name, line)
				var where: String = "%s '%s'" % [path.get_file(), name]
				if str(tr.get("type", "")).contains(POISON) or str(tr.get("origin", "")).contains(POISON):
					return "%s -> live resolve handed back a POISONED cache entry: the type walk is reading _resolve_cache" % where
				if tr.get("type", "") != live_tr.type or tr.get("origin", "") != live_tr.origin:
					return "%s -> rehydrated resolve gave type/origin '%s'/'%s', live gave '%s'/'%s'" \
						% [where, tr.get("type", ""), tr.get("origin", ""), live_tr.type, live_tr.origin]
				if tr.get("member_stack") != live_tr.member_stack:
					return "%s -> member_stack differs from the live parser's:\n              cached %s\n              live   %s" \
						% [where, str(tr.get("member_stack")), str(live_tr.member_stack)]
				checked += 1

	if checked == 0:
		return "no members resolved (nothing was actually pinned)"
	return ""


## Stamp the sentinel into every cached resolve entry (class members + function locals). Returns how
## many entries were poisoned.
static func _poison_resolve_caches(parser:GDScriptParser) -> int:
	var count := 0
	for tr in _collect_type_rich(parser).values():
		tr["type"] = POISON
		tr["origin"] = POISON
		count += 1
	return count


## Resolve every function's locals so ParserFunc._cache is populated (members are done by _make_live_for).
static func _resolve_locals(parser:GDScriptParser) -> void:
	for access_path in parser.get_classes():
		var cobj = parser.get_class_object(access_path)
		for fname in cobj.functions.keys():
			var fobj = cobj.functions[fname]
			fobj.map_variables()
			for local_name in fobj.local_vars.keys():
				fobj.get_local_var_type_rich(local_name)


## Every cached type_rich in the parser, keyed "<access_path>::<member>" / "<access_path>::<func>::<local>".
static func _collect_type_rich(parser:GDScriptParser) -> Dictionary:
	var out := {}
	for access_path in parser.get_classes():
		var cobj = parser.get_class_object(access_path)
		for name in cobj._resolve_cache.keys():
			var tr = cobj._resolve_cache[name].get(GDScriptParser.Keys.CLASS_CACHE_TYPE)
			if tr is Dictionary:
				out["%s::%s" % [access_path, name]] = tr
		for fname in cobj.functions.keys():
			var fobj = cobj.functions[fname]
			for key in fobj._cache.keys():
				var tr = fobj._cache[key].get(GDScriptParser.Keys.CLASS_CACHE_TYPE)
				if tr is Dictionary:
					out["%s::%s::%s" % [access_path, fname, key]] = tr
	return out


static func _collect_origins(parser:GDScriptParser) -> Dictionary:
	var out := {}
	var all := _collect_type_rich(parser)
	for key in all.keys():
		out[key] = str(all[key].get("origin", ""))
	return out


# ---- helpers ----

static func _make_live() -> GDScriptParser:
	for path in FIXTURES:
		var parser := _make_live_for(path)
		if not _find_resolved_member(parser).is_empty():
			return parser
	return null

static func _make_live_for(script_path:String) -> GDScriptParser:
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.set_parse_cache_dir(TEST_CACHE_DIR)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
	parser.parse()
	# force resolution so the resolve cache is populated
	for access_path in parser.get_classes():
		var cobj = parser.get_class_object(access_path)
		for name in _member_names(cobj):
			cobj.get_member_type_rich(name)
	return parser

static func _fresh_dispatcher() -> GDScriptParser:
	var d := GDScriptParser.new()
	d.set_autoload_cache()
	d.set_parser_cache({})
	d.set_parser_cache_size(40)
	d.set_parse_cache_dir(TEST_CACHE_DIR)
	return d

static func _member_names(cobj) -> Array:
	var names := []
	names.append_array(cobj.members.keys())
	names.append_array(cobj.constants.keys())
	names.append_array(cobj.functions.keys())
	return names

## First member across all classes whose resolved type is non-empty.
static func _find_resolved_member(parser:GDScriptParser) -> Dictionary:
	for access_path in parser.get_classes():
		var cobj = parser.get_class_object(access_path)
		for name in _member_names(cobj):
			var tr = cobj.get_member_type_rich(name)
			var t:String = tr.get("type", "") if tr is Dictionary else ""
			if t != "":
				return {"script": parser.get_script_path(), "access_path": access_path, "name": name, "expected": t}
	return {}

static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()

static func _write_file(path:String, text:String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

static func _delete_file(path:String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func _clear_dir() -> void:
	if not DirAccess.dir_exists_absolute(TEST_CACHE_DIR):
		return
	var dir := DirAccess.open(TEST_CACHE_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
