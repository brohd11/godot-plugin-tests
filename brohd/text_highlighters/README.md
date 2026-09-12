# Optional GDSh highlighter tests

Run from the workspace root with Godot 4.6 or newer:

```sh
python3 tests/brohd/text_highlighters/run_headless.py --godot godot --export
```

The runner creates two isolated projects containing ALib's text highlighters and
the dispatcher test. One has no GDSh files; the other includes only GDSh's
standalone `internal/script_highlighter_logic.gd` provider. No generated namespace,
editor addon, or other GDSh script is needed.

The tests cover extension normalization and discovery, fresh provider instances,
ALib palette compatibility, multiline cache invalidation, and plain-text fallback
when the provider is absent. `--export` repeats both cases from binary-script PCKs;
`--keep` retains the temporary projects.
