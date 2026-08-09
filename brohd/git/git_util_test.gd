@tool
extends EditorScript

## Parser tests for git_util.gd.
##
## parse_status() and parse_patch() are pure functions over captured git output, so nothing here
## spawns git. The fixtures in fixtures/ are real `git status --porcelain=v2` / `git diff` output
## from a repo built to hold every awkward case at once: a path with a space, a C-quoted path, a
## rename, a staged delete, a staged add, a binary file, a detached HEAD and an empty repo.

const GitUtil = preload("res://addons/addon_lib/brohd/alib_editor/misc/git_service/git_util.gd")

const FIXTURES = "res://tests/brohd/git/fixtures/"
const REPO = "res://" # the fixtures' notional repo root, so keys read as res://<path>

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_branch_headers()
	_test_branch_oid()
	_test_branch_upstream()
	_test_branch_label()
	_test_divergence_label()
	_test_count_changes()
	_test_entry_kinds()
	_test_rename()
	_test_paths_with_spaces_and_quotes()
	_test_status_never_leaks_a_dot()
	_test_patch_hunks()
	_test_patch_line_counts()
	_test_patch_path_traps()
	_test_binary()
	_test_status_labels()
	_test_status_letters()
	_test_log_tags()
	_test_file_state()
	_test_command_accepts()
	_test_pathspec()
	_test_expand_rename()
	_test_command_args()
	_test_show_args()
	_test_check_ignore_args()
	_test_find_repo_for()
	_test_ignored_entries()
	_test_ignored_covers()
	_test_ignored_quoted_dir()
	_test_count_changes_ignores_ignored()
	_test_status_color()
	_test_status_severity()

	var output:Array[String] = []
	output.append("git_util: %d passed, %d failed" % [_passed, _failures.size()])
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


# --- status ------------------------------------------------------------------------------------

static func _test_branch_headers() -> void:
	var branch = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("branch name", branch[GitUtil.Keys.BRANCH_NAME], "main")
	_check("branch not detached", branch[GitUtil.Keys.BRANCH_DETACHED], false)
	_check("branch not initial", branch[GitUtil.Keys.BRANCH_INITIAL], false)

	# "# branch.head (detached)" — v1 made this "## HEAD (no branch)", a string to sniff for
	var detached = GitUtil.parse_status(_read("status_detached.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("detached flagged", detached[GitUtil.Keys.BRANCH_DETACHED], true)
	_check("detached has no name", detached[GitUtil.Keys.BRANCH_NAME], "")

	# "# branch.oid (initial)" — v1 made this a "No commits yet on " prefix to strip
	var initial = GitUtil.parse_status(_read("status_initial.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("initial flagged", initial[GitUtil.Keys.BRANCH_INITIAL], true)
	_check("initial keeps branch name", initial[GitUtil.Keys.BRANCH_NAME], "main")


## The oid was parsed and dropped on the floor until the branch label needed it: branch.head reports
## "(detached)" and no name, so the oid is the only thing a detached HEAD can be called.
static func _test_branch_oid() -> void:
	var branch = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("oid kept", branch[GitUtil.Keys.BRANCH_OID],
		"da8dcfa5561cedb4cb3f7a859b588cafa7caa5fa")

	var detached = GitUtil.parse_status(_read("status_detached.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("detached keeps its oid", detached[GitUtil.Keys.BRANCH_OID],
		"da8dcfa5561cedb4cb3f7a859b588cafa7caa5fa")

	# "(initial)" is a marker, not a sha — it must not be stored as one
	var initial = GitUtil.parse_status(_read("status_initial.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("initial has no oid", initial[GitUtil.Keys.BRANCH_OID], "")


## `# branch.upstream` and `# branch.ab` — no fixture reached either of these arms before
## status_upstream.txt, so both were parsed but unproven.
static func _test_branch_upstream() -> void:
	var branch = GitUtil.parse_status(_read("status_upstream.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("upstream parsed", branch[GitUtil.Keys.BRANCH_UPSTREAM], "origin/main")
	_check("ahead parsed", branch[GitUtil.Keys.BRANCH_AHEAD], 2)
	_check("behind parsed", branch[GitUtil.Keys.BRANCH_BEHIND], 1)

	# a branch with no upstream must not invent divergence
	var no_upstream = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("no upstream", no_upstream[GitUtil.Keys.BRANCH_UPSTREAM], "")
	_check("no ahead", no_upstream[GitUtil.Keys.BRANCH_AHEAD], 0)
	_check("no behind", no_upstream[GitUtil.Keys.BRANCH_BEHIND], 0)


static func _test_branch_label() -> void:
	var tracking = GitUtil.parse_status(_read("status_upstream.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("label tracking", GitUtil.get_branch_label(tracking), "main → origin/main")

	var plain = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("label no upstream", GitUtil.get_branch_label(plain), "main")

	# the whole point of keeping the oid — this said "" before
	var detached = GitUtil.parse_status(_read("status_detached.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("label detached", GitUtil.get_branch_label(detached), "da8dcfa (detached)")

	var initial = GitUtil.parse_status(_read("status_initial.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("label initial", GitUtil.get_branch_label(initial), "main (no commits)")

	# not a repo, or git is not on PATH: say nothing rather than guess
	var empty = GitUtil.parse_status("", REPO)[GitUtil.Keys.BRANCH]
	_check("label empty", GitUtil.get_branch_label(empty), "")


static func _test_divergence_label() -> void:
	var branch = GitUtil.parse_status(_read("status_upstream.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("divergence both", GitUtil.get_divergence_label(branch), "↑2 ↓1")

	_check("divergence ahead only", GitUtil.get_divergence_label(
		{GitUtil.Keys.BRANCH_AHEAD: 3, GitUtil.Keys.BRANCH_BEHIND: 0}), "↑3")
	_check("divergence behind only", GitUtil.get_divergence_label(
		{GitUtil.Keys.BRANCH_AHEAD: 0, GitUtil.Keys.BRANCH_BEHIND: 4}), "↓4")

	# in sync, and untracked, both read as nothing to say
	var in_sync = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("divergence none", GitUtil.get_divergence_label(in_sync), "")


## STAGED and UNSTAGED are not exclusive, so the four counts do not sum to the total — status_upstream
## carries a file that is both, which is the case that would hide a double count.
static func _test_count_changes() -> void:
	var counts = GitUtil.count_changes(GitUtil.parse_status(_read("status_v2.txt"), REPO))
	_check("v2 total", counts[GitUtil.Keys.COUNT_TOTAL], 8)
	_check("v2 staged", counts[GitUtil.Keys.COUNT_STAGED], 3) # A. R. D.
	_check("v2 unstaged", counts[GitUtil.Keys.COUNT_UNSTAGED], 4) # .M x4
	_check("v2 untracked", counts[GitUtil.Keys.COUNT_UNTRACKED], 1)
	_check("v2 conflicted", counts[GitUtil.Keys.COUNT_CONFLICTED], 0)

	var mixed = GitUtil.count_changes(GitUtil.parse_status(_read("status_upstream.txt"), REPO))
	_check("mixed total", mixed[GitUtil.Keys.COUNT_TOTAL], 5)
	# both.txt is MM: it counts on each side, so staged + unstaged exceeds the tracked file count
	_check("mixed staged", mixed[GitUtil.Keys.COUNT_STAGED], 2) # both.txt, staged_only.txt
	_check("mixed unstaged", mixed[GitUtil.Keys.COUNT_UNSTAGED], 2) # both.txt, unstaged_only.txt
	_check("mixed untracked", mixed[GitUtil.Keys.COUNT_UNTRACKED], 1)
	# a conflict is a line kind, and settles the file outright — it is not also counted as staged
	_check("mixed conflicted", mixed[GitUtil.Keys.COUNT_CONFLICTED], 1)

	var clean = GitUtil.count_changes(GitUtil.parse_status("", REPO))
	_check("clean total", clean[GitUtil.Keys.COUNT_TOTAL], 0)


static func _test_entry_kinds() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	_check("file count", files.size(), 8)

	# "1 A. ..." — staged add, clean worktree
	var added = files.get("res://added.txt", {})
	_check("added kind", added.get(GitUtil.Keys.KIND), GitUtil.Kind.ORDINARY)
	_check("added index", added.get(GitUtil.Keys.INDEX), GitUtil.Status.ADDED)
	_check("added worktree", added.get(GitUtil.Keys.WORKTREE), GitUtil.Status.NONE)
	_check("added staged", added.get(GitUtil.Keys.STAGED), true)
	_check("added not unstaged", added.get(GitUtil.Keys.UNSTAGED), false)

	# "1 .M ..." — unstaged modify
	var plain = files.get("res://plain.txt", {})
	_check("plain index", plain.get(GitUtil.Keys.INDEX), GitUtil.Status.NONE)
	_check("plain worktree", plain.get(GitUtil.Keys.WORKTREE), GitUtil.Status.MODIFIED)
	_check("plain not staged", plain.get(GitUtil.Keys.STAGED), false)
	_check("plain unstaged", plain.get(GitUtil.Keys.UNSTAGED), true)

	# "1 D. ..." — staged delete
	_check("deleted index",
		files.get("res://to_delete.txt", {}).get(GitUtil.Keys.INDEX), GitUtil.Status.DELETED)

	# "? ..." — untracked is its own line type in v2, not a "??" XY pair
	var untracked = files.get("res://untracked.txt", {})
	_check("untracked kind", untracked.get(GitUtil.Keys.KIND), GitUtil.Kind.UNTRACKED)
	_check("untracked index", untracked.get(GitUtil.Keys.INDEX), GitUtil.Status.NONE)
	_check("untracked worktree", untracked.get(GitUtil.Keys.WORKTREE), GitUtil.Status.NONE)

	# blob OIDs come free with v2 and are what a future cat-file --batch would consume
	_check("oid head", plain.get(GitUtil.Keys.OID_HEAD), "4cb29ea38f70d7c61b2a3a25b02e3bdf44905402")
	_check("submodule field", plain.get(GitUtil.Keys.SUB), "N...")


static func _test_rename() -> void:
	# "2 R. ... R100 renamed.txt<TAB>to_rename.txt" — the target path comes first, the origin after
	# the tab. v1 joined them with " -> ", which a filename containing " -> " could forge.
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]
	var renamed = files.get("res://renamed.txt", {})

	_check("rename kind", renamed.get(GitUtil.Keys.KIND), GitUtil.Kind.RENAMED)
	_check("rename from", renamed.get(GitUtil.Keys.RENAMED_FROM), "res://to_rename.txt")
	_check("rename score", renamed.get(GitUtil.Keys.SCORE), 100)
	_check("rename index", renamed.get(GitUtil.Keys.INDEX), GitUtil.Status.RENAMED)
	_check("origin path is not itself an entry", files.has("res://to_rename.txt"), false)


static func _test_paths_with_spaces_and_quotes() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	# the reason every split in _parse_entry carries an explicit maxsplit
	_check("path with a space survives", files.has("res://with space.txt"), true)

	# git C-quotes a path containing a quote even with core.quotepath=false
	_check("C-quoted path is unquoted", files.has('res://quo"te.txt'), true)


static func _test_status_never_leaks_a_dot() -> void:
	# the v1 -> v2 footgun: "unmodified" is "." in v2 where it was " " in v1. It must be normalised
	# to Status.NONE at the parser boundary and never reach a consumer as a raw character.
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]
	for path:String in files:
		var entry:Dictionary = files[path]
		for key in [GitUtil.Keys.INDEX, GitUtil.Keys.WORKTREE]:
			if typeof(entry[key]) != TYPE_INT:
				_failures.append("%s: %s is not a Status enum (got %s)" % [path, key, entry[key]])
				return
	_passed += 1


# --- diff --------------------------------------------------------------------------------------

static func _test_patch_hunks() -> void:
	var patch = GitUtil.parse_patch(_read("diff_unstaged.patch"), REPO)
	var plain = patch.get("res://plain.txt", {})
	var hunks:Array = plain.get(GitUtil.Keys.HUNKS, [])

	_check("one hunk in plain.txt", hunks.size(), 1)
	if hunks.is_empty():
		return

	var hunk:Dictionary = hunks[0]
	_check("hunk old start", hunk[GitUtil.Keys.OLD_START], 1)
	_check("hunk old count", hunk[GitUtil.Keys.OLD_COUNT], 3)
	_check("hunk new start", hunk[GitUtil.Keys.NEW_START], 1)
	_check("hunk new count", hunk[GitUtil.Keys.NEW_COUNT], 4)

	# one two three -> one TWO three four
	var lines:Array = hunk[GitUtil.Keys.LINES]
	_check("hunk line count", lines.size(), 5)
	_check("context line", lines[0], {GitUtil.Keys.ORIGIN: " ", GitUtil.Keys.TEXT: "one"})
	_check("removed line", lines[1], {GitUtil.Keys.ORIGIN: "-", GitUtil.Keys.TEXT: "two"})
	_check("added line", lines[2], {GitUtil.Keys.ORIGIN: "+", GitUtil.Keys.TEXT: "TWO"})
	_check("trailing added line", lines[4], {GitUtil.Keys.ORIGIN: "+", GitUtil.Keys.TEXT: "four"})


## A hunk's lines must add up to the counts its own header declares — the invariant that makes a hunk
## readable without re-deriving anything from the text it came out of.
##
## `git diff` ends its output with a newline, and splitting on it leaves a trailing "" that reads as
## an empty context line: one the header never counted, landing on the last hunk of the last file of
## every patch. Only the last, which is why the plain.txt case above never saw it.
static func _test_patch_line_counts() -> void:
	var patch = GitUtil.parse_patch(_read("diff_unstaged.patch"), REPO)

	for res_path:String in patch:
		var file_data:Dictionary = patch[res_path]
		if file_data[GitUtil.Keys.BINARY]:
			continue

		for hunk:Dictionary in file_data[GitUtil.Keys.HUNKS]:
			var old_count = 0
			var new_count = 0
			for line:Dictionary in hunk[GitUtil.Keys.LINES]:
				match line[GitUtil.Keys.ORIGIN]:
					" ":
						old_count += 1
						new_count += 1
					"-":
						old_count += 1
					"+":
						new_count += 1

			_check("%s: hunk lines match its old count" % res_path,
				old_count, hunk[GitUtil.Keys.OLD_COUNT])
			_check("%s: hunk lines match its new count" % res_path,
				new_count, hunk[GitUtil.Keys.NEW_COUNT])


static func _test_patch_path_traps() -> void:
	var patch = GitUtil.parse_patch(_read("diff_unstaged.patch"), REPO)

	# git terminates a diff header path with a TAB when it contains a space:
	#     "--- a/with space.txt\t"
	# leaving the tab on would produce a key no status entry could ever match, and the file's
	# hunks would silently vanish.
	_check("space path keyed without trailing tab", patch.has("res://with space.txt"), true)
	_check("space path has a hunk",
		patch.get("res://with space.txt", {}).get(GitUtil.Keys.HUNKS, []).size(), 1)

	# git C-quotes the whole field, "a/" prefix included: '--- "a/quo\"te.txt"'
	_check("quoted path keyed correctly", patch.has('res://quo"te.txt'), true)


static func _test_binary() -> void:
	var patch = GitUtil.parse_patch(_read("diff_unstaged.patch"), REPO)
	var bin = patch.get("res://bin.dat", {})

	# a binary file has no +++/--- headers at all, only "Binary files a/x and b/x differ", so the
	# path has to be recovered from the "diff --git" line
	_check("binary flagged", bin.get(GitUtil.Keys.BINARY), true)
	_check("binary has no hunks", bin.get(GitUtil.Keys.HUNKS, []).size(), 0)


# --- display -----------------------------------------------------------------------------------

static func _test_status_labels() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	_check("label: untracked", GitUtil.get_status_label(files["res://untracked.txt"]), "Untracked")
	_check("label: added", GitUtil.get_status_label(files["res://added.txt"]), "Added")
	_check("label: deleted", GitUtil.get_status_label(files["res://to_delete.txt"]), "Deleted")
	_check("label: renamed", GitUtil.get_status_label(files["res://renamed.txt"]), "Renamed")

	# the worktree side wins when the file is dirty on disk
	_check("label: modified", GitUtil.get_status_label(files["res://plain.txt"]), "Modified")


static func _test_status_letters() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	# git's own short-format letters: "?" untracked, "U" conflict — the two must not collide
	_check("letter: untracked", GitUtil.get_status_letter(files["res://untracked.txt"]), "?")
	_check("letter: added", GitUtil.get_status_letter(files["res://added.txt"]), "A")
	_check("letter: deleted", GitUtil.get_status_letter(files["res://to_delete.txt"]), "D")
	_check("letter: renamed", GitUtil.get_status_letter(files["res://renamed.txt"]), "R")
	_check("letter: modified", GitUtil.get_status_letter(files["res://plain.txt"]), "M")

	# a conflict comes from a "u" line, which this fixture has none of — build one
	var conflicted = GitUtil.parse_status("u UU N... 100644 100644 100644 100644 aa bb cc x.gd", REPO)
	var entry:Dictionary = conflicted[GitUtil.Keys.FILES]["res://x.gd"]
	_check("conflict is Kind.UNMERGED", entry[GitUtil.Keys.KIND], GitUtil.Kind.UNMERGED)
	_check("letter: conflict", GitUtil.get_status_letter(entry), "U")
	_check("label: conflict", GitUtil.get_status_label(entry), "Conflict")

	# the letter must always be exactly one character, or it defeats the point of compacting
	for path:String in files:
		if GitUtil.get_status_letter(files[path]).length() != 1:
			_failures.append("%s: letter is not a single character" % path)
			return
	_passed += 1


# --- log / tags --------------------------------------------------------------------------------

static func _test_log_tags() -> void:
	var commits = GitUtil.parse_log(_read("log.txt"))
	_check("commit count", commits.size(), 5)
	if commits.size() < 5:
		return

	# %D carries branch and HEAD refs in the same field as the tags. Only the "tag: " prefix tells
	# them apart — without the filter this row would claim a tag called "HEAD -> main".
	_check("branch refs are not tags", commits[0][GitUtil.Keys.TAGS], [] as Array[String])
	_check("branch commit still parses", commits[0][GitUtil.Keys.HASH], "0d41245")

	_check("a tag is found", commits[1][GitUtil.Keys.TAGS], ["v0.7.2"] as Array[String])
	_check("no refs at all", commits[2][GitUtil.Keys.TAGS], [] as Array[String])
	_check("tag with dashes", commits[3][GitUtil.Keys.TAGS], ["0-5-0"] as Array[String])

	# a commit can carry several tags
	_check("two tags", commits[4][GitUtil.Keys.TAGS], ["v9.0.0", "latest"] as Array[String])

	# the %D field is empty for most commits, so the field-count guard must still let them through
	_check("empty %D does not drop the commit", commits[2][GitUtil.Keys.SUBJECT].is_empty(), false)
	_check("subject survives", commits[1][GitUtil.Keys.SUBJECT].is_empty(), false)
	_check("author survives", commits[1][GitUtil.Keys.AUTHOR].is_empty(), false)
	_check("full hash survives", commits[1][GitUtil.Keys.FULL_HASH].length(), 40)


# --- commands ----------------------------------------------------------------------------------

static func _test_file_state() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	# a line kind settles the file outright, before the staged/unstaged flags are read. It has to:
	# an untracked entry is built from a ".." XY pair, so *neither* flag is set and the kind is the
	# only thing that classifies it. Read the flags first and untracked would come back as 0.
	_check("untracked state", GitUtil.get_file_state(files["res://untracked.txt"]),
		GitUtil.State.UNTRACKED)

	_check("staged add", GitUtil.get_file_state(files["res://added.txt"]), GitUtil.State.STAGED)
	_check("staged delete", GitUtil.get_file_state(files["res://to_delete.txt"]), GitUtil.State.STAGED)
	_check("unstaged edit", GitUtil.get_file_state(files["res://plain.txt"]), GitUtil.State.UNSTAGED)

	var mixed = GitUtil.parse_status(_read("status_upstream.txt"), REPO)[GitUtil.Keys.FILES]
	# MM: staged hunks with further edits still on disk — both bits, which is why the two are a mask
	# and not an either/or
	_check("MM is both", GitUtil.get_file_state(mixed["res://both.txt"]),
		GitUtil.State.STAGED | GitUtil.State.UNSTAGED)
	_check("conflict state", GitUtil.get_file_state(mixed["res://conflict.txt"]),
		GitUtil.State.CONFLICTED)

	_check("unknown file has no state", GitUtil.get_file_state({}), 0)


static func _test_command_accepts() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]
	var mixed = GitUtil.parse_status(_read("status_upstream.txt"), REPO)[GitUtil.Keys.FILES]

	var untracked = files["res://untracked.txt"]
	var staged = files["res://added.txt"]
	var unstaged = files["res://plain.txt"]
	var conflict = mixed["res://conflict.txt"]

	# the menu shows a command only where it has something to do, so these are what keeps "Unstage"
	# off an untracked file
	_check("stage takes untracked", GitUtil.command_accepts(GitUtil.Command.STAGE, untracked), true)
	_check("stage takes unstaged", GitUtil.command_accepts(GitUtil.Command.STAGE, unstaged), true)
	# staging a conflict is how git marks it resolved
	_check("stage takes conflict", GitUtil.command_accepts(GitUtil.Command.STAGE, conflict), true)
	_check("stage skips staged-only", GitUtil.command_accepts(GitUtil.Command.STAGE, staged), false)

	_check("unstage takes staged", GitUtil.command_accepts(GitUtil.Command.UNSTAGE, staged), true)
	_check("unstage skips untracked", GitUtil.command_accepts(GitUtil.Command.UNSTAGE, untracked), false)
	_check("unstage skips unstaged-only", GitUtil.command_accepts(GitUtil.Command.UNSTAGE, unstaged), false)

	# `git restore` does not touch a file git has never seen — removing one of those is DELETE
	_check("discard takes unstaged", GitUtil.command_accepts(GitUtil.Command.DISCARD, unstaged), true)
	_check("discard skips untracked", GitUtil.command_accepts(GitUtil.Command.DISCARD, untracked), false)

	_check("delete takes untracked", GitUtil.command_accepts(GitUtil.Command.DELETE, untracked), true)
	_check("delete skips tracked", GitUtil.command_accepts(GitUtil.Command.DELETE, unstaged), false)
	_check("delete skips staged", GitUtil.command_accepts(GitUtil.Command.DELETE, staged), false)


static func _test_pathspec() -> void:
	_check("pathspec is repo relative", GitUtil.to_pathspec(REPO, "res://addons/thing.gd"),
		":(literal)addons/thing.gd")

	# a nested repo: the keys are still res:// paths, so the prefix that comes off is the repo's
	_check("nested repo pathspec",
		GitUtil.to_pathspec("res://addons/script_dock/", "res://addons/script_dock/src/a.gd"),
		":(literal)src/a.gd")

	# the whole point. git matches a pathspec as a glob, so without :(literal) `a[bc].txt` also
	# matches — and DISCARDs, and DELETEs — a bystanding ab.txt that was never selected.
	_check("glob chars are neutralised", GitUtil.to_pathspec(REPO, "res://a[bc].txt"),
		":(literal)a[bc].txt")


static func _test_expand_rename() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]
	var selected = ["res://renamed.txt"]

	# a rename is a delete of the old path plus an add of the new, and the entry keys on the new one.
	# Unstage only that and git leaves "D to_rename.txt" staged next to an untracked "renamed.txt" —
	# a half-unstaged rename, worse than either end of it.
	var unstage = GitUtil.expand_paths(GitUtil.Command.UNSTAGE, selected, files)
	_check("unstaging a rename takes both paths", unstage,
		["res://renamed.txt", "res://to_rename.txt"])

	# nothing else needs the old path: it does not exist on disk to stage, restore or delete
	_check("staging a rename takes one path",
		GitUtil.expand_paths(GitUtil.Command.STAGE, selected, files), ["res://renamed.txt"])

	_check("an ordinary file is untouched",
		GitUtil.expand_paths(GitUtil.Command.UNSTAGE, ["res://added.txt"], files), ["res://added.txt"])

	# the caller's array must survive: it is the one the signal carried
	_check("selection is not mutated", selected, ["res://renamed.txt"])


static func _test_command_args() -> void:
	var paths = ["res://plain.txt"]

	_check("stage args", GitUtil.build_command_args(GitUtil.Command.STAGE, REPO, paths),
		["add", "--", ":(literal)plain.txt"])
	_check("unstage args", GitUtil.build_command_args(GitUtil.Command.UNSTAGE, REPO, paths),
		["restore", "--staged", "--", ":(literal)plain.txt"])
	_check("discard args", GitUtil.build_command_args(GitUtil.Command.DISCARD, REPO, paths),
		["restore", "--", ":(literal)plain.txt"])
	_check("delete args", GitUtil.build_command_args(GitUtil.Command.DELETE, REPO, paths),
		["clean", "-f", "--", ":(literal)plain.txt"])

	# `git restore --staged` rebuilds the index *from HEAD*, and a repo with no commits has no HEAD:
	# it dies with "fatal: could not resolve HEAD". `git rm --cached` is the unstage that works there.
	var initial = GitUtil.parse_status(_read("status_initial.txt"), REPO)[GitUtil.Keys.BRANCH]
	_check("initial repo is flagged", initial[GitUtil.Keys.BRANCH_INITIAL], true)
	_check("unstage on an initial repo",
		GitUtil.build_command_args(GitUtil.Command.UNSTAGE, REPO, paths, true),
		["rm", "--cached", "--", ":(literal)plain.txt"])

	# only unstage changes shape on an initial repo
	_check("stage is unchanged on an initial repo",
		GitUtil.build_command_args(GitUtil.Command.STAGE, REPO, paths, true),
		["add", "--", ":(literal)plain.txt"])

	_check("multiple paths", GitUtil.build_command_args(GitUtil.Command.STAGE, REPO,
		["res://a.txt", "res://b.txt"]),
		["add", "--", ":(literal)a.txt", ":(literal)b.txt"])

	# the repo root trims to "", and a bare `:(literal)` is every file in the repo — an argv that
	# ends at `--` would DISCARD the whole worktree, so there is no safe argv to build at all
	_check("the repo root is not commandable", GitUtil.is_commandable_path(REPO, REPO), false)
	_check("a nested repo root is not commandable",
		GitUtil.is_commandable_path("res://addons/lib/", "res://addons/lib/"), false)
	_check("an ordinary path is commandable",
		GitUtil.is_commandable_path(REPO, "res://plain.txt"), true)

	_check("discarding the repo root builds nothing",
		GitUtil.build_command_args(GitUtil.Command.DISCARD, REPO, [REPO]), [])
	_check("deleting the repo root builds nothing",
		GitUtil.build_command_args(GitUtil.Command.DELETE, REPO, [REPO]), [])

	# one bad entry must not carry the rest of the selection into a repo-wide command, nor drop it
	_check("the root is dropped from a mixed selection",
		GitUtil.build_command_args(GitUtil.Command.DISCARD, REPO, [REPO, "res://a.txt"]),
		["restore", "--", ":(literal)a.txt"])


static func _test_show_args() -> void:
	_check("show args", GitUtil.build_show_args(GitUtil.REV_HEAD, REPO, "res://plain.txt"),
		["show", "HEAD:plain.txt"])

	# the path is relative to *its own* repo, not to the project
	_check("show args from a nested repo",
		GitUtil.build_show_args(GitUtil.REV_HEAD, "res://addons/lib/", "res://addons/lib/src/a.gd"),
		["show", "HEAD:src/a.gd"])

	# `<rev>:<path>` is a tree path and git does not glob it, so the pathspec prefix that every
	# command arg carries would here become part of the filename git goes looking for
	_check("show path is not a pathspec",
		GitUtil.build_show_args(GitUtil.REV_HEAD, REPO, "res://plain.txt")[1].contains(
			GitUtil.PATHSPEC_LITERAL), false)


static func _test_check_ignore_args() -> void:
	_check("check-ignore args", GitUtil.build_check_ignore_args(REPO, "res://plain.txt"),
		["check-ignore", "-q", "--", "plain.txt"])

	# the path is relative to *its own* repo, as with show args
	_check("check-ignore args from a nested repo",
		GitUtil.build_check_ignore_args("res://addons/lib/", "res://addons/lib/src/a.gd"),
		["check-ignore", "-q", "--", "src/a.gd"])

	# check-ignore takes pathnames, not pathspecs — the prefix would become part of the name it looks up
	_check("check-ignore path is not a pathspec",
		GitUtil.build_check_ignore_args(REPO, "res://plain.txt")[3].contains(
			GitUtil.PATHSPEC_LITERAL), false)

	# `--` is what keeps a path that looks like a flag from being read as one
	_check("check-ignore separates its path",
		GitUtil.build_check_ignore_args(REPO, "res://--weird.txt"),
		["check-ignore", "-q", "--", "--weird.txt"])


static func _test_find_repo_for() -> void:
	var repos = ["res://", "res://addons/lib/", "res://addons/other/"]

	# deepest wins: the project repo does not track the nested clone's files at all, so answering
	# "res://" here would mean asking git for a path that is not in its HEAD — an ABSENT that reads
	# as a brand new file, and a script painted entirely green
	_check("nested repo wins over the project",
		GitUtil.find_repo_for("res://addons/lib/src/a.gd", repos), "res://addons/lib/")
	_check("a project file takes the project repo",
		GitUtil.find_repo_for("res://src/main.gd", repos), "res://")
	_check("a sibling nested repo is not matched",
		GitUtil.find_repo_for("res://addons/other/x.gd", repos), "res://addons/other/")

	# no repo at all is a real case: the project need not be one
	_check("no repo matches", GitUtil.find_repo_for("res://src/main.gd", []), "")


static func _test_ignored_entries() -> void:
	var status = GitUtil.parse_status(_read("status_ignored.txt"), REPO)
	var ignored:Array = status[GitUtil.Keys.IGNORED]
	var files:Dictionary = status[GitUtil.Keys.FILES]

	_check("every ! line is collected", ignored.size(), 5)
	_check("a directory entry keeps its trailing slash", ignored.has("res://addons/"), true)
	_check("a file entry has no slash to keep", ignored.has("res://.DS_Store"), true)

	# the panel's Changes list iterates FILES, so an ignored directory landing there would render a
	# row for res://addons/. Keeping the two apart is the whole reason ! has its own array.
	_check("an ignored directory never reaches FILES", files.has("res://addons/"), false)
	_check("FILES holds only the real changes", files.size(), 2)


static func _test_ignored_covers() -> void:
	_check("a directory covers its subtree",
		GitUtil.ignored_covers("res://addons/", "res://addons/x/plugin.gd"), true)
	_check("a directory covers itself, so its own row dims",
		GitUtil.ignored_covers("res://addons/", "res://addons/"), true)
	_check("a file entry matches exactly",
		GitUtil.ignored_covers("res://.DS_Store", "res://.DS_Store"), true)
	_check("a file entry is not treated as a prefix",
		GitUtil.ignored_covers("res://.DS_Store", "res://.DS_Store.bak"), false)

	# the trailing slash is what stops a longer sibling name from matching
	_check("a name that merely starts the same is not covered",
		GitUtil.ignored_covers("res://addons/", "res://addonsfoo/x.gd"), false)

	# a bare `addons/` in .gitignore matches at every depth, which is why this project re-includes
	# tools/addons/ with a negation. git reports the match anchored at the repo root, so the prefix
	# test has to honour that anchor or the re-included tree dims along with the real one.
	_check("an unanchored pattern does not reach a nested namesake",
		GitUtil.ignored_covers("res://addons/", "res://tools/addons/x.gd"), false)

	_check("nothing ignored", GitUtil.is_path_ignored([], "res://a.gd"), false)
	_check("is_path_ignored scans past a non-match",
		GitUtil.is_path_ignored(["res://.godot/", "res://addons/"], "res://addons/x.gd"), true)


static func _test_ignored_quoted_dir() -> void:
	var ignored:Array = GitUtil.parse_status(_read("status_ignored.txt"), REPO)[GitUtil.Keys.IGNORED]

	# the "! " branch never ran before ignored parsing landed, so its unquoting is untested ground.
	# The trailing slash sits inside the quotes, and losing it would silently downgrade the entry
	# from "covers this subtree" to "matches this one path".
	_check("a C-quoted directory unquotes with its slash intact",
		ignored.has("res://ig\"nored dir/"), true)


static func _test_count_changes_ignores_ignored() -> void:
	var counts = GitUtil.count_changes(GitUtil.parse_status(_read("status_ignored.txt"), REPO))

	# counts come off FILES, so this is the same guard as _test_ignored_entries seen from the side
	# that actually feeds the panel's badge
	_check("ignored paths are not counted as changes", counts[GitUtil.Keys.COUNT_TOTAL], 2)
	_check("untracked is still counted", counts[GitUtil.Keys.COUNT_UNTRACKED], 1)
	_check("unstaged is still counted", counts[GitUtil.Keys.COUNT_UNSTAGED], 1)


static func _test_status_color() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	var colors = GitService.GitColors.new()

	_check("untracked is light green",
		GitUtil.get_status_color(files["res://untracked.txt"], colors), GitUtil.Colors.L_GREEN)
	_check("a staged add is green",
		GitUtil.get_status_color(files["res://added.txt"], colors), GitUtil.Colors.GREEN)
	_check("a worktree edit is light yellow",
		GitUtil.get_status_color(files["res://plain.txt"], colors), GitUtil.Colors.L_YELLOW)

	# kind has to win over the staged/unstaged pair: a conflict is neither, since a "u" line carries
	# a synthetic ".." XY, and would otherwise fall through to the dim default
	var conflicted = GitUtil.parse_status("u UU N... 100644 100644 100644 100644 aa bb cc x.gd", REPO)
	_check("a conflict is red",
		GitUtil.get_status_color(conflicted[GitUtil.Keys.FILES]["res://x.gd"], colors), GitUtil.Colors.RED)


## The tree's marker bubble picks a winner by int compare, so the ladder itself is the contract
## here, alongside each status landing on its own rung.
static func _test_status_severity() -> void:
	var files = GitUtil.parse_status(_read("status_v2.txt"), REPO)[GitUtil.Keys.FILES]

	_check("severity: untracked",
		GitUtil.get_status_severity(files["res://untracked.txt"]), GitUtil.Severity.UNTRACKED)
	_check("severity: staged add",
		GitUtil.get_status_severity(files["res://added.txt"]), GitUtil.Severity.STAGED)
	_check("severity: worktree edit",
		GitUtil.get_status_severity(files["res://plain.txt"]), GitUtil.Severity.MODIFIED)

	var conflicted = GitUtil.parse_status("u UU N... 100644 100644 100644 100644 aa bb cc x.gd", REPO)
	_check("severity: conflict",
		GitUtil.get_status_severity(conflicted[GitUtil.Keys.FILES]["res://x.gd"]), GitUtil.Severity.CONFLICTED)

	# the dim-default fallthrough, same as the color side — GitService maps "no entry at all"
	# to NONE before this is ever called
	_check("severity: empty entry", GitUtil.get_status_severity({}), GitUtil.Severity.IGNORED)

	_check("severity ladder", GitUtil.Severity.CONFLICTED > GitUtil.Severity.MODIFIED
		and GitUtil.Severity.MODIFIED > GitUtil.Severity.UNTRACKED
		and GitUtil.Severity.UNTRACKED > GitUtil.Severity.STAGED
		and GitUtil.Severity.STAGED > GitUtil.Severity.IGNORED
		and GitUtil.Severity.IGNORED > GitUtil.Severity.NONE, true)
