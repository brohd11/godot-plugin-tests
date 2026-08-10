@tool
extends EditorScript

## End-to-end coverage of the exporter, driven by the addons/plugin_exporter_test fixture plugin.
## That plugin's source is written to trip every feature worth checking, and its config exports it
## five ways - baseline, reduced, relative, renamed, backported - so the same fixtures have to come
## out correct under settings that are mutually exclusive with each other.
##
## EDITOR ONLY. Running an export reaches for EditorInterface and EditorConsoleSingleton, so this
## suite cannot join tests/plugin_exporter/run_headless.gd - that runner's SUITES list is explicit,
## and leaving this file out of it is what keeps headless green.
##
##     load("res://tests/plugin_exporter/export_fixture_test.gd").run_tests()

const UtilsLocal = preload("res://addons/plugin_exporter/src/class/utils_local.gd")
const ExportFileUtils = UtilsLocal.ExportFileUtils
const KeysConfig = ExportFileUtils.KeysConfig

const PLUGIN = "plugin_exporter_test"

## Export folder basename per variant, in the order the config declares them.
const BASELINE = "plugin-exporter-test"
const REDUCED = "pet-reduced"
const RELATIVE = "pet-relative"
const RENAMED = "pet-renamed"
const BACKPORT = "pet-backport"

static var _failures:Array[String] = []
static var _passed:int = 0
## variant folder prefix -> absolute path of that variant's exported plugin directory
static var _dirs:Dictionary = {}


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	_dirs = {}

	if not Engine.is_editor_hint():
		# Running the export needs EditorInterface, so there is nothing this suite can check.
		return {"result": 0, "output": ["export_fixture: skipped (editor only)"]}

	if _export():
		_test_layout()
		_test_rewrites()
		_test_reduction()
		_test_relative()
		_test_renamed()
		_test_backport()
		_test_no_cross_contamination()
		_test_every_reference_resolves()

	var output:Array[String] = []
	output.append("export_fixture: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## Runs the export and resolves each variant's output directory. Paths are derived from the config
## rather than hardcoded, because the version is baked into them.
static func _export() -> bool:
	var config_path = ExportFileUtils.get_export_config_path(PLUGIN)
	if not FileAccess.file_exists(config_path):
		_fail("fixture plugin config not found at " + config_path)
		return false

	var config = ExportFileUtils.get_export_data(config_path)
	if config == null:
		_fail("could not parse " + config_path)
		return false

	UtilsLocal.PluginExporterStatic.export_by_name(PLUGIN)

	var root = ExportFileUtils.get_full_export_path(
		config.get(KeysConfig.EXPORT_ROOT), config.get(KeysConfig.PLUGIN_FOLDER), config_path)
	for export_entry in config.get(KeysConfig.EXPORTS, []):
		var folder = ExportFileUtils.replace_version(
			export_entry.get(KeysConfig.Export.EXPORT_FOLDER), config_path)
		var dir = root.path_join(folder)
		if not DirAccess.dir_exists_absolute(dir):
			_fail("export produced no directory at " + dir)
			continue
		# "pet-reduced-0.1.0/plugin_exporter_test/" -> "pet-reduced"
		_dirs[folder.get_slice("/", 0).get_slice("-0", 0)] = dir

	return not _dirs.is_empty()


## What the export decided to place where: exclusions, transfers, relocation, tagged dependencies,
## licenses and the singleton-module manifest.
static func _test_layout() -> void:
	var dir = _dirs.get(BASELINE, "")
	if dir == "":
		return

	_check("exclude: directory", _exists(dir, "src/excluded/should_not_export.gd"), false)
	_check("exclude: file extension", _exists(dir, "src/scratch.tmp"), false)
	_check("exclude: named file", _exists(dir, "src/notes_excluded.md"), false)

	_check("other_transfers: single file", _exists(dir, "docs/note.txt"), true)
	_check("other_transfers: directory", _exists(dir, "docs/bundle/first.txt"), true)
	_check("other_transfers: directory, second entry", _exists(dir, "docs/bundle/second.txt"), true)

	# A class not being renamed is what makes move_global_files relocate it.
	_check("move_global_files: un-renamed class relocated", _exists(dir, "global/fixture_kept.gd"), true)
	_check("move_global_files: left src/", _exists(dir, "src/globals/fixture_kept.gd"), false)
	_check("renamed class stays put", _exists(dir, "src/globals/fixture_global.gd"), true)
	# parse_tres erases the .tres's script class from the renames, so it relocates the same way.
	_check("tres script_class exempted from rename", _exists(dir, "global/pet_resource.gd"), true)

	_check("dependency tag: explicit dir", _exists(dir, "src/deps/layout.json"), true)
	_check("dependency tag: current dir", _exists(dir, "src/version.cfg"), true)
	_check("dependency tag: plain", _found(dir, "yaml_parser/version.cfg"), true)

	_check("licenses gathered", _found(dir, "licenses/addon_lib_brohd/LICENSE"), true)
	# addon_lib/brohd/dock_manager/config carries its own LICENSE under brohd's. Closest-ancestor
	# matching has to hand that subtree to the nested one while the rest still lands under brohd,
	# so both arrive - matching in scan order let the outer license swallow the subtree.
	_check("nested license gathered alongside its parent",
		_found(dir, "licenses/addon_lib_brohd_dock_manager_config/LICENSE"), true)
	# res:// is held out of the matching, so no license lands from an empty flattened dir name.
	_check("no project-root license", _exists(dir, "licenses/LICENSE"), false)

	# include_docs: export_ignore/doc lands as .doc, structure intact, copied verbatim. The image
	# must arrive without its sidecar - that .import points at this project's .godot cache, and
	# nothing in a dot-prefixed folder is imported in the plugin it ships to anyway.
	_check("docs: top level", _exists(dir, ".doc/index.md"), true)
	_check("docs: nested", _exists(dir, ".doc/guide/nested.md"), true)
	_check("docs: non-markdown carried too", _exists(dir, ".doc/images/shot.png"), true)
	_check("docs: no import sidecar", _exists(dir, ".doc/images/shot.png.import"), false)
	_check("docs: source folder still excluded", _exists(dir, "export_ignore/doc/index.md"), false)
	_check("docs: hidden folder reaches the zip", _zipped(dir, ".doc/index.md"), true)
	_check("singleton module manifest", _has(dir, ".export_data", "PETSingletonMod"), true)
	_check("singleton module version from tag", _has(dir, ".export_data", "0.2.0"), true)
	_check("min version written to cfg", _has(dir, "plugin.cfg", "minimum_version="), true)


## The per-line rewrites every export performs.
static func _test_rewrites() -> void:
	var dir = _dirs.get(BASELINE, "")
	if dir == "":
		return

	_check("gd exported flag flipped", _has(dir, "src/core/consumer.gd",
		"const PLUGIN_EXPORTED = true"), true)
	_check("cs exported flag flipped", _has(dir, "src/cs/FixtureCs.cs",
		"public const bool PLUGIN_EXPORTED = true;"), true)
	_check("cs namespace renamed", _has(dir, "src/cs/FixtureCs.cs",
		"namespace PETExported.Fixture;"), true)

	_check("class_name stripped from renamed class", _has(dir, "src/globals/fixture_global.gd",
		"class_name PETFixtureGlobal"), false)
	_check("class_name kept for ignored class", _has(dir, "global/fixture_kept.gd",
		"class_name PETKeptGlobal"), true)
	_check("renamed class injected as preload", _has(dir, "src/core/consumer.gd",
		"### Plugin Exporter Global Classes"), true)
	_check("renamed class use rewritten", _has(dir, "src/core/consumer.gd",
		"PETFixtureGlobal."), false)

	_check("uid preload resolved to the copy", _has(dir, "src/core/consumer.gd",
		'preload("uid://'), false)
	_check("ignore-remote path untouched", _has(dir, "src/core/consumer.gd",
		'"res://addons/addon_lib/brohd/README.md" #! ignore-remote'), true)
	_check("namespace directive stripped", _has(dir, "src/core/tags.gd", "#! namespace"), false)

	_check("strip-cast: built-in name", _has(dir, "src/core/tags.gd",
		"-> PE_STRIP_CAST_SCRIPT"), false)
	_check("strip-cast: from strip_cast.txt", _has(dir, "src/core/tags.gd",
		"-> PETStripped"), false)
	_check("strip-cast: from inline tag", _has(dir, "src/core/tags.gd",
		"as PETLocalOnly"), false)

	# "#! remote" + extends: the stub is replaced wholesale by the script it extended.
	_check("remote extends replaced by target", _has(dir, "src/remote_extends.gd",
		"static func get_major_version"), true)
	_check("remote extends stub gone", _has(dir, "src/remote_extends.gd",
		'extends "res://addons/addon_lib'), false)

	# The scene keeps its references, rewritten to the copies.
	_check("tscn ext_resource rewritten", _has(dir, "src/scenes/fixture_scene.tscn",
		'path="res://addons/addon_lib'), false)
	_check("tres script_class header preserved", _has(dir, "src/scenes/fixture_resource.tres",
		'script_class="PETResource"'), true)


## reduce_access_paths: dotted chains become direct preloads, and a hub every mention of which was
## rewritten away is dropped along with the tree it preloaded.
static func _test_reduction() -> void:
	var dir = _dirs.get(REDUCED, "")
	if dir == "":
		return

	_check("reduced: declaration form became the preload", _has(dir, "src/core/access_paths.gd",
		"const UList = preload("), true)
	_check("reduced: inline use rewritten", _has(dir, "src/core/access_paths.gd",
		"return UList.get_next_item"), true)
	_check("reduced: no chain left", _has(dir, "src/core/access_paths.gd",
		"ALibRuntime.Utils"), false)
	_check("reduced: pass-through hub dropped", _found(dir, "_ns/a_lib_runtime.gd"), false)

	# One mention that no reduction rewrites away is enough to keep a hub.
	_check("reduced: bare-used hub kept", _found(dir, "_ns/singletons.gd"), true)
	# Head already the deepest file it names, so the chain must be left alone.
	_check("reduced: no-op chain untouched", _has(dir, "src/core/access_paths.gd",
		".pattern"), true)

	# The derived script rewrites its uses but must not redeclare the inherited constant.
	_check("reduced: base declares the binding", _has(dir, "src/core/access_base.gd",
		"const USort = preload("), true)
	_check("reduced: derived uses it", _has(dir, "src/core/access_derived.gd",
		"return USort.sort_priority_dict"), true)
	_check("reduced: derived does not redeclare", _has(dir, "src/core/access_derived.gd",
		"const USort = preload("), false)

	# An enum tail the walk cannot follow is kept on the end of the rewritten expression, and the
	# file it resolved to has to travel even though nothing else in the plugin preloads it.
	_check("reduced: tail chain rewritten", _has(dir, "src/core/access_tail.gd",
		"return StringMap.Mode.STRING"), true)
	_check("reduced: tail target exported", _found(dir, "utils/string/string_map.gd"), true)


static func _test_relative() -> void:
	var dir = _dirs.get(RELATIVE, "")
	if dir == "":
		return

	# "./" is only prepended when the path does not already start with a dot, so "../" is the
	# normal shape for anything not in the same directory.
	_check("relative: preloads are relative", _has(dir, "src/core/consumer.gd",
		'preload("../'), true)
	_check("relative: no absolute preloads", _has(dir, "src/core/consumer.gd",
		'preload("res://'), false)
	_check("relative: scene refs are relative", _has(dir, "src/scenes/fixture_scene.tscn",
		'path="res://'), false)


static func _test_renamed() -> void:
	var dir = _dirs.get(RENAMED, "")
	if dir == "":
		return

	_check("renamed: paths carry the new plugin name", _has(dir, "src/core/consumer.gd",
		"res://addons/pet_renamed_plugin/"), true)
	_check("renamed: old plugin name gone", _has(dir, "src/core/consumer.gd",
		"res://addons/plugin_exporter_test/"), false)
	# gather_licenses composes get_export_path and get_renamed_path in the opposite order to
	# everywhere else, which only matters when rename_plugin is on - this is the only case in the
	# repo that exercises it.
	_check("renamed: license still landed inside the export",
		_found(dir, "licenses/addon_lib_brohd/LICENSE"), true)
	# gather_docs maps out of res:// the same way, so it shares that hazard.
	_check("renamed: docs landed inside the export", _exists(dir, ".doc/index.md"), true)


static func _test_backport() -> void:
	var dir = _dirs.get(BACKPORT, "")
	if dir == "":
		return

	# The fixture's docstring deliberately avoids naming the annotation, so the only occurrence
	# would be the real one on line 1.
	_check("backport: @abstract stripped", _has(dir, "src/core/backport_bits.gd", "@abstract"), false)
	_check("backport: EditorInterface replaced", _has(dir, "src/core/backport_bits.gd",
		'Engine.get_singleton(&"EditorInterface")'), true)


## Each variant's setting must reach that variant and no other. The config declares them as untyped
## keys with the "parse_*" blocks left out, which is the shape that used to hand an export the
## shared settings dictionary by reference - so a regression shows up as a later variant quietly
## adopting an earlier one's setting. The per-variant tests above would barely notice: they only
## assert a setting is on where it belongs, never that it is off everywhere else.
static func _test_no_cross_contamination() -> void:
	for variant in [BASELINE, RELATIVE, RENAMED, BACKPORT]:
		var dir = _dirs.get(variant, "")
		if dir == "":
			continue
		# Reduction is variant 2's alone; with it off the pass-through hub is still copied.
		_check("%s: reduction did not leak in" % variant, _found(dir, "_ns/a_lib_runtime.gd"), true)

	for variant in [BASELINE, REDUCED, RENAMED, BACKPORT]:
		var dir = _dirs.get(variant, "")
		if dir == "":
			continue
		# Relative paths are variant 3's alone.
		_check("%s: relative paths did not leak in" % variant, _has(dir, "src/core/consumer.gd",
			'preload("res://'), true)

	for variant in [BASELINE, REDUCED, RELATIVE, RENAMED]:
		var dir = _dirs.get(variant, "")
		if dir == "":
			continue
		# The backport is variant 5's alone, and it is the last entry - so this catches a leak
		# running the other way, from a later export into an earlier one.
		_check("%s: backport did not leak in" % variant, _has(dir, "src/core/backport_bits.gd",
			"@abstract"), true)


## The check that catches what the targeted ones miss: after every rewrite, does each reference
## still point at a file that is actually in the export? A dropped dependency, an over-eager prune
## and a mis-ordered rename all surface here.
static func _test_every_reference_resolves() -> void:
	var preload_regex = RegEx.new()
	preload_regex.compile(r'(?:preload|load)\(\s*"([^"]+)"\s*\)')
	var ext_resource_regex = RegEx.new()
	ext_resource_regex.compile(r'\[ext_resource[^\]]*\bpath="([^"]+)"')

	for variant:String in _dirs:
		var dir:String = _dirs[variant]
		var broken:Array[String] = []
		for file in _walk(dir):
			var ext = file.get_extension()
			if not ext in ["gd", "tscn", "tres"]:
				continue
			var text = FileAccess.get_file_as_string(file)
			var regex = preload_regex if ext == "gd" else ext_resource_regex
			for m in regex.search_all(text):
				var target:String = m.get_string(1)
				if target.begins_with("uid://"):
					continue # a uid the export chose not to rewrite resolves through the project
				var resolved = _resolve(target, file, dir)
				if resolved != "" and not FileAccess.file_exists(resolved):
					broken.append("%s -> %s" % [file.trim_prefix(dir), target])

		_check("%s: every reference resolves (%s)" % [variant, ", ".join(broken)],
			broken.is_empty(), true)


## Maps a reference as written back onto disk. Absolute paths are anchored at the export's plugin
## directory, which is what "res://addons/<plugin>/" means once the plugin is installed.
static func _resolve(target:String, from_file:String, dir:String) -> String:
	if target.begins_with("res://addons/"):
		var rest = target.trim_prefix("res://addons/")
		var plugin_dir = rest.get_slice("/", 0)
		if not rest.begins_with(plugin_dir + "/"):
			return ""
		if dir.get_file() != plugin_dir:
			return "" # points at a different plugin, not this export's business
		return dir.path_join(rest.trim_prefix(plugin_dir + "/"))
	if target.begins_with("res://"):
		return "" # outside addons entirely, e.g. a deliberately ignored path
	if target.begins_with("./") or target.begins_with("../"):
		return from_file.get_base_dir().path_join(target).simplify_path()
	return ""


static func _walk(dir:String) -> Array[String]:
	var out:Array[String] = []
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_walk(dir.path_join(d)))
	return out


static func _exists(dir:String, relative:String) -> bool:
	return FileAccess.file_exists(dir.path_join(relative))


## True when the variant's zip carries `relative`. The zip is written from a separate walk of the
## export, so a file being on disk is no proof it was packaged - hidden folders especially.
static func _zipped(dir:String, relative:String) -> bool:
	var plugin_dir = dir.trim_suffix("/")
	var zip_path = plugin_dir.get_base_dir() + ".zip"
	var reader = ZIPReader.new()
	if reader.open(zip_path) != OK:
		_fail("no zip written at " + zip_path)
		return false
	var suffix = plugin_dir.get_file().path_join(relative)
	var found = false
	for entry in reader.get_files():
		if entry.ends_with(suffix):
			found = true
			break
	reader.close()
	return found


## True when any file in the export ends with `suffix` - for targets whose exact location inside
## remote_dir is not the thing under test.
static func _found(dir:String, suffix:String) -> bool:
	for file in _walk(dir):
		if file.ends_with(suffix):
			return true
	return false


static func _has(dir:String, relative:String, needle:String) -> bool:
	var path = dir.path_join(relative)
	if not FileAccess.file_exists(path):
		return false
	return FileAccess.get_file_as_string(path).find(needle) > -1


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])


static func _fail(message:String) -> void:
	_failures.append(message)
