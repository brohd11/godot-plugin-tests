extends RefCounted

const Optimization = preload("res://addons/plugin_exporter/src/class/export/optimization.gd")
const Init = preload("res://addons/plugin_exporter/src/class/export/plugin_init.gd")

static func run_tests() -> Dictionary:
	var failures:Array = []
	var expected := Optimization.defaults()
	var template:Dictionary = Init.PluginExportJSON.get_body_data()
	var seeded:Dictionary = template.options.parser_settings.parse_gd.optimizer
	if seeded != expected:
		failures.append("plugin_init did not seed optimizer defaults")
	var yaml := YAMLParser.new()
	if yaml.parse(YAMLParser.dump(template)) != OK or yaml.data.options.parser_settings.parse_gd.optimizer != expected:
		failures.append("seeded defaults did not survive YAML serialization")
	seeded.enabled = false
	if not Init.PluginExportJSON.get_body_data().options.parser_settings.parse_gd.optimizer.enabled:
		failures.append("template defaults leaked between initializations")
	var defaults := Optimization.configuration({})
	if not defaults.errors.is_empty() or not defaults.options.enabled or not defaults.options.inline_functions or defaults.options.struct_read_types != 1:
		failures.append("missing optimizer block did not enable shared defaults")
	var partial := Optimization.configuration({"inline_functions": false})
	if not partial.errors.is_empty() or partial.options.inline_functions or not partial.options.scalar_replacement:
		failures.append("partial optimizer settings lost defaults")
	var disabled := Optimization.configuration({"enabled": false, "unknown": true, "struct_read_types": 99})
	if not disabled.errors.is_empty() or disabled.options != {"enabled": false}:
		failures.append("disabled optimizer validated inactive settings")
	for value in [false, null, [], {"enabled": "false"}, {"enabled": 0}, {"unknown": true}]:
		if Optimization.configuration(value).errors.is_empty():
			failures.append("invalid optimizer configuration accepted: " + str(value))
	return {"result": failures.size(), "output": ["optimizer config: %d failures" % failures.size()] + failures}
