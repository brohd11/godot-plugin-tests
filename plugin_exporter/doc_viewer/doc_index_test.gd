@tool
extends EditorScript

## Tests for the doc viewer's index: where a plugin's docs are found, in what order they are
## listed, and what each one is called. The resolution order is load-bearing - the exporter GUI
## hands the viewer either a doc folder or a plugin folder and expects the right thing either way.
##
## Fixtures are written to user:// so the layouts under test sit beside their assertions.
##
##     load("res://tests/plugin_exporter/doc_viewer/doc_index_test.gd").run_tests()

const DocIndex = preload("res://addons/plugin_exporter/src/components/doc_viewer/doc_index.gd")

const DIR = "user://pe_doc_index_tests/"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_reset_dir()
	_test_order()
	_test_titles()
	_test_find_doc_dir()
	_test_readme_fallback()
	_reset_dir()

	var output:Array[String] = []
	output.append("doc_index: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## Depth first, files before the directories at the same level, so the flat list reads as a tree.
static func _test_order() -> void:
	var doc_dir = DIR + "ordered/"
	_w(doc_dir + "zebra.md", "# Zebra\n")
	_w(doc_dir + "alpha.md", "# Alpha\n")
	_w(doc_dir + "guide/setup.md", "# Setup\n")
	_w(doc_dir + "guide/deep/more.md", "# More\n")
	_w(doc_dir + "appendix/notes.md", "# Notes\n")
	_w(doc_dir + "guide/not_a_doc.txt", "ignored\n")

	var docs = DocIndex.scan(doc_dir)
	var titles:Array[String] = []
	for doc in docs:
		titles.append(doc[DocIndex.KEY_TITLE])
	_check("order: files before dirs, sorted within each",
		titles, ["Alpha", "Zebra", "Notes", "Setup", "More"] as Array[String])
	_check("order: non-markdown skipped", docs.size(), 5)
	_check("order: rel path", docs[4][DocIndex.KEY_REL], "guide/deep/more.md")
	_check("order: depth from rel", docs[4][DocIndex.KEY_DEPTH], 2)
	_check("order: top level depth", docs[0][DocIndex.KEY_DEPTH], 0)
	_check("order: missing dir is empty", DocIndex.scan(DIR + "nope/").size(), 0)


static func _test_titles() -> void:
	var dir = DIR + "titles/"
	_check("title: first heading wins", _title(dir + "a.md", "intro\n\n## Second Level\n# Later\n"), "Second Level")
	_check("title: markers stripped", _title(dir + "b.md", "# The **big** one\n"), "The big one")
	# A "#" comment inside a fence is code, not the document's title.
	_check("title: fenced comment ignored", _title(dir + "c.md", "```gdscript\n# not a title\n```\n# Real\n"), "Real")
	_check("title: filename fallback", _title(dir + "export_settings.md", "no heading here\n"), "Export Settings")
	_check("title: dashes read as words", _title(dir + "getting-started.md", "prose\n"), "Getting Started")

	var single = DocIndex.single(dir + "b.md")
	_check("single: one entry", single.size(), 1)
	_check("single: depth zero", single[0][DocIndex.KEY_DEPTH], 0)
	_check("single: titled", single[0][DocIndex.KEY_TITLE], "The big one")


## A released plugin carries .doc; the dev tree it came from carries export_ignore/doc; and a
## caller can point straight at either. A plugin root is never itself a doc folder.
static func _test_find_doc_dir() -> void:
	var addon = DIR + "addon/"
	_w(addon + "plugin.cfg", "[plugin]\n")
	_w(addon + "README.md", "# Readme\n")
	_w(addon + "export_ignore/doc/index.md", "# Index\n")

	_check("find: export_ignore/doc in a dev tree",
		DocIndex.find_doc_dir(addon), (addon + "export_ignore/doc").trim_suffix("/"))

	_w(addon + ".doc/index.md", "# Packaged\n")
	_check("find: packaged .doc wins",
		DocIndex.find_doc_dir(addon), (addon + ".doc").trim_suffix("/"))

	var bare = DIR + "bare_docs/"
	_w(bare + "one.md", "# One\n")
	_check("find: a doc dir passed directly", DocIndex.find_doc_dir(bare), bare.trim_suffix("/"))
	_check("find: trailing slash does not matter",
		DocIndex.find_doc_dir(bare.trim_suffix("/")), bare.trim_suffix("/"))

	# A plugin root holding only a readme must fall through to the readme, not scan the plugin.
	var readme_only = DIR + "readme_only/"
	_w(readme_only + "plugin.cfg", "[plugin]\n")
	_w(readme_only + "README.md", "# Readme Only\n")
	_check("find: plugin root is not a doc dir", DocIndex.find_doc_dir(readme_only), "")
	_check("find: missing dir", DocIndex.find_doc_dir(DIR + "absent/"), "")
	_check("find: empty path", DocIndex.find_doc_dir(""), "")


static func _test_readme_fallback() -> void:
	var dir = DIR + "readme_only/"
	_check("readme: found", DocIndex.find_readme(dir), dir + "README.md")
	_check("readme: case insensitive", DocIndex.find_readme(_mk(DIR + "lower/", "readme.md")), DIR + "lower/readme.md")
	_check("readme: none", DocIndex.find_readme(DIR + "ordered/"), "")


# --- harness -----------------------------------------------------------------------------

static func _title(path:String, text:String) -> String:
	_w(path, text)
	return DocIndex.title_for(path)


static func _mk(dir:String, file:String) -> String:
	_w(dir + file, "# Lower\n")
	return dir


static func _w(path:String, text:String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("could not write fixture: " + path)
		return
	file.store_string(text)
	file.close()


static func _reset_dir() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		_rm_recursive(DIR)
	DirAccess.make_dir_recursive_absolute(DIR)


static func _rm_recursive(dir:String) -> void:
	var dir_access = DirAccess.open(dir)
	if dir_access == null:
		return
	dir_access.include_hidden = true
	for f in dir_access.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for d in dir_access.get_directories():
		_rm_recursive(dir.path_join(d) + "/")
	DirAccess.remove_absolute(dir)


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
		return
	_failures.append("%s — expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)])
