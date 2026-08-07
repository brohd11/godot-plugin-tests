@tool
extends EditorScript

## Tests for alias_completion.gd's static helpers.
##
## The provider's _init needs a live singleton, which is why the collect/display/indent rules are
## static — what lands in a script is decided here, without an editor. The two hints and the display
## prefix carry most of the weight: all three feed CodeEdit's own filtering or drawing, so their
## exact shape is the thing that breaks.

const AliasCompletion = preload("res://addons/code_completions/src/completions/alias_completion.gd")

const FIXTURE_SCRIPT = preload("res://tests/code_completions/fixtures/aliases_fixture.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_display_single_line()
	_test_display_multi_line()
	_test_display_truncates()
	_test_display_with_arg()
	_test_display_truncates_long_row()
	_test_resolve_arg()
	_test_blank_arg_round_trip()
	_test_display_blank_arg()
	_test_split_args()
	_test_split_open_arg()
	_test_name_option_round_trip()
	_test_name_display_stays_matchable()
	_test_filled_arg_count()
	_test_short_argument_list()
	_test_closed_slot_round_trip()
	_test_arg_hint()
	_test_open_arg_index()
	_test_code_hint()
	_test_longest_key()
	_test_display_key()
	_test_keys_starting_with()
	_test_lookup_directions_differ()
	_test_menu_insert()
	_test_array_builder()
	_test_builder_options()
	_test_arg_text()
	_test_split_consumed()
	_test_prefix_is_contiguous()
	_test_normalize_row()
	_test_builder_dict_rows()
	_test_dict_row_display_separation()
	_test_script_constants()
	_test_script_builders()
	_test_script_arg_names()
	_test_script_skips()
	_test_build_args()
	_test_builder_round_trip()
	_test_apply_indent()
	_test_apply_indent_no_op()
	_test_line_indent()
	_test_shipped_script_collects()

	var output:Array[String] = []
	output.append("alias_completion: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	var res = run_tests()
	print("\n".join(res.output))


## Values are entry records now; most cases only care about the single option they wrote.
static func _options(res:Dictionary, key:String) -> Array:
	var entry:Dictionary = res.aliases.get(key, {})
	return entry.get("options", [])


static func _test_display_single_line() -> void:
	var display = AliasCompletion.make_display("mykey", "myoption")
	_check(display == "(mykey) myoption", "display single line: %s" % display)


static func _test_display_multi_line() -> void:
	# the key must appear in the display or CodeEdit's own filter drops the option
	var display = AliasCompletion.make_display("ready", "func _ready() -> void:\n\tpass")
	_check(display == "(ready) func _ready() -> void: " + AliasCompletion.ELLIPSIS,
			"display multi line: %s" % display)


static func _test_display_truncates() -> void:
	var long_line = "x".repeat(AliasCompletion.DISPLAY_MAX + 20)
	var display = AliasCompletion.make_display("k", long_line)
	_check(display.begins_with("(k) "), "display truncate: keeps key prefix -> %s" % display)
	_check(display.ends_with(AliasCompletion.ELLIPSIS), "display truncate: ends with ellipsis")
	_check(display.length() == 4 + AliasCompletion.DISPLAY_MAX + AliasCompletion.ELLIPSIS.length(),
			"display truncate: length %d" % display.length())


static func _test_display_with_arg() -> void:
	# the prefix is the typed run, one contiguous string - no space to break the match in two
	var display = AliasCompletion.make_display("/setget/myvar", "var myvar:int = 0:")
	_check(display == "(/setget/myvar) var myvar:int = 0:", "display with arg: %s" % display)
	_check(AliasCompletion.make_display("/mykey", "myoption") == "(/mykey) myoption", "display with arg: no arguments")


## A builder can return a row far longer than the popup: the prefix survives, the body is clipped.
static func _test_display_truncates_long_row() -> void:
	var text = "var %s = 0" % "x".repeat(AliasCompletion.DISPLAY_MAX + 20)
	var display = AliasCompletion.make_display("/k/arg", text)
	_check(display.begins_with("(/k/arg) "), "display truncate long row: prefix -> %s" % display.substr(0, 12))
	_check(display.ends_with(AliasCompletion.ELLIPSIS), "display truncate long row: ends with ellipsis")


static func _test_resolve_arg() -> void:
	_check(AliasCompletion.resolve_arg("") == AliasCompletion.PLACEHOLDER, "resolve arg: nothing typed -> default")
	_check(AliasCompletion.resolve_arg(AliasCompletion.BLANK_ARG) == "", "resolve arg: lone underscore -> blank")
	# leading-underscore names are ordinary GDScript and must survive verbatim
	_check(AliasCompletion.resolve_arg("_myvar") == "_myvar", "resolve arg: private name verbatim")
	_check(AliasCompletion.resolve_arg("__") == "__", "resolve arg: only a LONE underscore is special")
	_check(AliasCompletion.resolve_arg("on_control_") == "on_control_", "resolve arg: plain text verbatim")


## The blank marker has to survive all the way to the builder's parameter, not just resolve_arg.
static func _test_blank_arg_round_trip() -> void:
	var args = func(typed): return AliasCompletion.build_args(AliasCompletion.split_args(typed), 1, 1)
	_check(args.call("/_") == [""], "blank arg: lone underscore reaches the builder blank")
	_check(args.call("/on_control_") == ["on_control_"], "blank arg: prefixed form verbatim")
	_check(args.call("") == [AliasCompletion.PLACEHOLDER], "blank arg: nothing typed is not blank")


static func _test_display_blank_arg() -> void:
	# the display shows what was TYPED, so explicit blank stays distinguishable from a plain alias
	_check(AliasCompletion.make_display("/dropdata/_", "func _get_drop_data():") == "(/dropdata/_) func _get_drop_data():",
			"display blank arg: %s" % AliasCompletion.make_display("/dropdata/_", "func _get_drop_data():"))


static func _test_split_args() -> void:
	_check(AliasCompletion.split_args("").is_empty(), "split args: nothing typed -> empty")
	# the leading separator is optional, so both spellings land the same way
	_check(Array(AliasCompletion.split_args("/i/aliases")) == ["i", "aliases"], "split args: leading separator")
	_check(Array(AliasCompletion.split_args("i/aliases")) == ["i", "aliases"], "split args: no leading separator")
	_check(Array(AliasCompletion.split_args("myvar")) == ["myvar"], "split args: single argument")
	_check(Array(AliasCompletion.split_args("_")) == ["_"], "split args: blank marker survives to resolve_arg")


static func _test_split_open_arg() -> void:
	_check(Array(AliasCompletion.split_open_arg("/i/alia")) == ["/i/", "alia"], "split open arg: mid argument")
	# a trailing separator means the argument is closed, so the open segment is empty
	_check(Array(AliasCompletion.split_open_arg("/i/")) == ["/i/", ""], "split open arg: closed")
	_check(Array(AliasCompletion.split_open_arg("/alia")) == ["/", "alia"], "split open arg: first argument")
	_check(AliasCompletion.split_open_arg("myvar").is_empty(), "split open arg: no separator -> empty")


static func _test_name_option_round_trip() -> void:
	var closed = "forloop/i/"
	_check(AliasCompletion.make_name_display(closed, "_aliases") == "(forloop/i/) _aliases",
			"name option: display -> %s" % AliasCompletion.make_name_display(closed, "_aliases"))
	var insert = AliasCompletion.make_name_insert(closed, "_aliases")
	_check(insert == "forloop/i/_aliases/", "name option: insert -> %s" % insert)

	# what the NEXT completion sees once that insert lands: two filled slots, a third still open
	var typed = insert.trim_prefix("forloop")
	_check(Array(AliasCompletion.split_args(typed)) == ["i", "_aliases", ""],
			"name option: feeds back as args -> %s" % [Array(AliasCompletion.split_args(typed))])
	_check(AliasCompletion.build_args(AliasCompletion.split_args(typed), 2, 2) == ["i", "_aliases"],
			"name option: both arguments reach the builder")


static func _test_name_display_stays_matchable() -> void:
	# the whole display format rests on this: Godot filters the typed run against the display, so a
	# bare "_aliases" row would be dropped. Guard it as a subsequence check.
	var display = AliasCompletion.make_name_display("forloop/i/", "_aliases")
	_check(_is_subsequence("forloop/i/alia", display), "name display: typed run is a subsequence of %s" % display)
	_check(not _is_subsequence("forloop/i/alia", "_aliases"), "name display: a bare name would NOT match")


## Case-insensitive, because Godot's own matcher is: typing "action" reaches "ActionCopy".
static func _is_subsequence(needle:String, haystack:String) -> bool:
	needle = needle.to_lower()
	haystack = haystack.to_lower()
	var i = 0
	for c in haystack:
		if i < needle.length() and c == needle[i]:
			i += 1
	return i == needle.length()


static func _test_filled_arg_count() -> void:
	# a trailing separator leaves an empty element that must not count as supplied
	_check(AliasCompletion.filled_arg_count(AliasCompletion.split_args("/i/")) == 1, "filled args: trailing separator")
	_check(AliasCompletion.filled_arg_count(AliasCompletion.split_args("/i/aliases")) == 2, "filled args: both given")
	# an explicit blank was still *supplied*, so it counts
	_check(AliasCompletion.filled_arg_count(AliasCompletion.split_args("_")) == 1, "filled args: blank marker counts")
	_check(AliasCompletion.filled_arg_count(AliasCompletion.split_args("")) == 0, "filled args: nothing typed")


## Mirrors the provider's rule for offering NAME CANDIDATES: a separator means slots are being
## worked through, and there are still unfilled ones.
static func _is_short(typed:String, slots:int) -> bool:
	return typed.contains(AliasCompletion.ARG_SEPARATOR) \
			and AliasCompletion.filled_arg_count(AliasCompletion.split_args(typed)) < slots


static func _test_short_argument_list() -> void:
	# a closed slot must not count as filled, or the candidates for it never appear
	_check(_is_short("/i/", 2), "short list: closed slot still counts as short")
	_check(_is_short("/i", 2), "short list: mid argument")
	_check(not _is_short("/i/aliases", 2), "short list: fully supplied")
	_check(not _is_short("/i/aliases/", 2), "short list: fully supplied with trailing separator")
	# no separator at all means arguments are not being worked through positionally
	_check(not _is_short("_", 3), "short list: no separator never counts as short")


static func _test_closed_slot_round_trip() -> void:
	# picking a name on a freshly closed slot has to land both arguments on the builder
	var insert = AliasCompletion.make_name_insert("forloop/i/", "_aliases")
	var typed = insert.trim_prefix("forloop")
	_check(AliasCompletion.build_args(AliasCompletion.split_args(typed), 2, 2) == ["i", "_aliases"],
			"closed slot: both parameters filled after the pick")
	_check(not _is_short(typed, 2), "closed slot: no longer short after the pick")
	# and the hint has moved on to the slot the trailing separator opened
	_check(AliasCompletion.open_arg_index(typed) == 2, "closed slot: hint tracks to the next argument")


## The browse row's hint, read off the signature - a bracketed name has a default.
static func _test_arg_hint() -> void:
	var names = PackedStringArray(["iterator", "collection"])
	_check(AliasCompletion.make_arg_hint(names, 2, 2) == "(iterator/collection)",
			"arg hint: both required -> %s" % AliasCompletion.make_arg_hint(names, 2, 2))
	_check(AliasCompletion.make_arg_hint(names, 1, 1) == "(iterator/?:collection)",
			"arg hint: a default is bracketed -> %s" % AliasCompletion.make_arg_hint(names, 1, 1))
	_check(AliasCompletion.make_arg_hint(PackedStringArray(), 0, 0) == "",
			"arg hint: no parameters -> nothing")
	# the hint sits after the key, or a partly typed key stops matching the row contiguously
	var display = AliasCompletion.make_display("/", "setget" + AliasCompletion.make_arg_hint(names, 1, 1))
	_check(display.contains("(/) setget"), "arg hint: key stays contiguous after the prefix -> %s" % display)


static func _test_open_arg_index() -> void:
	var index = AliasCompletion.open_arg_index
	# nothing typed and a bare separator are both "about to type argument 0"
	_check(index.call("") == 0, "open arg index: nothing typed")
	_check(index.call("/") == 0, "open arg index: separator only")
	_check(index.call("i") == 0, "open arg index: no leading separator")
	_check(index.call("/i") == 0, "open arg index: still on the first")
	# a trailing separator has moved on to the next one
	_check(index.call("/i/") == 1, "open arg index: first closed")
	_check(index.call("/i/_ali") == 1, "open arg index: mid second")
	_check(index.call("i/j") == 1, "open arg index: leading separator is optional")
	_check(index.call("/i/j/k") == 2, "open arg index: third")


static func _test_code_hint() -> void:
	var names = PackedStringArray(["name", "type"])
	var hint = AliasCompletion.make_code_hint("setget", names, 1, 0)
	# assert on the stripped text, so the suite doesn't depend on how CodeEdit draws the marker
	var plain = hint.replace(AliasCompletion.HINT_MARKER, "")
	_check(plain == "setget(name, ?:type)", "code hint: reads as a signature -> %s" % plain)
	_check(hint.count(AliasCompletion.HINT_MARKER) == 2, "code hint: exactly one marked run")
	_check(hint.contains(AliasCompletion.HINT_MARKER + "name" + AliasCompletion.HINT_MARKER),
			"code hint: the argument being typed is the marked one")
	# and it follows the index
	var second = AliasCompletion.make_code_hint("setget", names, 1, 1)
	_check(second.contains(AliasCompletion.HINT_MARKER + "?:type" + AliasCompletion.HINT_MARKER),
			"code hint: marks the second once the first is closed")
	# past the last parameter nothing is marked rather than marking the wrong one
	var over = AliasCompletion.make_code_hint("setget", names, 1, 5)
	_check(not over.contains(AliasCompletion.HINT_MARKER), "code hint: index past the end marks nothing")
	_check(AliasCompletion.make_code_hint("icon", PackedStringArray(), 0, 0) == "icon()",
			"code hint: no parameters")


static func _test_longest_key() -> void:
	# order-independent: the dict is built in file order, the answer must not depend on it
	var aliases = {"for": [], "fori": [], "forib": []}
	_check(AliasCompletion.longest_key(aliases, "forib") == "forib", "longest key: exact, most specific")
	_check(AliasCompletion.longest_key(aliases, "fori") == "fori", "longest key: mid length")
	_check(AliasCompletion.longest_key(aliases, "for") == "for", "longest key: shortest")
	_check(AliasCompletion.longest_key(aliases, "for/i/x") == "for", "longest key: only one can match with args")
	_check(AliasCompletion.longest_key(aliases, "foribx") == "forib", "longest key: trailing text keeps the longest")
	_check(AliasCompletion.longest_key(aliases, "nope") == "", "longest key: no match")


## Mirrors the provider: keys are stored bare, but the popup and any insert must carry the separator,
## because that is what Godot filters the typed run against.
static func _display_key(key:String) -> String:
	return AliasCompletion.ARG_SEPARATOR + key


static func _test_display_key() -> void:
	_check(_display_key("icon") == "/icon", "display key: key rendered as typed")
	# the guard that catches the whole class of bug - the stored key has no "/" to match against
	var good = AliasCompletion.make_display(_display_key("icon"), "Node2D")
	_check(_is_subsequence("/icon", good), "display key: typed run matches -> %s" % good)
	_check(not _is_subsequence("/icon", AliasCompletion.make_display("icon", "Node2D")),
			"display key: the bare 'icon' key would NOT match")
	# an insert replaces the typed run, so it has to reproduce the separator form too
	_check(AliasCompletion.make_name_insert(_display_key("icon") + "/", "Node2D") == "/icon/Node2D/",
			"display key: insert keeps the separator form")


static func _test_keys_starting_with() -> void:
	var aliases = {"setget": {}, "export": {}, "icon": {}, "iconed": {}}
	# an empty prefix is a prefix of everything, which is what a bare separator relies on
	_check(Array(AliasCompletion.keys_starting_with(aliases, "")) == ["export", "icon", "iconed", "setget"],
			"keys starting with: empty prefix lists all, sorted")
	_check(Array(AliasCompletion.keys_starting_with(aliases, "icon")) == ["icon", "iconed"],
			"keys starting with: narrows")
	_check(Array(AliasCompletion.keys_starting_with(aliases, "SET")) == ["setget"],
			"keys starting with: case-insensitive")
	_check(AliasCompletion.keys_starting_with(aliases, "zzz").is_empty(), "keys starting with: no match")


static func _test_lookup_directions_differ() -> void:
	# the two are opposites, which is exactly why longest_key can't serve the menu
	var aliases = {"setget": {}}
	_check(AliasCompletion.longest_key(aliases, "set") == "", "directions: partial key does not invoke")
	_check(Array(AliasCompletion.keys_starting_with(aliases, "set")) == ["setget"], "directions: partial key browses")
	_check(AliasCompletion.longest_key(aliases, "setgetmy") == "setget", "directions: typed past the key invokes")
	_check(AliasCompletion.keys_starting_with(aliases, "setgetmy").is_empty(),
			"directions: typed past the key does not browse")


static func _test_menu_insert() -> void:
	# an alias that takes arguments re-triggers straight into argument mode
	#_check(AliasCompletion.make_menu_insert("setget") == "/setget/", "menu insert: arguments get the separator")
	## always, so the insert re-triggers - a zero argument alias needs that just as much
	#_check(AliasCompletion.make_menu_insert("icon") == "/icon/", "menu insert: no arguments still gets one")
	# and the row still has to survive the filter, hint and all
	var row = AliasCompletion.make_display(AliasCompletion.ARG_SEPARATOR,
			"setget" + AliasCompletion.make_arg_hint(PackedStringArray(["name", "type"]), 1, 1))
	_check(_is_subsequence("/set", row), "menu insert: partial typing matches the menu row -> %s" % row)


static func _test_array_builder() -> void:
	var res = _collect_fixture()
	var entry:Dictionary = res.aliases.get("array_builder", {})
	_check(entry.get("slots") == 0 and entry.get("required") == 0, "array builder: zero parameters")
	# zero parameters means build_args yields [], and callv([]) is exactly call()
	var call_args = AliasCompletion.build_args(AliasCompletion.split_args(""), entry.required, entry.slots)
	_check(call_args.is_empty(), "array builder: no args to pass -> %s" % [call_args])
	var result = entry.build.callv(call_args)
	_check(result is Array and result.size() == 3, "array builder: raw return -> %s" % [result])
	# the empty element must not become a blank row
	var options = AliasCompletion.builder_options(result)
	_check(options == ["first_row", "second_row"], "array builder: normalised -> %s" % [options])


static func _test_builder_options() -> void:
	var opts = AliasCompletion.builder_options
	_check(opts.call("one") == ["one"], "builder options: a string is a single row")
	# a trailing break would drop the caret onto a blank line after the insert
	_check(opts.call("one\n") == ["one"], "builder options: trailing break stripped")
	_check(opts.call(["a\n", "", "b"]) == ["a", "b"], "builder options: array normalised and emptied")
	_check(opts.call(PackedStringArray(["a", "b"])) == ["a", "b"], "builder options: PackedStringArray")
	# non string elements are still usable rows
	_check(opts.call([1, 2]) == ["1", "2"], "builder options: elements str()'d")
	_check(opts.call(42).is_empty(), "builder options: neither string nor array -> no rows")
	_check(opts.call("").is_empty(), "builder options: empty string -> no rows")


static func _test_arg_text() -> void:
	# a lone separator means the list was opened and nothing supplied, which must read as nothing
	# typed - menu inserts always end in one, so this is what keeps plain aliases alive
	_check(AliasCompletion.arg_text("/") == "", "arg text: lone separator is nothing")
	_check(AliasCompletion.arg_text("/a") == "a", "arg text: separator stripped")
	_check(AliasCompletion.arg_text("") == "", "arg text: nothing typed")
	_check(AliasCompletion.arg_text("extra") == "extra", "arg text: no separator, text is foreign")


## Mirrors the provider: the prefix is the key plus only the arguments the alias consumes.
static func _prefix(key:String, typed:String, slots:int) -> String:
	return AliasCompletion.ARG_SEPARATOR + key + AliasCompletion.split_consumed(typed, slots)[0]


static func _test_split_consumed() -> void:
	var consumed = func(typed, slots): return Array(AliasCompletion.split_consumed(typed, slots))
	# zero slots: the opening separator is consumed, everything after it is excess
	_check(consumed.call("/act", 0) == ["/", "act"], "split consumed: zero slots keeps the separator")
	_check(consumed.call("act", 0) == ["", "act"], "split consumed: zero slots, no separator")
	_check(consumed.call("", 0) == ["", ""], "split consumed: nothing typed")
	_check(consumed.call("/", 0) == ["/", ""], "split consumed: list opened, nothing supplied")
	
	# ALERT this has been changed, I think right
	# every argument the alias takes is consumed, trailing separator included
	_check(consumed.call("/my_var/float", 2) == ["/my_var/float", ""], "split consumed: all arguments")
	_check(consumed.call("/i/_aliases/size/", 3) == ["/i/_aliases/size/", ""], "split consumed: trailing separator")
	# excess beyond the slot count stays out of the prefix
	_check(consumed.call("/my_var/float/extra", 2) == ["/my_var/float/", "extra"], "split consumed: excess left over")

static func _test_prefix_is_contiguous() -> void:
	# the regression this fixes: a space in the prefix meant a long argument run only ever matched as
	# a scattered subsequence, which scores badly enough to drop out of the popup
	var typed_run = "/for/i/_aliases/size/"
	var display = AliasCompletion.make_display(_prefix("for", "/i/_aliases/size/", 3),
			"for i in range(_aliases.size()):")
	_check(display.contains(typed_run), "prefix contiguous: typed run is a SUBSTRING of %s" % display)

	# and the other half: excess must NOT reach the prefix, or a zero argument builder stops
	# narrowing - every icon row would match on the prefix alone
	var icon_prefix = _prefix("icon", "/act", 0)
	_check(icon_prefix == "/icon/", "prefix contiguous: zero slots consume only the separator -> %s" % icon_prefix)
	_check(not icon_prefix.contains("act"), "prefix contiguous: excess stays out so the body must match")
	# "/iconact" and "/icon/act" have to behave the same way
	_check(_prefix("icon", "act", 0) == "/icon", "prefix contiguous: no separator form")


const ICON_INSERT = 'EditorInterface.get_editor_theme().get_icon(&"ActionCopy", &"EditorIcons")'

const ROW_KEYS = ["kind", "display_text", "insert_text", "font_color", "icon", "default_value", "location"]


static func _test_normalize_row() -> void:
	# add_completion_option reads all seven by dot access, so a partial dict has to come back whole
	var filled = AliasCompletion.normalize_row({&"insert_text": ICON_INSERT})
	for key in ROW_KEYS:
		_check(filled.has(key), "normalize row: '%s' present" % key)
	_check(filled.display_text == ICON_INSERT, "normalize row: display falls back to insert")
	_check(AliasCompletion.normalize_row({&"display_text": "only"}).insert_text == "only",
			"normalize row: insert falls back to display")
	# the builder's own values win over every default
	var explicit = AliasCompletion.normalize_row({
		&"display_text": "ActionCopy", &"insert_text": ICON_INSERT, &"location": 7,
	})
	_check(explicit.display_text == "ActionCopy" and explicit.insert_text == ICON_INSERT,
			"normalize row: display and insert kept apart")
	_check(explicit.location == 7, "normalize row: supplied key not overwritten")
	_check(AliasCompletion.normalize_row({}).is_empty(), "normalize row: nothing to show -> dropped")
	_check(AliasCompletion.normalize_row({&"insert_text": "a\n"}).insert_text == "a",
			"normalize row: trailing break stripped")


static func _test_builder_dict_rows() -> void:
	var opts = AliasCompletion.builder_options
	var row = {&"display_text": "ActionCopy", &"insert_text": ICON_INSERT}
	# a bare dict is a single row, same as a bare string
	var single = opts.call(row)
	_check(single.size() == 1 and single[0] is Dictionary, "builder dict: bare dict -> one row")
	# strings and dicts can be mixed in one array
	var mixed = opts.call(["plain", row, ""])
	_check(mixed.size() == 2, "builder dict: mixed array -> %s rows" % mixed.size())
	_check(mixed[0] is String and mixed[1] is Dictionary, "builder dict: element types preserved")
	_check(opts.call([{}]).is_empty(), "builder dict: empty row dropped")


static func _test_dict_row_display_separation() -> void:
	# the whole point: the popup shows the short name while the long expression is what gets inserted
	var row = AliasCompletion.normalize_row({&"display_text": "ActionCopy", &"insert_text": ICON_INSERT})
	var display = AliasCompletion.make_display("/iconed", row.display_text)
	_check(display == "(/iconed) ActionCopy", "dict row: short display -> %s" % display)
	_check(row.insert_text == ICON_INSERT, "dict row: insert stays the long expression")
	_check(_is_subsequence("/iconedaction", display), "dict row: typed run matches the short display")
	# a string row still has display and insert identical, unchanged from before
	var plain = AliasCompletion.builder_options("one_liner")
	_check(plain == ["one_liner"], "dict row: string return unchanged -> %s" % [plain])


static func _collect_fixture() -> Dictionary:
	var out := {}
	var errors = AliasCompletion.collect_script_aliases(FIXTURE_SCRIPT, out)
	return {"aliases": out, "errors": errors}


static func _test_script_constants() -> void:
	var res = _collect_fixture()
	_check(res.errors.is_empty(), "script constants: no errors, got %s" % [res.errors])
	_check(_options(res, "single") == ["one_option"], "script constants: string -> one option")
	_check(_options(res, "several") == ["first", "second"], "script constants: array -> several options")
	_check(_options(res, "with_empty") == ["kept"], "script constants: empty entry dropped")


static func _test_script_builders() -> void:
	var res = _collect_fixture()
	# the signature is the contract: parameter count is the slot count, defaults are not required
	var two:Dictionary = res.aliases.get("two_slots", {})
	_check(two.get("build") is Callable, "script builders: static func -> callable")
	_check(two.get("slots") == 2 and two.get("required") == 2, "script builders: two required slots")
	var one:Dictionary = res.aliases.get("one_required", {})
	_check(one.get("slots") == 2 and one.get("required") == 1, "script builders: default makes a slot optional")
	# slots is derived from the names now, so the two can never disagree
	_check(one.get("slots") == one.get("arg_names").size(), "script builders: slots is the name count")
	var none:Dictionary = res.aliases.get("no_args", {})
	_check(none.get("slots") == 0 and none.get("required") == 0, "script builders: no parameters")


static func _test_script_skips() -> void:
	var res = _collect_fixture()
	# these are the rules that keep helpers and data out of the popup, with no opt-out marker
	_check(not res.aliases.has("DATA"), "script skips: Dictionary constant is data, not an alias")
	_check(not res.aliases.has("NUMBER"), "script skips: non string/array constant")
	_check(not res.aliases.has("_Preloaded"), "script skips: preload constant")
	_check(not res.aliases.has("_helper_const"), "script skips: underscore constant")
	_check(not res.aliases.has("_helper_builder"), "script skips: underscore func")
	# there is no hidden tier any more - a name is either an alias or a helper
	_check(res.aliases.has("plain_const"), "script skips: ordinary constant is collected")
	_check(res.aliases.has("array_builder"), "script skips: ordinary func is collected")
	_check(not res.aliases.has("not_static"), "script skips: instance method")
	_check(not res.aliases.has("all_empty"), "script skips: array with no usable entries")


## The parameter names are read off the real signature, which is what both hints are built from.
static func _test_script_arg_names() -> void:
	var res = _collect_fixture()
	var names = func(key): return Array(res.aliases.get(key, {}).get("arg_names", PackedStringArray()))
	_check(names.call("two_slots") == ["a", "b"], "script arg names: both -> %s" % [names.call("two_slots")])
	_check(names.call("one_required") == ["a", "b"], "script arg names: a default is still a parameter")
	_check(names.call("no_args") == [], "script arg names: none")
	# a const has no signature, so it must still answer the key the menu reads
	_check(names.call("single") == [], "script arg names: a const has none")
	# and the hint the browse row shows comes straight off them
	var entry:Dictionary = res.aliases.get("one_required", {})
	_check(AliasCompletion.make_arg_hint(entry.arg_names, entry.slots, entry.required) == "(a/?:b)",
			"script arg names: feed the browse hint -> %s" % AliasCompletion.make_arg_hint(entry.arg_names, entry.slots, entry.required))


static func _test_build_args() -> void:
	var split = AliasCompletion.split_args
	# a closing separator leaves an empty tail; passing it would beat the parameter's default
	_check(AliasCompletion.build_args(split.call("/my_var/"), 1, 2) == ["my_var"],
			"build args: trailing empty dropped so the default applies")
	_check(AliasCompletion.build_args(split.call("/my_var/float"), 1, 2) == ["my_var", "float"],
			"build args: both supplied")
	# a required parameter must never be left unfilled, or callv errors
	_check(AliasCompletion.build_args(split.call(""), 2, 2) == [AliasCompletion.PLACEHOLDER, AliasCompletion.PLACEHOLDER],
			"build args: required parameters padded")
	_check(AliasCompletion.build_args(split.call("/a/b/c"), 1, 2) == ["a", "b"],
			"build args: extras dropped so callv can't overflow")
	# resolve_arg still applies per element
	_check(AliasCompletion.build_args(split.call("/_/float"), 2, 2) == ["", "float"],
			"build args: lone underscore still blanks a slot")


static func _test_builder_round_trip() -> void:
	var res = _collect_fixture()
	var entry:Dictionary = res.aliases.get("one_required", {})
	var call_it = func(typed:String):
		return entry.build.callv(AliasCompletion.build_args(
				AliasCompletion.split_args(typed), entry.required, entry.slots))
	_check(call_it.call("/a/b") == "a|b", "builder round trip: both arguments")
	_check(call_it.call("/a/") == "a|defaulted", "builder round trip: default fills the open slot")
	_check(call_it.call("") == "%s|defaulted" % AliasCompletion.PLACEHOLDER,
			"builder round trip: nothing typed -> padded and defaulted")


static func _test_apply_indent() -> void:
	var text = "func _ready() -> void:\n\tpass\n\nvar a = 1"
	var indented = AliasCompletion.apply_indent(text, "\t")
	# first line rides the caret's existing indent; blank lines stay blank rather than padded
	_check(indented == "func _ready() -> void:\n\t\tpass\n\n\tvar a = 1",
			"apply indent: %s" % [JSON.stringify(indented)])


static func _test_apply_indent_no_op() -> void:
	_check(AliasCompletion.apply_indent("single", "\t") == "single", "apply indent: single line untouched")
	_check(AliasCompletion.apply_indent("a\nb", "") == "a\nb", "apply indent: empty indent untouched")


static func _test_line_indent() -> void:
	_check(AliasCompletion.get_line_indent("\t\tmykey") == "\t\t", "line indent: tabs")
	_check(AliasCompletion.get_line_indent("    mykey") == "    ", "line indent: spaces")
	_check(AliasCompletion.get_line_indent("mykey") == "", "line indent: none")


static func _test_shipped_script_collects() -> void:
	var path = AliasCompletion.DEFAULT_ALIAS_DIR.path_join(AliasCompletion.ALIAS_SCRIPT_NAME)
	if not FileAccess.file_exists(path):
		return # dev repo only, absent in a released plugin
	var script = load(path)
	_check(script is Script, "shipped script: loads as a script")
	if not script is Script:
		return
	var out := {}
	var errors = AliasCompletion.collect_script_aliases(script, out)
	_check(errors.is_empty(), "shipped script: no errors, got %s" % [errors])
	# the motivating case: the default value is derived from the type, so there is no third argument
	var entry:Dictionary = out.get("setget", {})
	_check(entry.get("build") is Callable, "shipped script: setget is a builder")
	_check(entry.get("slots") == 2 and entry.get("required") == 1, "shipped script: setget arity from the signature")
	var built = str(entry.build.callv(AliasCompletion.build_args(
			AliasCompletion.split_args("/my_var/float"), entry.required, entry.slots)))
	_check(built.begins_with("var my_var:float = 0.0:"), "shipped script: derived default -> %s" % built.get_slice("\n", 0))
	var defaulted = str(entry.build.callv(AliasCompletion.build_args(
			AliasCompletion.split_args("/my_var/"), entry.required, entry.slots)))
	_check(defaulted.begins_with("var my_var:int = 0:"), "shipped script: type default -> %s" % defaulted.get_slice("\n", 0))
	_check(Array(entry.get("arg_names")) == ["name", "type"],
			"shipped script: parameter names read for the hints -> %s" % [entry.get("arg_names")])
	# the data table and the helper must not have become aliases
	_check(not out.has("DEFAULTS"), "shipped script: DEFAULTS stays data")
	_check(not out.has("_default_for"), "shipped script: helper stays hidden")
	_check(out.has("icon") and out.has("edicon"), "shipped script: builders reachable without an underscore")
	# the aliases ported off the old yml file
	_check(out.get("example_arr", {}).get("options", []).size() == 2, "shipped script: mykey has two options")
	_check(out.has("ready") and out.get("ready", {}).get("slots") == 0, "shipped script: ready is a plain const")
	_check(out.get("fi", {}).get("slots") == 1, "shipped script: fori takes one argument")


static func _check(condition:bool, message:String) -> void:
	if condition:
		_passed += 1
	else:
		_failures.append(message)
