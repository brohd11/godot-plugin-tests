#!/usr/bin/env python3
"""Import Editor Console in a disposable project and check its GDSh integration."""
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    project = Path(tempfile.mkdtemp(prefix='editor-console-tests-'))
    print(f'Isolated project: {project}', flush=True)
    try:
        for directory in ['addons/addon_lib', 'addons/editor_console', 'addons/zyx_popup_wrapper', 'tests/editor_console']:
            shutil.copytree(repo / directory, project / directory,
                            ignore=shutil.ignore_patterns('.git', 'export_ignore', '__pycache__'))
        (project / 'project.godot').write_text('''config_version=5
[application]
config/name="Editor Console integration tests"
[rendering]
renderer/rendering_method="gl_compatibility"
''')
        commands = [
            [args.godot, '--headless', '--path', str(project), '--editor', '--import'],
            [args.godot, '--headless', '--path', str(project), '--script', 'res://tests/editor_console/runtime_test.gd'],
        ]
        for command in commands:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            if result.returncode or 'SCRIPT ERROR:' in result.stdout or 'Parse Error:' in result.stdout:
                print(result.stdout)
                return 1
            print('PASS: isolated import' if '--import' in command else result.stdout, flush=True)
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(project)


if __name__ == '__main__':
    raise SystemExit(main())
