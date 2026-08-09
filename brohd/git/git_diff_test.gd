@tool
extends EditorScript

## Tests for git_diff.gd.
##
## Every function under test is pure, so nothing here spawns git — same property the git_util suite
## has, and the reason both run headless in a second.
##
## Two of these matter more than the rest. The contract test feeds *git's own* parsed hunks into
## hunks_to_markers, which only works if the shape git_diff emits really is parse_patch's. The round
## trip test compares diff_lines against real `git diff --no-index` output captured in
## fixtures/diff_expected.patch — it is the only thing here that can catch the whole algorithm being
## subtly wrong in a way that is self consistent.

const GitUtil = preload("res://addons/addon_lib/brohd/alib_editor/misc/git_service/git_util.gd")
const GitDiff = preload("res://addons/addon_lib/brohd/alib_editor/misc/git_service/git_diff.gd")

const FIXTURES = "res://tests/brohd/git/fixtures/"
const REPO = "res://" # the fixtures' notional repo root, so keys read as res://<path>

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_to_lines()
	_test_crlf()
	_test_identical()
	_test_round_trip_against_git()
	_test_single_modification()
	_test_insert_into_empty()
	_test_delete_at_eof()
	_test_hunk_grouping()
	_test_empty_sides()
	_test_trailing_newline()
	_test_markers_from_git_hunks()
	_test_markers()
	_test_markers_out_of_range()
	_test_fill_markers()
	_test_edit_distance_budget()

	var output:Array[String] = []
	output.append("git_diff: %d passed, %d failed" % [_passed, _failures.size()])
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


## The origins of a hunk's lines as one string — "  -+ " reads at a glance where a line by line dump
## of dictionaries does not.
static func _origins(hunk:Dictionary) -> String:
	var out = ""
	for line:Dictionary in hunk[GitUtil.Keys.LINES]:
		out += line[GitUtil.Keys.ORIGIN]
	return out


static func _spans(hunk:Dictionary) -> Array:
	return [
		hunk[GitUtil.Keys.OLD_START], hunk[GitUtil.Keys.OLD_COUNT],
		hunk[GitUtil.Keys.NEW_START], hunk[GitUtil.Keys.NEW_COUNT],
	]


# --- normalising -------------------------------------------------------------------------------

static func _test_to_lines() -> void:
	# the trailing empty string is the point: it is the empty last line CodeEdit shows for a file
	# that ends in a newline, and dropping it would make every such file differ from its own buffer
	_check("a trailing newline leaves an empty last line",
		GitDiff.to_lines("a\nb\n"), PackedStringArray(["a", "b", ""]))
	_check("no trailing newline, no empty last line",
		GitDiff.to_lines("a\nb"), PackedStringArray(["a", "b"]))
	_check("empty text is one empty line", GitDiff.to_lines(""), PackedStringArray([""]))


static func _test_crlf() -> void:
	# `git show` hands back the raw blob, so a repo committed with CRLF arrives with a \r on every
	# line where the editor's buffer has none. Without normalising, every file in such a repo would
	# diff as entirely changed — the loudest possible way to be wrong.
	_check("CRLF blob against an LF buffer is not a diff",
		GitDiff.diff_lines(GitDiff.to_lines("a\r\nb\r\n"), GitDiff.to_lines("a\nb\n")), [])
	_check("a lone CR is a line break too",
		GitDiff.to_lines("a\rb"), PackedStringArray(["a", "b"]))


# --- diffing -----------------------------------------------------------------------------------

static func _test_identical() -> void:
	_check("identical files do not diff",
		GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\n"), GitDiff.to_lines("a\nb\nc\n")), [])


## The one test that can catch the algorithm being wrong in a way that agrees with itself: the
## expected side is real `git diff --no-index` output, not a hand written guess.
static func _test_round_trip_against_git() -> void:
	var patch = GitUtil.parse_patch(_read("diff_expected.patch"), REPO)
	# --no-index names the two files it was given, so the patch keys on the "new" one
	var expected:Array = patch.get("res://diff_buffer.txt", {}).get(GitUtil.Keys.HUNKS, [])
	_check("git's patch parsed to one hunk", expected.size(), 1)
	if expected.is_empty():
		return

	var actual = GitDiff.diff_lines(
		GitDiff.to_lines(_read("diff_head.txt")), GitDiff.to_lines(_read("diff_buffer.txt")))
	_check("we find one hunk too", actual.size(), 1)
	if actual.is_empty():
		return

	# HEADING is the one field that cannot match: git guesses the enclosing function and writes it
	# after the @@, we leave it empty. It is not diff content — nothing reads it to place a line —
	# so the shapes are still interchangeable. Everything else must be identical.
	_check("git's heading is not ours", expected[0][GitUtil.Keys.HEADING], "extends Node")
	_check("our heading is empty", actual[0][GitUtil.Keys.HEADING], "")

	var git_hunk:Dictionary = expected[0].duplicate()
	git_hunk[GitUtil.Keys.HEADING] = ""
	_check("our hunk is git's hunk", actual[0], git_hunk)


static func _test_single_modification() -> void:
	var old_text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
	var new_text = "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n10\n"
	var hunks = GitDiff.diff_lines(GitDiff.to_lines(old_text), GitDiff.to_lines(new_text))

	_check("one line changed is one hunk", hunks.size(), 1)
	if hunks.is_empty():
		return

	# three lines of context each side of a one line change, on both sides of the file
	_check("modification spans", _spans(hunks[0]), [2, 7, 2, 7])
	_check("modification origins", _origins(hunks[0]), "   -+   ")
	_check("removal comes before addition", hunks[0][GitUtil.Keys.LINES][3],
		{GitUtil.Keys.ORIGIN: "-", GitUtil.Keys.TEXT: "5"})
	_check("addition follows it", hunks[0][GitUtil.Keys.LINES][4],
		{GitUtil.Keys.ORIGIN: "+", GitUtil.Keys.TEXT: "FIVE"})


static func _test_insert_into_empty() -> void:
	var hunks = GitDiff.diff_lines(PackedStringArray(), GitDiff.to_lines("a\nb\nc"))
	_check("filling an empty file is one hunk", hunks.size(), 1)
	if hunks.is_empty():
		return

	# git's zero count rule: "@@ -0,0 +1,3 @@". There is no old line 1 to point at, so the start
	# names the line before the change — of which there are none, hence 0.
	_check("insert into empty spans", _spans(hunks[0]), [0, 0, 1, 3])
	_check("insert into empty origins", _origins(hunks[0]), "+++")


static func _test_delete_at_eof() -> void:
	var hunks = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc"), GitDiff.to_lines("a\nb"))
	_check("truncating is one hunk", hunks.size(), 1)
	if hunks.is_empty():
		return
	_check("delete at eof spans", _spans(hunks[0]), [1, 3, 1, 2])
	_check("delete at eof origins", _origins(hunks[0]), "  -")


static func _test_hunk_grouping() -> void:
	# two changes with 2 lines between them: their context overlaps, so git writes one hunk
	var near_old = GitDiff.to_lines("a\nb\nc\nd\ne\nf\ng\n")
	var near_new = GitDiff.to_lines("a\nB\nc\nd\nE\nf\ng\n")
	_check("changes 2 lines apart are one hunk",
		GitDiff.diff_lines(near_old, near_new).size(), 1)

	# ...and with 10 lines between, the context cannot reach and they are two
	var far_old = GitDiff.to_lines("a\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nb\n")
	var far_new = GitDiff.to_lines("A\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nB\n")
	var far = GitDiff.diff_lines(far_old, far_new)
	_check("changes 10 lines apart are two hunks", far.size(), 2)
	if far.size() == 2:
		# git writes "@@ -1,4 +1,4 @@" and "@@ -9,4 +9,4 @@" for this pair. The first matches; the
		# second counts 5 here, and that is the phantom last line doing its job rather than a bug.
		# git diffs 12 lines, because it counts the final newline as a terminator; to_lines models
		# the 13 lines CodeEdit shows, the last of them empty. So a hunk that reaches the end of a
		# file ending in a newline quotes one more line of context than git's would — the only place
		# the two line models part company, and the price of markers that line up with the buffer.
		_check("first far hunk starts at the top", _spans(far[0]), [1, 4, 1, 4])
		_check("second far hunk is at the bottom", _spans(far[1]), [9, 5, 9, 5])


static func _test_empty_sides() -> void:
	var added = GitDiff.diff_lines(PackedStringArray(), PackedStringArray(["x", "y"]))
	_check("empty old is all additions", _origins(added[0]) if added.size() == 1 else "", "++")

	var removed = GitDiff.diff_lines(PackedStringArray(["x", "y"]), PackedStringArray())
	_check("empty new is all removals", _origins(removed[0]) if removed.size() == 1 else "", "--")
	_check("empty new spans", _spans(removed[0]) if removed.size() == 1 else [], [1, 2, 0, 0])


static func _test_trailing_newline() -> void:
	# git says "\ No newline at end of file" because it diffs bytes. This diffs lines, and to_lines
	# has already turned the missing newline into one fewer empty line — so the same fact arrives as
	# an ordinary removed line, and NO_NEWLINE has nothing left to say.
	var hunks = GitDiff.diff_lines(GitDiff.to_lines("a\nb\n"), GitDiff.to_lines("a\nb"))
	_check("losing the final newline is a diff", hunks.size(), 1)
	if hunks.is_empty():
		return
	_check("it reads as removing the empty last line", _origins(hunks[0]), "  -")
	_check("the removed line is the empty one", hunks[0][GitUtil.Keys.LINES][2],
		{GitUtil.Keys.ORIGIN: "-", GitUtil.Keys.TEXT: ""})
	_check("no_newline is never set", hunks[0][GitUtil.Keys.NO_NEWLINE], false)


# --- markers -----------------------------------------------------------------------------------

## The contract: hunks parsed out of a real patch resolve to markers just as ours do. If this passes,
## a hunk from git and a hunk from git_diff really are the same thing, which is the whole promise
## made to the diff preview window that will read both.
static func _test_markers_from_git_hunks() -> void:
	var patch = GitUtil.parse_patch(_read("diff_unstaged.patch"), REPO)
	var hunks:Array = patch.get("res://plain.txt", {}).get(GitUtil.Keys.HUNKS, [])
	_check("git's plain.txt hunk is there", hunks.size(), 1)
	if hunks.is_empty():
		return

	# one two three -> one TWO three four: line 2 replaced, line 4 appended
	var markers = GitDiff.hunks_to_markers(hunks, 4)
	_check("git hunk: untouched first line", markers[0], 0)
	_check("git hunk: replaced line is modified", markers[1], GitDiff.Marker.MODIFIED)
	_check("git hunk: untouched third line", markers[2], 0)
	_check("git hunk: appended line is added", markers[3], GitDiff.Marker.ADDED)


static func _test_markers() -> void:
	# a pure insertion marks only the lines that arrived
	var added = GitDiff.diff_lines(GitDiff.to_lines("a\nc"), GitDiff.to_lines("a\nb\nc"))
	_check("added run", Array(GitDiff.hunks_to_markers(added, 3)), [0, GitDiff.Marker.ADDED, 0])

	# a replacement is one fact, not a removal next to an addition: two lines becoming one marks the
	# survivor modified and says nothing about a deletion
	var replaced = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\nd"), GitDiff.to_lines("a\nX\nd"))
	_check("replace two with one",
		Array(GitDiff.hunks_to_markers(replaced, 3)), [0, GitDiff.Marker.MODIFIED, 0])

	# a deletion has no line of its own to mark, so it marks the line that closed over it
	var deleted = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\nd"), GitDiff.to_lines("a\nd"))
	_check("deletion marks the line below",
		Array(GitDiff.hunks_to_markers(deleted, 2)), [0, GitDiff.Marker.DELETED_ABOVE])

	# ...and at the end of the file there is no line below, so the last line carries it instead
	var truncated = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc"), GitDiff.to_lines("a\nb"))
	_check("deletion at eof marks the last line",
		Array(GitDiff.hunks_to_markers(truncated, 2)), [0, GitDiff.Marker.DELETED_BELOW])

	# three lines collapsing to one is still one replacement, not a replacement plus a deletion: the
	# removals and the addition are one unbroken block, so they are one fact about one line
	var collapsed = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\nd"), GitDiff.to_lines("a\nD"))
	_check("many lines collapsing to one is a modification, not also a deletion",
		Array(GitDiff.hunks_to_markers(collapsed, 2)), [0, GitDiff.Marker.MODIFIED])

	# a modification and a deletion in the same hunk land on different lines: the deletion marks the
	# line that closed over it, which is a context line, and a context line was not modified
	var mixed = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\nd\ne"), GitDiff.to_lines("a\nB\nc"))
	_check("a modification and a later deletion mark different lines",
		Array(GitDiff.hunks_to_markers(mixed, 3)),
		[0, GitDiff.Marker.MODIFIED, GitDiff.Marker.DELETED_BELOW])

	_check("no lines, no markers", GitDiff.hunks_to_markers(deleted, 0), PackedByteArray())


## hunks_to_markers takes hunks, not a diff, and the caller decides what buffer to resolve them
## against — so it has to survive hunks that describe a file the line count does not match. The
## Changes list holds exactly such hunks: `git diff` against a file the editor has since edited.
static func _test_markers_out_of_range() -> void:
	var hunks = GitDiff.diff_lines(GitDiff.to_lines("a\nb\nc\nd"), GitDiff.to_lines("a\nB\nc\nD"))

	# a buffer shorter than the hunks describe: what is in range is still true, and the rest is
	# dropped rather than written past the end
	_check("markers past the end are dropped, not written",
		Array(GitDiff.hunks_to_markers(hunks, 2)), [0, GitDiff.Marker.MODIFIED])


static func _test_fill_markers() -> void:
	var mask = GitDiff.Marker.NO_BASELINE
	_check("a wash marks every line", Array(GitDiff.fill_markers(3, mask)), [mask, mask, mask])

	# the same guard hunks_to_markers has: an empty buffer is a real case and resize(0) must not be
	# reached with a negative count
	_check("an empty file washes to nothing", GitDiff.fill_markers(0, mask), PackedByteArray())
	_check("a negative count washes to nothing", GitDiff.fill_markers(-1, mask), PackedByteArray())

	# the bit has to sit clear of the diff markers, which are drawn differently and read by mask
	_check("no baseline does not collide with a diff marker",
		mask & (GitDiff.Marker.ADDED | GitDiff.Marker.MODIFIED
			| GitDiff.Marker.DELETED_ABOVE | GitDiff.Marker.DELETED_BELOW), 0)


static func _test_edit_distance_budget() -> void:
	# nothing in common and far too big to solve: the budget has to give up rather than allocate a
	# trace the size of the file squared
	var n = GitDiff.MAX_EDIT_DISTANCE * 2
	var old_lines = PackedStringArray()
	var new_lines = PackedStringArray()
	old_lines.resize(n)
	new_lines.resize(n)
	for i in n:
		old_lines[i] = "old %d" % i
		new_lines[i] = "new %d" % i

	var hunks = GitDiff.diff_lines(old_lines, new_lines)
	# the coarse answer: one hunk, everything gone and everything new — true, just not minimal
	_check("blowing the budget still answers", hunks.size(), 1)
	if hunks.is_empty():
		return
	_check("budget fallback removes everything", hunks[0][GitUtil.Keys.OLD_COUNT], n)
	_check("budget fallback adds everything", hunks[0][GitUtil.Keys.NEW_COUNT], n)
	_check("budget fallback lines are removals then additions",
		_origins(hunks[0]), "-".repeat(n) + "+".repeat(n))
