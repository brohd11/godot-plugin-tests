"""Benchmark actual exported variants; timings exclude process startup and warmup."""

import argparse
import json
import math
from pathlib import Path
import re
import shutil
import statistics
import tempfile
import zipfile

from export_smoke import FIXTURES, hashes, install_dependencies, preset, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot 4.6+ editor used to export")
    parser.add_argument("--release-runtime", help="Optional matching release template executable")
    parser.add_argument("--iterations", type=int, default=200000)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--output", type=Path, help="New output directory; defaults to a temporary directory")
    args = parser.parse_args()
    if args.iterations < 1 or args.samples < 1:
        parser.error("iterations and samples must be positive")
    output = args.output or Path(tempfile.mkdtemp(prefix="export-optimizer-benchmark-"))
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    project.mkdir()
    print(f"Benchmark project: {project}", flush=True)
    install_dependencies(project)
    for source in (FIXTURES / "benchmark").glob("*.gd"):
        shutil.copy2(source, project / source.name)
    (project / "main.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://main.gd" id="1"]
[node name="Benchmark" type="Node"]
script = ExtResource("1")
''')
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Export Optimizer Benchmark"
run/main_scene="res://main.tscn"
[editor_plugins]
enabled=PackedStringArray("res://addons/export_optimizer/plugin.cfg")
[rendering]
renderer/rendering_method="gl_compatibility"
''')
    run(args.godot, project, "--editor", "--import")
    before = hashes(project)
    variants = []
    for inline in (False, True):
        variants.append((f"objects-inline{int(inline)}", False, False, 0, inline))
        for scalar in (False, True):
            for mode in range(3):
                name = f"structs-scalar{int(scalar)}-reads{mode}-inline{int(inline)}"
                variants.append((name, True, scalar, mode, inline))
    metadata = {}
    for name, structs, scalar, mode, inline in variants:
        directory = output / name
        directory.mkdir()
        (project / "export_presets.cfg").write_text(preset(structs, 0, inline, scalar, mode))
        archive = directory / "source.zip"
        log = run(args.godot, project, "--export-pack", "Smoke", str(archive))
        assert "Exporting original code" not in log, log
        (directory / "export.log").write_text(log)
        with zipfile.ZipFile(archive) as package:
            for file in ("workloads.gd", "main.gd"):
                (directory / file).write_bytes(package.read(file))
        run(args.godot, project, "--export-pack", "Smoke", str(directory / "benchmark.pck"))
        assert hashes(project) == before, "Export modified source files"
        stats_match = re.search(r"struct stats=(\{[^\n]+\})", log)
        metadata[name] = {"structs": structs, "scalar": scalar, "read_types": mode,
                          "inline": inline, "stats": json.loads(stats_match[1]) if stats_match else {}}
        print(f"Exported {name}", flush=True)
    runtime = args.release_runtime or args.godot
    samples = {name: [] for name in metadata}
    checksums = {}
    names = list(metadata)
    for trial in range(args.samples + 1):
        rotated = names[trial % len(names):] + names[:trial % len(names)]
        if trial % 2:
            rotated.reverse()
        for name in rotated:
            log = run(runtime, project, "--main-pack", str(output / name / "benchmark.pck"),
                      "--", str(args.iterations))
            payload = next(line.removeprefix("BENCH_RESULT ") for line in log.splitlines()
                           if line.startswith("BENCH_RESULT "))
            result = json.loads(payload)
            for case, data in result["cases"].items():
                expected = checksums.setdefault(case, data["checksum"])
                assert math.isclose(data["checksum"], expected, rel_tol=1e-12, abs_tol=1e-9), (name, case, data, expected)
            if trial:
                samples[name].append(result)
        print("Validated all checksums" if trial == 0 else f"Completed sample {trial}/{args.samples}", flush=True)
    summaries = {}
    for name, trials in samples.items():
        summaries[name] = {}
        for case in checksums:
            timings = [trial["cases"][case]["usec"] for trial in trials]
            summaries[name][case] = {"median_usec": statistics.median(timings),
                                     "min_usec": min(timings), "max_usec": max(timings)}
    rows = ["# Struct optimization benchmark", "", f"Runtime: `{runtime}`",
            f"Engine: {result['engine']}; editor={result['editor']}; debug={result['debug']}",
            f"Iterations: {args.iterations}; samples: {args.samples}", "",
            "| Variant | Workload | Median µs | Min–max µs | vs objects | vs struct baseline |",
            "|---|---|---:|---:|---:|---:|"]
    for name, cases in summaries.items():
        inline = int(metadata[name]["inline"])
        for case, summary in cases.items():
            median = summary["median_usec"]
            summary["speedup_objects"] = summaries[f"objects-inline{inline}"][case]["median_usec"] / max(median, 1)
            summary["speedup_structs"] = summaries[f"structs-scalar0-reads0-inline{inline}"][case]["median_usec"] / max(median, 1)
            rows.append(f"| {name} | {case} | {median:g} | {summary['min_usec']}–{summary['max_usec']} | "
                        f"{summary['speedup_objects']:.2f}× | {summary['speedup_structs']:.2f}× |")
    (output / "results.json").write_text(json.dumps({"runtime": runtime, "metadata": metadata,
                                                    "samples": samples, "summary": summaries}, indent=2))
    (output / "report.md").write_text("\n".join(rows) + "\n")
    print(f"Results: {output / 'report.md'}", flush=True)


if __name__ == "__main__":
    main()
