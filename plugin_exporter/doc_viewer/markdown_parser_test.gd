@tool
extends EditorScript

## Tests for the doc viewer's markdown parser — block segmentation and the inline-to-BBCode pass.
## The parser is static and pure, so the whole suite runs headless with no scene and no fixtures.
##
##     load("res://tests/plugin_exporter/doc_viewer/markdown_parser_test.gd").run_tests()

const Parser = preload("res://addons/plugin_exporter/src/components/doc_viewer/markdown_parser.gd")

## Base size the bbcode assertions are written against; heading sizes are ratios of it.
const BASE = 16

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_fences()
	_test_images_and_rules()
	_test_headings()
	_test_emphasis()
	_test_links_and_escaping()
	_test_lists_and_quotes()
	_test_first_heading()
	_test_no_marker_collision()
	_test_tag_balance()

	var output:Array[String] = []
	output.append("markdown_parser: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## The info string names the fence's language and must not survive into the code itself.
static func _test_fences() -> void:
	var blocks = Parser.parse("intro\n\n```gdscript\nvar x = 1\n```\n\nouttro")
	_check("fence: block count", blocks.size(), 3)
	_check("fence: prose before", blocks[0][Parser.KEY_TYPE], Parser.TYPE_TEXT)
	_check("fence: code type", blocks[1][Parser.KEY_TYPE], Parser.TYPE_CODE)
	_check("fence: lang", blocks[1][Parser.KEY_LANG], "gdscript")
	_check("fence: body excludes the fences", blocks[1][Parser.KEY_TEXT], "var x = 1")
	_check("fence: prose after", blocks[2][Parser.KEY_TEXT], "outtro")

	var no_lang = Parser.parse("```\nplain\n```")
	_check("fence: no info string", no_lang[0][Parser.KEY_LANG], "")

	var tilde = Parser.parse("~~~yaml\nkey: value\n~~~")
	_check("fence: tilde lang", tilde[0][Parser.KEY_LANG], "yaml")
	_check("fence: tilde body", tilde[0][Parser.KEY_TEXT], "key: value")

	# A backtick run inside a longer fence is body text, not the close.
	var nested = Parser.parse("````\n```\ninner\n````")
	_check("fence: longer run closes", nested.size(), 1)
	_check("fence: shorter run is body", nested[0][Parser.KEY_TEXT], "```\ninner")

	# An unterminated fence renders as code rather than swallowing the rest of the doc.
	var unterminated = Parser.parse("before\n\n```\nvar x = 1\nvar y = 2")
	_check("fence: unterminated count", unterminated.size(), 2)
	_check("fence: unterminated is code", unterminated[1][Parser.KEY_TYPE], Parser.TYPE_CODE)
	_check("fence: unterminated body", unterminated[1][Parser.KEY_TEXT], "var x = 1\nvar y = 2")

	_check("fence: blank lines around blocks dropped", Parser.parse("\n\ntext\n\n").size(), 1)


static func _test_images_and_rules() -> void:
	var blocks = Parser.parse("![a shot](images/shot.png)")
	_check("image: type", blocks[0][Parser.KEY_TYPE], Parser.TYPE_IMAGE)
	_check("image: src", blocks[0][Parser.KEY_SRC], "images/shot.png")
	_check("image: alt", blocks[0][Parser.KEY_ALT], "a shot")

	var titled = Parser.parse('![](shot.png "hover")')
	_check("image: title dropped", titled[0][Parser.KEY_SRC], "shot.png")

	# Only a standalone image becomes a block - one inside a sentence stays in the prose.
	var inline = Parser.parse("see ![a shot](shot.png) here")
	_check("image: inline stays prose", inline[0][Parser.KEY_TYPE], Parser.TYPE_TEXT)

	var ruled = Parser.parse("above\n\n---\n\nbelow")
	_check("rule: block count", ruled.size(), 3)
	_check("rule: type", ruled[1][Parser.KEY_TYPE], Parser.TYPE_RULE)
	_check("rule: asterisks", Parser.parse("a\n\n***\n\nb")[1][Parser.KEY_TYPE], Parser.TYPE_RULE)


static func _test_headings() -> void:
	for level in range(1, 7):
		var text = Parser.to_bbcode("#".repeat(level) + " Title", BASE)
		var expected = "[font_size=%d][b]Title[/b][/font_size]" % Parser.heading_size(level, BASE)
		_check("heading: level %d" % level, text, expected)

	_check("heading: h1 is the largest", Parser.heading_size(1, BASE) > Parser.heading_size(2, BASE), true)
	_check("heading: sizes track the base", Parser.heading_size(1, 32) > Parser.heading_size(1, 16), true)
	_check("heading: seven hashes is not a heading", Parser.to_bbcode("####### x", BASE).contains("font_size"), false)
	_check("heading: closing hashes trimmed", Parser.to_bbcode("## Title ##", BASE).contains("[b]Title[/b]"), true)

	# A setext underline turns the line above it into a heading.
	var setext = Parser.parse("Title\n=====\n\nbody")
	_check("heading: setext h1", setext[0][Parser.KEY_TEXT], "# Title\n\nbody")
	_check("heading: setext h2", Parser.parse("Title\n---")[0][Parser.KEY_TEXT], "## Title")
	# The same dashes with no line above them are a rule, not a heading.
	_check("heading: dashes alone are a rule", Parser.parse("---")[0][Parser.KEY_TYPE], Parser.TYPE_RULE)


static func _test_emphasis() -> void:
	_check("emphasis: bold", Parser.to_bbcode("a **b** c", BASE), "a [b]b[/b] c")
	_check("emphasis: bold underscores", Parser.to_bbcode("a __b__ c", BASE), "a [b]b[/b] c")
	_check("emphasis: italic", Parser.to_bbcode("a *b* c", BASE), "a [i]b[/i] c")
	_check("emphasis: strike", Parser.to_bbcode("a ~~b~~ c", BASE), "a [s]b[/s] c")
	_check("emphasis: triple run nests cleanly", Parser.to_bbcode("***b***", BASE), "[b][i]b[/i][/b]")
	_check("emphasis: code span", Parser.to_bbcode("call `do_it()` now", BASE), "call [code]do_it()[/code] now")

	# Snake_case is everywhere in this repo's docs and must not read as emphasis.
	_check("emphasis: snake_case untouched", Parser.to_bbcode("my_var_name", BASE), "my_var_name")
	# Nothing inside a code span is markdown.
	_check("emphasis: not applied in code", Parser.to_bbcode("`a_b_c **d**`", BASE), "[code]a_b_c **d**[/code]")


static func _test_links_and_escaping() -> void:
	_check("link: basic", Parser.to_bbcode("[docs](other.md)", BASE), "[url=other.md]docs[/url]")
	_check("link: emphasis in label", Parser.to_bbcode("[**docs**](x.md)", BASE), "[url=x.md][b]docs[/b][/url]")
	_check("link: url", Parser.to_bbcode("[site](https://a.b/c)", BASE), "[url=https://a.b/c]site[/url]")
	_check("link: inline image falls back to alt", Parser.to_bbcode("see ![shot](a.png)", BASE), "see shot")

	# A literal bracket must not read as BBCode once it reaches the label.
	_check("escape: bare bracket", Parser.to_bbcode("array[0]", BASE), "array[lb]0]")
	_check("escape: bbcode in prose", Parser.to_bbcode("[b]not bold[/b]", BASE), "[lb]b]not bold[lb]/b]")
	_check("escape: bracket in code span", Parser.to_bbcode("`a[0]`", BASE), "[code]a[lb]0][/code]")


static func _test_lists_and_quotes() -> void:
	_check("list: bullet", Parser.to_bbcode("- one", BASE), "[indent]• one[/indent]")
	_check("list: asterisk bullet", Parser.to_bbcode("* one", BASE), "[indent]• one[/indent]")
	_check("list: ordered keeps its number", Parser.to_bbcode("2. two", BASE), "[indent]2. two[/indent]")
	_check("list: nested indents twice", Parser.to_bbcode("  - deep", BASE), "[indent][indent]• deep[/indent][/indent]")
	_check("list: emphasis inside item", Parser.to_bbcode("- **a**", BASE), "[indent]• [b]a[/b][/indent]")
	_check("quote: single", Parser.to_bbcode("> quoted", BASE), "[indent][i]quoted[/i][/indent]")
	_check("quote: nested", Parser.to_bbcode("> > deep", BASE), "[indent][indent][i]deep[/i][/indent][/indent]")


static func _test_first_heading() -> void:
	_check("title: from heading", Parser.first_heading("# Export Settings"), "Export Settings")
	_check("title: level does not matter", Parser.first_heading("### Deep"), "Deep")
	_check("title: markers stripped", Parser.first_heading("# The **big** `one`"), "The big one")
	_check("title: link label kept", Parser.first_heading("# [Home](i.md)"), "Home")
	_check("title: none", Parser.first_heading("just prose"), "")


## The inline pass once substituted finished spans back into the text behind index markers, and
## the markers collided with any digit on the line - mangling urls and unbalancing the bbcode.
## Converted spans are kept out of the text entirely now, so a document cannot collide with them.
static func _test_no_marker_collision() -> void:
	_check("collision: digit beside a link", Parser.to_bbcode("v1.0 uses [api](a.md) on 8080", BASE),
		"v1.0 uses [url=a.md]api[/url] on 8080")
	_check("collision: digit beside a code span", Parser.to_bbcode("run `go` 10 times", BASE),
		"run [code]go[/code] 10 times")
	_check("collision: digits inside the url", Parser.to_bbcode("[ref](https://github.com/brohd11/x)", BASE),
		"[url=https://github.com/brohd11/x]ref[/url]")
	_check("collision: digits inside a code span", Parser.to_bbcode("`v1 and v0`", BASE),
		"[code]v1 and v0[/code]")
	_check("collision: two links on one line", Parser.to_bbcode("[a](1.md) and [b](2.md)", BASE),
		"[url=1.md]a[/url] and [url=2.md]b[/url]")


## Unbalanced output makes RichTextLabel pop tags it never pushed, which surfaces as engine errors
## rather than anything visible in the text - so balance is asserted here instead.
static func _test_tag_balance() -> void:
	var corpus:Array[String] = [
		"# Heading with `code` and [a link](x.md)",
		" - [EditorNodeRef](https://github.com/brohd11/Godot-Editor-Node-Ref) -> res://addons/addon_lib/editor_node_ref",
		"### **Be sure to download the zip in releases, not the repo source code.**",
		"> quoted **bold** with [link](y.md) and 2 digits",
		"  - nested item with `a[0]` and *emphasis*",
		"literal [brackets] and [/url] and [b] in prose",
		"1. ordered with ![inline image](shot.png)",
		"trailing ** star and _ underscore and ` tick",
	]
	for line in corpus:
		var bbcode = Parser.to_bbcode(line, BASE)
		_check("balance: " + line.substr(0, 34), _unbalanced_tag(bbcode), "")


## The first tag that closes without an open one, or that is left open at the end. Empty when the
## bbcode is balanced.
static func _unbalanced_tag(bbcode:String) -> String:
	var stack:Array[String] = []
	var re = RegEx.create_from_string(r"\[(/?)([a-zA-Z_]+)[^\]]*\]")
	for m in re.search_all(bbcode):
		var name = m.get_string(2)
		if name in ["lb", "rb", "img"]:
			continue
		if m.get_string(1) == "":
			stack.append(name)
			continue
		if stack.is_empty():
			return "closed [/%s] with nothing open" % name
		var open = stack.pop_back()
		if open != name:
			return "[%s] closed by [/%s]" % [open, name]
	if not stack.is_empty():
		return "left open: " + str(stack)
	return ""


# --- harness -----------------------------------------------------------------------------

static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
		return
	_failures.append("%s — expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)])
