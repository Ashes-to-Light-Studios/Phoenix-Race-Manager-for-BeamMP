#!/usr/bin/env python3
"""Cut a release: the version YOU name, on the branch you are on.

    python tools/release.py 0.28.5 "Short title"
    python tools/release.py 0.28.5 "Short title" --dry-run     say what, write nothing
    python tools/release.py 0.28.5 "Short title" --no-commit   leave it for review

Sets the seven build stamps, turns "## Unreleased" in CHANGELOG.md into
"## 0.28.5 - Short title", rebuilds package/ (deploy.py --build-only), runs
every tests/*_test.lua and commits. Nothing is committed if a test fails.

Merging that commit to main publishes it: package.yml tags vX.Y.Z on the merge
and releases it. The number is never worked out here: versions are chosen by
hand, jumps included.

Run from anywhere; paths are relative to the repo root.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The seven stamps package.yml checks before it builds. (path, pattern, format)
STAMPS = [
    ('server/RaceManager/main.lua', r"^local RM_BUILD = '([^']*)'", "local RM_BUILD = '{v}'"),
    ('lua/ge/extensions/raceManager.lua', r"^local RM_BUILD = '([^']*)'", "local RM_BUILD = '{v}'"),
    ('ui/modules/apps/RaceManager/app.js', r"APP_BUILD = '([^']*)';", "APP_BUILD = '{v}';"),
    ('ui/modules/apps/RaceManager/app.json', r'"version": "([^"]*)",', '"version": "{v}",'),
    ('ui/modules/apps/RaceManagerLights/app.json', r'"version": "([^"]*)",', '"version": "{v}",'),
    ('ui/modules/apps/RaceManagerRadar/app.json', r'"version": "([^"]*)",', '"version": "{v}",'),
    ('tools/deploy.py', r"^RELEASE_NAME = 'RaceManager-v([^']*)\.zip'", "RELEASE_NAME = 'RaceManager-v{v}.zip'"),
]
CHANGELOG = 'CHANGELOG.md'


def die(msg):
    print('release: ' + msg, file=sys.stderr)
    sys.exit(1)


def git(*args, check=True):
    r = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)
    if check and r.returncode != 0:
        die('git ' + ' '.join(args) + ' failed: ' + r.stderr.strip())
    return r.stdout.strip()


# newline='' keeps each file's own line endings.
def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(os.path.join(ROOT, path), 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def vkey(v):
    return tuple(int(p) for p in v.split('.'))


def stamped(version):
    """Each stamp's file with the version swapped in. Exactly one match each,
    or the pattern has drifted from the file and package.yml would refuse it."""
    out, current = {}, set()
    for path, pattern, fmt in STAMPS:
        text = read(path)
        rx = re.compile(pattern, re.M)
        hits = rx.findall(text)
        if len(hits) != 1:
            die(f'{path}: expected one version stamp, found {len(hits)}')
        current.add(hits[0])
        out[path] = rx.sub(lambda _m: fmt.format(v=version), text, count=1)
    return out, current


def titled(version, title):
    text = read(CHANGELOG)
    # The line ending is left out of the match, so it survives the swap.
    m = re.search(r'^## Unreleased[ \t]*(?=\r?$)', text, re.M)
    if not m:
        die(f'{CHANGELOG} has no "## Unreleased" section to release')
    rest = text[m.end():]
    nxt = re.search(r'^## ', rest, re.M)
    body = rest[:nxt.start()] if nxt else rest
    if not body.strip():
        die(f'the Unreleased section of {CHANGELOG} is empty')
    if re.search(r'^## ' + re.escape(version) + ' ', text, re.M):
        die(f'{CHANGELOG} already has a {version} section')
    return text[:m.start()] + f'## {version} - {title}' + text[m.end():]


def run_tests():
    lua = next((shutil.which(n) for n in ('lua', 'lua5.4', 'lua5.3') if shutil.which(n)), None)
    if not lua:
        die('no lua on PATH to run the tests (or pass --no-tests)')
    tests = sorted(f for f in os.listdir(os.path.join(ROOT, 'tests')) if f.endswith('_test.lua'))
    failed = []
    print(f'running {len(tests)} test files...')
    for t in tests:
        r = subprocess.run([lua, os.path.join('tests', t)], cwd=ROOT,
                           capture_output=True, text=True, encoding='utf-8', errors='replace')
        out = r.stdout + r.stderr
        bad = [l for l in out.splitlines() if l.startswith('FAIL')]
        if r.returncode != 0 or bad:
            failed.append(t)
            print(f'  FAILED {t}')
            for l in (bad or out.splitlines()[-5:])[:5]:
                print('    ' + l)
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('version', help='X.Y.Z, as you want it released')
    ap.add_argument('title', help='the release title, e.g. "Spectators see the race"')
    ap.add_argument('--dry-run', action='store_true', help='say what would change, write nothing')
    ap.add_argument('--no-commit', action='store_true', help='make the changes, do not commit')
    ap.add_argument('--no-tests', action='store_true', help='skip the test suite')
    ap.add_argument('--allow-main', action='store_true', help='commit straight onto main')
    a = ap.parse_args()

    v, title = a.version.strip(), a.title.strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', v):
        die(f'"{v}" is not X.Y.Z')
    if not title or '\n' in title:
        die('the title must be one non-empty line')

    branch = git('branch', '--show-current')
    if branch == 'main' and not a.allow_main and not a.dry_run:
        die('on main: release on the PR branch, or pass --allow-main')
    if git('status', '--porcelain') and not a.dry_run:
        die('the working tree is not clean: commit or stash first')
    if git('tag', '-l', 'v' + v) or git('ls-remote', '--tags', 'origin', 'refs/tags/v' + v, check=False):
        die(f'v{v} is already tagged')

    files, current = stamped(v)
    if current == {v}:
        die(f'the stamps already say {v}')
    if len(current) > 1:
        print(f'note: the stamps disagreed ({", ".join(sorted(current))}); all become {v}')
    was = max(current, key=vkey)
    if vkey(v) <= vkey(was):
        print(f'note: {v} is not above the current {was}')
    log = titled(v, title)

    print(f'release {was} -> {v} "{title}" on {branch or "a detached HEAD"}')
    if a.dry_run:
        for path in files:
            print('  would stamp ' + path)
        print(f'  would title {CHANGELOG}, rebuild package/, run the tests and commit')
        return

    for path, text in files.items():
        write(path, text)
    write(CHANGELOG, log)

    r = subprocess.run([sys.executable, os.path.join('tools', 'deploy.py'), '--build-only'], cwd=ROOT)
    if r.returncode != 0:
        die('deploy.py --build-only failed; nothing committed (git restore . to undo)')

    if not a.no_tests:
        failed = run_tests()
        if failed:
            die(f'{len(failed)} test file(s) failed; nothing committed (git restore . to undo)')
        print('all tests pass')

    if a.no_commit:
        print('changes made, not committed')
        return
    git('add', '--', CHANGELOG, 'package', *[p for p, _, _ in STAMPS])
    git('commit', '-q', '-m', f'Release {v}: {title}', '-m',
        f'All seven build stamps to {v}, the CHANGELOG section titled, package/ rebuilt.')
    print(f'committed {git("rev-parse", "--short", "HEAD")}. Push and merge the PR: '
          f'the merge to main publishes v{v}.')


if __name__ == '__main__':
    main()
