@tool
extends RefCounted

## Fixture for collect_script_aliases: one member per branch of the member-kind rules. Nothing here
## is meant to be a useful alias — the point is exactly which names come out and which don't.

const _Preloaded = preload("res://tests/code_completions/fixtures/aliases_fixture_helper.gd")

const single := "one_option"

const several := ["first", "second"]

const with_empty := ["kept", ""]

const all_empty := ["", ""]

## Not a String or an Array, so it's data rather than an alias.
const DATA := {"int": "0"}

const NUMBER := 42

const _helper_const := "helper"

const plain_const := "plain_option"


static func two_slots(a, b) -> String:
	return "%s|%s" % [a, b]


static func one_required(a, b := "defaulted") -> String:
	return "%s|%s" % [a, b]


static func no_args() -> String:
	return "nothing"


static func _helper_builder(a) -> String:
	return a


## Zero parameters and an Array return: one key, many rows.
static func array_builder() -> Array:
	return ["first_row", "", "second_row"]


func not_static() -> String:
	return "instance"
