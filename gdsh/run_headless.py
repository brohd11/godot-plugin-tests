#!/usr/bin/env python3
"""Build an isolated GDSh project and run its runtime tests (Python 3, Godot 4.6+)."""
import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--export', action='store_true', help='Also export and run the tests from a PCK with binary scripts')
    parser.add_argument('--keep', action='store_true', help='Keep the temporary project for inspection')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    module = Path('addons/addon_lib/gdsh')
    project = Path(tempfile.mkdtemp(prefix='gdsh-runtime-'))
    print(f'Isolated project: {project}', flush=True)
    try:
        uid_paths = {p.read_text().strip(): p.with_suffix('') for p in (repo / 'addons').rglob('*.uid')}
        pending = list((repo / module).rglob('*.gd')) + list((repo / 'tests/gdsh').rglob('*.gd'))
        visited = set()
        while pending:
            source = pending.pop()
            if source in visited:
                continue
            visited.add(source)
            rel = source.relative_to(repo)
            if 'editor_console' in rel.parts or 'alib_editor' in rel.parts:
                raise RuntimeError(f'Editor dependency: {rel}')
            dest = project / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, dest)
            uid = source.with_suffix(source.suffix + '.uid')
            if uid.exists():
                shutil.copy2(uid, dest.with_suffix(dest.suffix + '.uid'))
            for path in re.findall(r'(?:preload|load)\("([^"\n]+)"\)|extends\s+"([^"\n]+)"', source.read_text()):
                path = path[0] or path[1]
                if path.startswith('uid://'):
                    dependency = uid_paths.get(path)
                    if dependency is None:
                        raise RuntimeError(f'Unknown UID {path} in {rel}')
                elif path.startswith('res://'):
                    dependency = repo / path.removeprefix('res://')
                else:
                    continue
                if dependency.is_file():
                    pending.append(dependency)
        for source in (repo / 'tests/gdsh/fixtures').rglob('*'):
            if source.suffix in ['.gdsh', '.txt']:
                dest = project / source.relative_to(repo)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, dest)
        (project / 'project.godot').write_text('''config_version=5
[application]
config/name="GDSh runtime tests"
[rendering]
renderer/rendering_method="gl_compatibility"
''')
        commands = [
            [args.godot, '--headless', '--path', str(project), '--editor', '--import'],
            [args.godot, '--headless', '--path', str(project), '--script', 'res://tests/gdsh/runtime_test.gd'],
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
                [args.godot, '--headless', '--path', str(packed_run), '--main-pack', str(pack), '--script', 'res://tests/gdsh/runtime_test.gd'],
            ])
        for command in commands:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
            quiet = ('--editor' in command or '--export-pack' in command) and not result.returncode and 'ERROR:' not in result.stdout
            print(('PASS: project export' if '--export-pack' in command else 'PASS: project import') if quiet else re.sub(r'\x1b\[[0-9;]*m', '', result.stdout), flush=True)
            if result.returncode or 'SCRIPT ERROR:' in result.stdout or 'Parse Error:' in result.stdout:
                return 1
        print(f'PASS: runtime isolation; {len(visited)} scripts, no Editor Console/editor addon imports')
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(project)


if __name__ == '__main__':
    raise SystemExit(main())
