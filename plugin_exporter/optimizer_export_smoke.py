"""Export optimizer fixtures and execute each package in an isolated Godot project."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "addons/plugin_exporter_test"


def run(godot, project, *args):
    result = subprocess.run(
        [godot, "--headless", "--path", str(project), "--log-file", str(Path(tempfile.gettempdir()) / ("optimizer-" + project.name + ".log")), *args],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=300,
    )
    if result.returncode or "SCRIPT ERROR:" in result.stdout:
        raise AssertionError(result.stdout)
    return result.stdout


def hashes():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (FIXTURE / "src").rglob("*.gd")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--reuse", type=Path, help="Only execute packages from an existing manifest")
    args = parser.parse_args()
    output = args.reuse or Path(tempfile.mkdtemp(prefix="plugin-optimizer-smoke-"))
    print(f"Integration output: {output}", flush=True)
    before = hashes()
    if not args.reuse:
        log = run(args.godot, ROOT, "--script", "res://tests/plugin_exporter/run_optimizer_export.gd", "--", str(output))
        (output / "export.log").write_text(log)
        assert "OPTIMIZER_EXPORT_ASSERTIONS" in log, log
    for entry in json.loads((output / "manifest.json").read_text()):
        entry["name"] = entry["name"].rstrip("/")
        project = output / "runtimes" / entry["name"]
        project.mkdir(parents=True, exist_ok=True)
        target = project / entry["install"]
        shutil.copytree(entry["dir"], target, dirs_exist_ok=True)
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Optimizer Runtime"\n')
        script = "res://" + entry["install"] + "/src/core/optimizer_user.gd"
        core = "res://" + entry["install"] + "/src/core/"
        constructor = "new" if entry["name"] == "disabled" else "create"
        expected_calls = 2 if entry["name"] in ("disabled", "inline-off", "struct-only") else 1
        element_type = "Vec" if entry["name"] == "disabled" else "Array"
        (project / "run.gd").write_text(f'''extends SceneTree
const User = preload("{script}")
const Access = preload("{core}struct_access.gd")
const Vec = preload("{core}struct_vec.gd")
func _init() -> void:
    if User.substitution_check() != {expected_calls} or User.nested_check(2.0) != 23.0:
        printerr("COMPOSITION_RUNTIME_FAILED")
        quit(1)
        return
    if User.early_check() != [5, ["early", "after", 0, "after", 1, "after"]]:
        printerr("EARLY_RETURN_RUNTIME_FAILED")
        quit(1)
        return
    var result:Array = User.run()
    if result != [5.0, 9.0, 10.0, 9.0] or User.reference_score() != 9:
        printerr("OPTIMIZER_RUNTIME_FAILED ", result)
        quit(1)
        return
    for path:String in ["test.gd", "test.gd.remap", "test.gd::Inner", "image.png"]:
        var expected:bool = path != "image.png"
        if User.path_check(path) != expected or User.dynamic_path_check(path) != expected:
            printerr("PREDICATE_RUNTIME_FAILED")
            quit(1)
            return
    var values:Array[{element_type}] = [Vec.{constructor}(3.0, 4.0), Vec.{constructor}(5.0, 6.0)]
    var checks:Array = [Access.length_sq(values[0]), Access.local_typed(), Access.local_inferred(),
        Access.from_return(), Access.loop_sum(values), Access.indexed(values),
        Access.typed_list(values[0], values[1]), Access.lambda_sum(values), Access.new().member()]
    if checks != [25.0, "changed", 2.0, 3, 8.0, 4.0, 6.0, 9.0, 7.0]:
        printerr("STRUCT_RUNTIME_FAILED ", checks)
        quit(1)
        return
    print("OPTIMIZER_RUNTIME_OK ", result)
    quit()
''')
        log = run(args.godot, project, "--script", "res://run.gd")
        assert "OPTIMIZER_RUNTIME_OK" in log, log
        (project / "runtime.log").write_text(log)
        stats = entry["stats"]
        rendered = (target / "src/core/optimizer_user.gd").read_text()
        if entry["name"] == "disabled":
            assert not stats and "_inline_" not in rendered and "_struct_opt_" not in rendered
        elif entry["name"] in ("inline-off", "struct-only"):
            assert stats.get("inline_calls", 0) == 0 and "Helpers.affine(number)" in rendered
        else:
            assert "if Helpers.is_gdscript_path(path):" not in rendered
            assert stats["inline_calls"] >= 4 and stats["inline_expanded_calls"] >= 2, stats
            assert stats["inline_early_return_calls"] >= 1, stats
            assert "Helpers.early_value(value)" in rendered and "Helpers.early_effect(events, value)" not in rendered
            assert "Helpers.affine(number)" not in rendered and "Helpers.struct_score(" not in rendered
            assert stats["scalar_structs"] >= 1, stats
        if entry["name"] == "references":
            package_source = "\n".join(path.read_text() for path in target.rglob("*.gd"))
            for marker in ("# optimizer-inline;", "# optimizer-struct;", "# optimizer-scalar-replacement;", "# optimizer-struct-read;"):
                assert marker in package_source, marker
            assert "return false or Helpers.is_gdscript_path(path)" not in rendered
            assert stats["scalar_structs"] > 3, stats
        if entry["name"] in ("inline-off", "references"):
            assert stats["struct_read_casts"] > 0 and stats["struct_typed_captures"] == 0, stats
        print(f"PASS {entry['name']}: {stats.get('inline_calls', 0)} calls inlined", flush=True)
    assert hashes() == before, "Export changed fixture source files"
    print("PASS exported runtimes and source preservation", flush=True)


if __name__ == "__main__":
    main()
