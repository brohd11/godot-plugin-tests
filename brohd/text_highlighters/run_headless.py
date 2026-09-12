#!/usr/bin/env python3
"""Test ALib text dispatch in isolated projects with and without GDSh's provider."""
import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

TEXT_MODULE = Path('addons/addon_lib/brohd/alib_runtime/misc/syntax_highlighters/text')
PROVIDER = Path('addons/addon_lib/gdsh/internal/script_highlighter_logic.gd')
TEST = Path('tests/brohd/text_highlighters/dispatcher_test.gd')


def run(command):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    output = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
    if result.returncode or 'ERROR:' in output or 'Parse Error:' in output:
        print(output, flush=True)
        raise RuntimeError('Godot validation failed')
    if '--editor' in command:
        print('PASS: project import', flush=True)
    elif '--export-pack' in command:
        print('PASS: project export', flush=True)
    else:
        print(output, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--export', action='store_true')
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    workspace = Path(tempfile.mkdtemp(prefix='alib-text-dispatch-'))
    print(f'Isolated projects: {workspace}', flush=True)
    try:
        for present in [False, True]:
            project = workspace / ('present' if present else 'absent')
            paths = [p.relative_to(repo) for p in (repo / TEXT_MODULE).rglob('*')
                     if p.suffix in ['.gd', '.uid']]
            paths.append(TEST)
            if present:
                # Copy only the standalone provider, not GDSh's namespace or other scripts.
                paths.append(PROVIDER)
            for path in paths:
                dest = project / path
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(repo / path, dest)
                uid = Path(str(path) + '.uid')
                if path.suffix == '.gd' and (repo / uid).exists():
                    shutil.copy2(repo / uid, project / uid)
            (project / 'project.godot').write_text(f'''config_version=5
[application]
config/name="ALib text dispatch tests"
[test]
provider_present={str(present).lower()}
[rendering]
renderer/rendering_method="gl_compatibility"
''')
            run([args.godot, '--headless', '--path', str(project), '--editor', '--import'])
            run([args.godot, '--headless', '--path', str(project), '--script', 'res://' + str(TEST)])
            if args.export:
                (project / 'export_presets.cfg').write_text('''[preset.0]
name="Runtime"
platform="Linux"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
script_export_mode=2
[preset.0.options]
binary_format/architecture="x86_64"
''')
                pack = project / 'runtime.pck'
                packed_run = project / 'packed_run'
                packed_run.mkdir()
                run([args.godot, '--headless', '--path', str(project), '--export-pack', 'Runtime', str(pack)])
                run([args.godot, '--headless', '--path', str(packed_run), '--main-pack', str(pack),
                     '--script', 'res://' + str(TEST)])
        print('PASS: optional GDSh provider and standalone ALib dispatch', flush=True)
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(workspace)


if __name__ == '__main__':
    raise SystemExit(main())
