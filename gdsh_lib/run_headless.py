#!/usr/bin/env python3
"""Build an isolated project with GDSh and the gdsh_lib utils and tree libs and run their runtime tests (Python 3, Godot 4.6+)."""
import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

MODULES = [Path('addons/addon_lib/gdsh'), Path('addons/addon_lib/gdsh_lib/utils'), Path('addons/addon_lib/gdsh_lib/tree'), Path('tests/gdsh_lib')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--export', action='store_true', help='Also export and run the tests from a PCK with binary scripts')
    parser.add_argument('--keep', action='store_true', help='Keep the temporary project for inspection')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    project = Path(tempfile.mkdtemp(prefix='gdsh-lib-runtime-'))
    print(f'Isolated project: {project}', flush=True)
    try:
        for module in MODULES:
            shutil.copytree(repo / module, project / module,
                            ignore=shutil.ignore_patterns('.git', 'export_ignore', '__pycache__', '*.py'))
        # Every script dependency must stay inside the copied modules.
        uid_paths = {p.read_text().strip(): p.with_suffix('') for p in (repo / 'addons').rglob('*.uid')}
        scripts = list(project.rglob('*.gd'))
        for source in scripts:
            for path in re.findall(r'(?:preload|load)\("([^"\n]+)"\)|extends\s+"([^"\n]+)"', source.read_text()):
                path = path[0] or path[1]
                if path.startswith('uid://'):
                    dependency = uid_paths.get(path)
                    if dependency is None:
                        raise RuntimeError(f'Unknown UID {path} in {source.relative_to(project)}')
                    path = str(dependency.relative_to(repo))
                elif path.startswith('res://'):
                    path = path.removeprefix('res://')
                else:
                    continue
                if not any(Path(path).is_relative_to(module) for module in MODULES):
                    raise RuntimeError(f'External dependency {path} in {source.relative_to(project)}')
        (project / 'project.godot').write_text('''config_version=5
[application]
config/name="GDSh utils runtime tests"
[rendering]
renderer/rendering_method="gl_compatibility"
''')
        test = 'res://tests/gdsh_lib/runtime_test.gd'
        commands = [
            [args.godot, '--headless', '--path', str(project), '--editor', '--import'],
            [args.godot, '--headless', '--path', str(project), '--script', test],
        ]
        if args.export:
            (project / 'export_presets.cfg').write_text('''[preset.0]
name="Runtime"
platform="Linux"
runnable=true
export_filter="all_resources"
include_filter="*.gdsh,*.txt"
exclude_filter=""
script_export_mode=2
[preset.0.options]
binary_format/architecture="x86_64"
''')
            pack = project / 'runtime.pck'
            packed_run = project / 'packed_run'
            packed_run.mkdir()
            commands.extend([
                [args.godot, '--headless', '--path', str(project), '--export-pack', 'Runtime', str(pack)],
                [args.godot, '--headless', '--path', str(packed_run), '--main-pack', str(pack), '--script', test],
            ])
        for command in commands:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            quiet = ('--editor' in command or '--export-pack' in command) and not result.returncode and 'ERROR:' not in result.stdout
            print(('PASS: project export' if '--export-pack' in command else 'PASS: project import') if quiet else re.sub(r'\x1b\[[0-9;]*m', '', result.stdout), flush=True)
            if result.returncode or 'SCRIPT ERROR:' in result.stdout or 'Parse Error:' in result.stdout:
                return 1
        print(f'PASS: runtime isolation; {len(scripts)} scripts, only GDSh, gdsh_lib utils, and their tests')
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(project)


if __name__ == '__main__':
    raise SystemExit(main())
