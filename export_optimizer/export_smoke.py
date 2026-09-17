"""Export a disposable project and run its PCK with the editor binary (no templates needed)."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / "fixtures"
REFERENCES = re.compile(r'(?:preload\s*\(\s*|extends\s+)["\']([^"\'\n]+)["\']')


def install_dependencies(project):
    uid_map = {}
    paths = subprocess.check_output(
        ["rg", "--files", "--hidden", "-g", "*.uid", "-g", "!**/export_ignore/**", "addons", "namespace"],
        cwd=ROOT, text=True,
    ).splitlines()
    for relative in paths:
        sidecar = ROOT / relative
        uid_map[sidecar.read_text().strip()] = sidecar.with_suffix("")
    pending = [ROOT / "addons/export_optimizer/plugin.gd"]
    copied = set()
    while pending:
        source = pending.pop()
        if source in copied:
            continue
        copied.add(source)
        target = project / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        sidecar = source.with_suffix(source.suffix + ".uid")
        if sidecar.exists():
            shutil.copy2(sidecar, target.with_suffix(target.suffix + ".uid"))
        if source.suffix != ".gd":
            continue
        for reference in REFERENCES.findall(source.read_text()):
            if not reference.startswith(("res://", "uid://")) and not reference.endswith(".gd"):
                continue
            if reference.startswith("uid://"):
                dependency = uid_map[reference]
            elif reference.startswith("res://"):
                dependency = ROOT / reference[6:]
            else:
                dependency = (source.parent / reference).resolve()
            if dependency.is_file():
                pending.append(dependency)
    shutil.copy2(ROOT / "addons/export_optimizer/plugin.cfg", project / "addons/export_optimizer/plugin.cfg")
    install_yaml_requirement(project)


def install_yaml_requirement(project):
    # Model the plugin.cfg install requirement using the checked-out dependency.
    cfg = (project / "addons/export_optimizer/plugin.cfg").read_text()
    assert '"brohd11/godot-yaml-parser@v2.1.0"' in cfg, cfg
    source = ROOT / "addons/addon_lib/yaml_parser"
    target = project / "addons/addon_lib/yaml_parser"
    target.mkdir(parents=True, exist_ok=True)
    for name in ("yaml.gd", "yaml.gd.uid", "version.cfg"):
        if (source / name).exists():
            shutil.copy2(source / name, target / name)



def run(godot, project, *args, expected_error=False):
    result = subprocess.run(
        [godot, "--headless", "--path", str(project), "--log-file", str(project / "run.log"), *args],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=120,
    )
    # Known shutdown noise also occurs with optimization disabled on the 4.6 Mono editor.
    # Keep all script errors fatal, and exempt only these exact unrelated engine messages.
    errors = [line for line in result.stdout.splitlines() if line.startswith("ERROR:")
              and not re.match(r"ERROR: \d+ (resources still in use|RID allocations)", line)
              and line != 'ERROR: EditorSettings not instantiated yet when getting setting "export/android/android_sdk_path".']
    if result.returncode or "SCRIPT ERROR:" in result.stdout or (errors and not expected_error):
        raise AssertionError(result.stdout)
    return result.stdout


def preset(project, enabled, mode, inline=False, scalar=False, read_types=0, allow_references=False):
    (project / "optimizer.yaml").write_text(
        f"structs: {str(enabled).lower()}\ninline_functions: {str(inline).lower()}\ndebug_tags: {str(inline).lower()}\n"
        f"scalar_replacement: {str(scalar).lower()}\nstruct_read_types: {('off', 'typed_locals', 'as_casts')[read_types]}\n"
        f"scalar_replacement_allow_ref_counted: {str(allow_references).lower()}\n"
        f"struct_read_types_allow_ref_counted: {str(allow_references).lower()}\n"
    )
    return f'''[preset.0]
name="Smoke"
platform="Linux"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="addons/*,excluded.gd"
script_export_mode={mode}

[preset.0.options]
optimization/optimize={str(enabled or inline).lower()}
optimization/config_file="res://optimizer.yaml"
'''


def hashes(project):
    return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in project.rglob("*.gd") if ".godot" not in p.parts}


def check_configuration(godot, project, before):
    cases = [
        ("defaults", True, "", None, False, True),
        ("partial-references", True, "optimizer.yaml", "scalar_replacement_allow_ref_counted: true\nstruct_read_types_allow_ref_counted: true\n", False, True),
        ("reference-casts", True, "res://optimizer.yaml", "scalar_replacement_allow_ref_counted: true\nstruct_read_types_allow_ref_counted: true\nstruct_read_types: as_casts\n", False, True),
        ("disabled", False, "res://missing.yaml", None, False, False),
        ("missing", True, "res://missing.yaml", None, True, False),
        ("invalid", True, "res://optimizer.yaml", "scalar_replacement: wrong\n", True, False),
        ("inactive", True, "res://optimizer.yaml", "structs: false\n", False, False),
    ]
    for name, enabled, path, config, error, structs in cases:
        settings = preset(project, True, 0).replace("optimization/optimize=true", f"optimization/optimize={str(enabled).lower()}")
        settings = settings.replace('optimization/config_file="res://optimizer.yaml"', f'optimization/config_file="{path}"')
        (project / "export_presets.cfg").write_text(settings)
        if config is not None:
            (project / "optimizer.yaml").write_text(config)
        archive = project.parent / f"{project.name}-config-{name}.zip"
        log = run(godot, project, "--export-pack", "Smoke", str(archive), expected_error=error)
        assert ("Exporting original code" in log) == error, log
        if name == "inactive":
            assert "options are inactive" in log, log
        with zipfile.ZipFile(archive) as package:
            rendered = package.read("references.gd").decode()
            if name in ("partial-references", "reference-casts"):
                assert "var record:" not in rendered and "_struct_opt_" in rendered, rendered
                assert "_struct_opt_read_" in rendered if name == "partial-references" else "as Payload)" in rendered
            if not enabled or error:
                assert rendered == (project / "references.gd").read_text()
        pack = archive.with_suffix(".pck")
        run(godot, project, "--export-pack", "Smoke", str(pack), expected_error=error)
        runtime = ["--main-pack", str(pack), "--script", "res://main.gd"]
        if structs:
            runtime += ["--", "optimized"]
        assert "OPTIMIZER_SMOKE_OK" in run(godot, project, *runtime)
        assert hashes(project) == before
        print(f"PASS config-{name}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--config-only", action="store_true", help="Run only configuration and reference export cases")
    parser.add_argument("--plugin-package", type=Path,
                        help="Test an exported addons/export_optimizer directory instead of development dependencies")
    args = parser.parse_args()
    project = Path(tempfile.mkdtemp(prefix="export-optimizer-smoke-"))
    print(f"Smoke project: {project}", flush=True)
    if args.plugin_package:
        shutil.copytree(args.plugin_package, project / "addons/export_optimizer")
        install_yaml_requirement(project)
    else:
        install_dependencies(project)
    for fixture in FIXTURES.glob("*.gd"):
        if fixture.name != "invalid_struct.gd":
            shutil.copy2(fixture, project / fixture.name)
    (project / "excluded.gd").write_text('extends RefCounted\nconst VALUE = 9\n')
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Optimizer Smoke"
[editor_plugins]
enabled=PackedStringArray("res://addons/export_optimizer/plugin.cfg")
[rendering]
renderer/rendering_method="gl_compatibility"
''')
    (project / "export_presets.cfg").write_text(preset(project, True, 0))
    run(args.godot, project, "--editor", "--import")
    uid = (project / "value.gd.uid").read_text().strip()
    user = project / "user.gd"
    user.write_text(user.read_text().replace('preload("value.gd")', f'preload("{uid}")'))
    run(args.godot, project, "--editor", "--import")
    before = hashes(project)
    check_configuration(args.godot, project, before)
    if args.config_only:
        return
    for enabled, mode, inline in [(True, 0, False), (True, 1, False), (True, 2, False),
                                  (False, 2, False), (False, 0, True), (True, 0, True),
                                  (True, 1, True), (True, 2, True)]:
        (project / "export_presets.cfg").write_text(preset(project, enabled, mode, inline))
        name = f"enabled-{enabled}-mode-{mode}-inline-{inline}"
        archive = project.parent / f"{project.name}-{name}.zip"
        run(args.godot, project, "--export-pack", "Smoke", str(archive))
        with zipfile.ZipFile(archive) as package:
            files = set(package.namelist())
            assert "excluded.gd" not in files, files
            assert not any(p.startswith("addons/") for p in files), files
            if enabled:
                assert "enum { X, Y }" in package.read("point.gd").decode()
                assert "class_name OptimizerSmokePoint" in package.read("point.gd").decode()
                assert '### GDScript Optimizer Structs' in package.read("blind.gd").decode()
                assert "main.gd" in files, files
            else:
                assert ("point.gdc" in files) == (mode != 0), files
            if inline:
                rendered = package.read("user.gd").decode()
                assert "return 2 * affine(value, 3)" not in rendered, rendered
                assert "if is_gdscript_path(path):" not in rendered, rendered
                assert "return value * scale + value - 3" in rendered, rendered
                assert "return expanded_vector(Vector2(2, 3), 2.0)" not in rendered, rendered
                assert "_inline_" in rendered, rendered
                assert "# optimizer-inline;" in rendered, rendered
                assert "return step()" not in rendered, rendered
                assert "var total := read_value(value)" not in rendered, rendered
                assert "User.read_value(value)" not in package.read("main.gd").decode()
                assert "User.expanded_vector(Vector2(2, 3), 2.0)" not in package.read("main.gd").decode()
                assert "User.affine(7, 3)" not in package.read("main.gd").decode()
                assert "OptimizerSmokeUser.affine(7, 3)" not in package.read("main.gd").decode()
        pack = archive.with_suffix(".pck")
        run(args.godot, project, "--export-pack", "Smoke", str(pack))
        runtime_args = ["--main-pack", str(pack), "--script", "res://main.gd"]
        if enabled:
            runtime_args += ["--", "optimized"]
        output = run(args.godot, project, *runtime_args)
        assert "OPTIMIZER_SMOKE_OK" in output, output
        assert hashes(project) == before, "Export changed project sources"
        print(f"PASS {name}", flush=True)
    for scalar, read_types, inline in [(s, r, i) for s in (False, True)
                                      for r in range(3) for i in (False, True) if s or r]:
        (project / "export_presets.cfg").write_text(preset(project, True, 0, inline, scalar, read_types))
        name = f"scalar-{scalar}-reads-{read_types}-inline-{inline}"
        archive = project.parent / f"{project.name}-{name}.zip"
        output = run(args.godot, project, "--export-pack", "Smoke", str(archive))
        assert "Exporting original code" not in output, output
        assert "struct stats=" in output, output
        with zipfile.ZipFile(archive) as package:
            rendered = package.read("user.gd").decode()
            if scalar:
                assert "_struct_opt_" in rendered and "var pair:" not in rendered, rendered
            if read_types == 1:
                assert "_struct_opt_read_" in rendered, rendered
            if read_types == 2:
                assert "as int)" in rendered, rendered
        pack = archive.with_suffix(".pck")
        run(args.godot, project, "--export-pack", "Smoke", str(pack))
        output = run(args.godot, project, "--main-pack", str(pack), "--script", "res://main.gd", "--", "optimized")
        assert "OPTIMIZER_SMOKE_OK" in output, output
        assert hashes(project) == before
        print(f"PASS {name}", flush=True)
    # Inspect the stored bytes: custom runtime templates are only needed to decrypt the pack.
    for pattern, encrypted in [("*.gd", True), ("*.gdc", False)]:
        settings = preset(project, True, 2).replace("[preset.0.options]", f'''encrypt_pck=true
encrypt_directory=false
encryption_include_filters="{pattern}"
encryption_exclude_filters=""
script_encryption_key="{'ab' * 32}"

[preset.0.options]''')
        (project / "export_presets.cfg").write_text(settings)
        pack = project.parent / f"{project.name}-encryption-{encrypted}.pck"
        run(args.godot, project, "--export-pack", "Smoke", str(pack))
        assert (b"enum { X, Y }" not in pack.read_bytes()) == encrypted
        assert hashes(project) == before, "Encrypted export changed project sources"
    print("PASS PCK encryption filters cover replacement .gd files", flush=True)
    shutil.copy2(FIXTURES / "invalid_struct.gd", project / "invalid.gd")
    (project / "export_presets.cfg").write_text(preset(project, True, 0, True, True, 2))
    failed = project.parent / f"{project.name}-fallback.zip"
    output = run(args.godot, project, "--export-pack", "Smoke", str(failed), expected_error=True)
    assert "Exporting original code; no optimizations were applied" in output, output
    with zipfile.ZipFile(failed) as package:
        assert package.read("point.gd").decode() == (project / "point.gd").read_text()
        assert package.read("user.gd").decode() == user.read_text()
    print("PASS invalid batch exports original code", flush=True)


if __name__ == "__main__":
    main()
