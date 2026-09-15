extends RefCounted
# Fixture for lambda_scope_test.gd - cases find their line by var name.

func host(a: int, b: String) -> void:
	var outer_local := Color.RED
	var shadowed := "text"
	var f = func(a: Vector2, c: Node):
		var in_f_a = a
		var in_f_b = b
		var in_f_local = outer_local
		var in_f_shadowed = shadowed
		var g = func(c: float):
			var in_g_c = c
			var in_g_a = a
		var after_g_c = c
	var after_f_a = a
	var after_f_shadowed = shadowed
	f.call(Vector2.ZERO, null)


var member_lambda = func(a: Node2D):
	var in_member_a = a
