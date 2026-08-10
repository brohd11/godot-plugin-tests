@tool
extends EditorScript

## Tests for git_util.gd's blame parser.
##
## parse_blame() is a pure function over captured `git blame --porcelain` output, so nothing here
## spawns git. fixtures/blame_porcelain.txt is real output for this plugin's own plugin.gd — 84
## lines over 8 commits, with a `boundary` header on the oldest and groups both with and without a
## line count, which between them cover the whole format.
##
## The one thing worth stating outright: porcelain emits a commit's header only the *first* time
## that commit appears, so the later groups of the same commit are a bare sha line. A parser that
## expects a header per group loses every field on them, and the fixture would still look parsed.

const GitUtil = preload("res://addons/addon_lib/brohd/alib_editor/misc/git_service/git_util.gd")

const FIXTURES = "res://tests/brohd/git/fixtures/"
const REPO = "res://"

## The oldest commit in the fixture, and the one carrying `boundary`
const INIT_SHA = "7fc9c44829706fe7e6c9f1d42d89587ce365405b"
## The commit owning line 4, the first group after the init commit's opening run of three
const SECOND_SHA = "667acc7c3a3fc3cd273875cb90c6083bd16af9f9"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_line_count()
	_test_distinct_commits()
	_test_group_shares_one_header()
	_test_commit_fields()
	_test_boundary_does_not_corrupt()
	_test_content_lines_are_not_headers()
	_test_empty_input()
	_test_blame_args()
	_test_log_record_shape()
	_test_relative_time()
	_test_relative_time_edges()

	var output:Array[String] = []
	output.append("git_blame: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	var res = run_tests()
	print("\n".join(res.output))


static func _read(file_name:String) -> String:
	var text = FileAccess.get_file_as_string(FIXTURES + file_name)
	if text.is_empty():
		_failures.append("fixture missing or empty: " + file_name)
	return text


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("%s\n          expected: %s\n          actual:   %s" % [label, expected, actual])


# --- the fixture ---------------------------------------------------------------------------------

## One entry per line of the blamed file, indexed rather than appended — the assertion that matters
## is the size, since a parser that missed the bare sha lines would come up short by exactly them.
static func _test_line_count() -> void:
	var blame = GitUtil.parse_blame(_read("blame_porcelain.txt"))
	var lines:PackedStringArray = blame[GitUtil.Keys.BLAME_LINES]

	_check("one sha per line", lines.size(), 84)
	_check("no line left unattributed", lines.count(""), 0)


static func _test_distinct_commits() -> void:
	var blame = GitUtil.parse_blame(_read("blame_porcelain.txt"))
	_check("commits are deduplicated", blame[GitUtil.Keys.COMMITS].size(), 8)


## The opening group is "…405b 1 1 3": three lines of one commit, whose second and third arrive as a
## bare sha with no count and no header at all.
static func _test_group_shares_one_header() -> void:
	var blame = GitUtil.parse_blame(_read("blame_porcelain.txt"))
	var lines:PackedStringArray = blame[GitUtil.Keys.BLAME_LINES]

	_check("group line 1", lines[0], INIT_SHA)
	_check("group line 2, header omitted", lines[1], INIT_SHA)
	_check("group line 3, header omitted", lines[2], INIT_SHA)
	_check("the group ends where the next commit starts", lines[3], SECOND_SHA)


static func _test_commit_fields() -> void:
	var commits:Dictionary = GitUtil.parse_blame(_read("blame_porcelain.txt"))[GitUtil.Keys.COMMITS]
	var init:Dictionary = commits[INIT_SHA]

	_check("author", init[GitUtil.Keys.AUTHOR], "brohd")
	_check("mail is unwrapped", init[GitUtil.Keys.AUTHOR_MAIL], "brohdielr@proton.me")
	_check("author time is an int", init[GitUtil.Keys.AUTHOR_TIME], 1784329953)
	_check("timezone", init[GitUtil.Keys.AUTHOR_TZ], "-0700")
	_check("summary is the subject", init[GitUtil.Keys.SUBJECT], "init commit")
	_check("full hash", init[GitUtil.Keys.FULL_HASH], INIT_SHA)
	_check("short hash", init[GitUtil.Keys.HASH], "7fc9c44")

	# a subject with commas and no quoting — `summary` is the rest of the line, not a field to split
	_check("subject keeps its punctuation", commits[SECOND_SHA][GitUtil.Keys.SUBJECT],
		"fix mini map draw alignments, move panel files into git view")


## `boundary` is the one header with no value. Splitting it as `key value` yields a single piece,
## which must fall through rather than land somewhere as an empty string.
static func _test_boundary_does_not_corrupt() -> void:
	var commits:Dictionary = GitUtil.parse_blame(_read("blame_porcelain.txt"))[GitUtil.Keys.COMMITS]
	# the fixture writes `boundary` between `summary` and `filename`, so a mishandled one takes the
	# subject with it
	_check("a boundary commit keeps its subject", commits[INIT_SHA][GitUtil.Keys.SUBJECT], "init commit")
	_check("a boundary commit keeps its author", commits[INIT_SHA][GitUtil.Keys.AUTHOR], "brohd")


# --- the format's traps --------------------------------------------------------------------------

## The content line is source code, and source code can say anything — including a line that reads
## exactly like a header or a group start. The leading tab is the only thing separating them.
static func _test_content_lines_are_not_headers() -> void:
	var text = "\n".join([
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1",
		"author real",
		"summary real subject",
		"\tauthor fake",
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2 2 1",
		"author other",
		"summary other subject",
		"\tcccccccccccccccccccccccccccccccccccccccc 9 9 9",
	])

	var blame = GitUtil.parse_blame(text)
	var lines:PackedStringArray = blame[GitUtil.Keys.BLAME_LINES]
	var commits:Dictionary = blame[GitUtil.Keys.COMMITS]

	_check("a content line reading as a header is content", commits.size(), 2)
	_check("...and does not overwrite the field it names",
		commits["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"][GitUtil.Keys.AUTHOR], "real")
	_check("a content line reading as a group start is content", lines.size(), 2)
	_check("...and the line it would have claimed is not there", lines[1],
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")


## An empty repo, a file with no history, or a spawn that failed — get_blame hands the empty string
## straight through rather than special casing it.
static func _test_empty_input() -> void:
	var blame = GitUtil.parse_blame("")
	_check("no commits", blame[GitUtil.Keys.COMMITS].size(), 0)
	_check("no lines", blame[GitUtil.Keys.BLAME_LINES].size(), 0)


## The same pathname trap as build_show_args: a `:(literal)` prefix here would have git look for a
## file named after the prefix.
static func _test_blame_args() -> void:
	_check("blame args", GitUtil.build_blame_args("HEAD", REPO, "res://src/a.gd"),
		["blame", "--porcelain", "HEAD", "--", "src/a.gd"])
	_check("blame args carry no pathspec magic",
		GitUtil.build_blame_args("HEAD", REPO, "res://a b.gd").has(GitUtil.PATHSPEC_LITERAL + "a b.gd"), false)


## A blame commit is handed to the same rows that render a `git log` record, so it has to carry the
## same keys. Checked against parse_log's own output rather than a written out list, so the two
## cannot drift apart quietly.
static func _test_log_record_shape() -> void:
	var record = GitUtil.LOG_SEP.join(["abc1234", "subject", "name", "2 days ago", "abc1234def", ""])
	var log_record = GitUtil.parse_log(record)
	var blame_commit:Dictionary = GitUtil.parse_blame(_read("blame_porcelain.txt"))[GitUtil.Keys.COMMITS][INIT_SHA]

	if log_record.is_empty():
		_failures.append("parse_log returned nothing to compare against")
		return

	for key in log_record[0]:
		_check("a blame commit carries %s" % key, blame_commit.has(key), true)


# --- relative time -------------------------------------------------------------------------------

## The buckets are git's own, which is why they are not one unit of the next size up: days run to 14
## before weeks start, so "1 week ago" is unreachable — in git too.
static func _test_relative_time() -> void:
	const NOW = 1_000_000_000

	var cases = [
		[1, "1 second ago"],
		[30, "30 seconds ago"],
		[89, "89 seconds ago"],
		[90, "2 minutes ago"], # rounds, as git does
		[GitUtil.HOUR, "60 minutes ago"],
		[2 * GitUtil.HOUR, "2 hours ago"],
		[2 * GitUtil.DAY, "2 days ago"],
		[20 * GitUtil.DAY, "3 weeks ago"],
		[100 * GitUtil.DAY, "3 months ago"],
		[400 * GitUtil.DAY, "1 year ago"],
		[800 * GitUtil.DAY, "2 years ago"],
	]

	for entry in cases:
		_check("%d seconds ago reads as" % entry[0],
			GitUtil.format_relative_time(NOW - entry[0], NOW), entry[1])


static func _test_relative_time_edges() -> void:
	const NOW = 1_000_000_000

	_check("no timestamp at all", GitUtil.format_relative_time(0, NOW), "")
	_check("just now", GitUtil.format_relative_time(NOW, NOW), "0 seconds ago")
	# a skewed clock, or an author date ahead of its commit date
	_check("ahead of the clock", GitUtil.format_relative_time(NOW + 60, NOW), "in the future")
