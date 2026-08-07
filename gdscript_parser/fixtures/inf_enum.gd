@tool
class_name InfEnum
extends RefCounted
## Fixture for scenario_inference.gd: a global class used as a user-type dictionary key/value and as a
## preload target for `preload(...).CONST` inference. Mirrors TEnum in test_comp.gd.

@warning_ignore_start("unused_parameter", "unused_variable")

enum E { ONE, TWO }

const MY_COLOR := Color.AQUA

class Nested:
	var tag := "nested"
