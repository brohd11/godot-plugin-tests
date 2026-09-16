@tool
class_name GpDerived
extends GpBase
## Fixture: subclass in the inheritance chain. Inherits State / StateAlias / Handle / make_state
## from GpBase, and adds its own enum. Scenarios extend this to exercise inherited class/enum
## access-path resolution.

@warning_ignore_start("unused_parameter", "unused_variable")

enum Local { ONE, TWO }

func make_local() -> Local:
	return Local.ONE
