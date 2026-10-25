import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { root } from '../configuration.mjs';

const bash = process.env.BOS_BASH ?? (process.platform === 'win32'
  ? join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe') : 'bash');
let source = (await readFile(new URL('tools/package-macos.sh', root), 'utf8')).replaceAll('\r\n', '\n');
const rootAssignment = 'ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"';
assert.ok(source.includes(rootAssignment));
source = source.replace(rootAssignment, 'ROOT="$PWD"');
for (const [command, mock] of Object.entries({
  '/usr/bin/uname': 'mock_uname',
  '/usr/bin/plutil': 'mock_plutil',
  '/usr/bin/ditto': 'mock_ditto',
  '/usr/bin/pkgbuild': 'mock_pkgbuild',
  '/usr/bin/xcrun': 'mock_xcrun',
  '/usr/sbin/pkgutil': 'mock_pkgutil',
  '/usr/sbin/spctl': 'mock_spctl'
})) {
  assert.ok(source.includes(command));
  source = source.replaceAll(command, mock);
}

const mocks = `
set -euo pipefail
export TMPDIR="$PWD/unrelated-tmp"
mkdir -p "$TMPDIR"
trace_step(){
  printf '%s\\n' "$1" >> package-trace.txt
  [[ "\${FAIL_STEP:-}" != "$1" ]]
}
mock_uname(){ printf 'Darwin\\n'; }
mock_plutil(){ printf '3.6.0\\n'; }
mock_ditto(){ mkdir -p "$2"; cp -R "$1/." "$2"; }
mock_pkgbuild(){
  trace_step pkgbuild || return 21
  local output
  for output in "$@"; do :; done
  [[ "$(dirname "$(dirname "$output")")" == "$ROOT/output/devbox/macos" ]] || {
    printf 'ERROR: Package staging is not beside its publication target.\\n' >&2
    return 22
  }
  printf 'fixture package\\n' > "$output"
}
mock_xcrun(){ trace_step "$1:$2"; }
mock_pkgutil(){ trace_step signature; }
mock_spctl(){ trace_step assessment; }
`;

async function fixture(action) {
  const directory = await mkdtemp(join(tmpdir(), 'bos-endpoint-package-'));
  try {
    await mkdir(join(directory, 'output', 'devbox', 'macos', 'package-root'), { recursive: true });
    const run = (args, failure = '') => {
      const result = spawnSync(bash, ['--noprofile', '--norc', '-s', '--', ...args], {
        cwd: directory,
        input: mocks + source,
        encoding: 'utf8',
        env: { ...process.env, FAIL_STEP: failure },
        timeout: 120000
      });
      if (result.error) throw result.error;
      return result;
    };
    await action(directory, run);
  } finally {
    await rm(directory, { recursive: true });
  }
}

const releaseArgs = ['--sign', 'Developer ID Installer: Fixture', '--notary-profile', 'fixture-profile'];

test('package staging stays beside the output even when TMPDIR points elsewhere', async () => {
  await fixture(async (_directory, run) => {
    const result = run(releaseArgs);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Signed, notarized, stapled package:/);
  });
});

test('release packaging publishes only after notarization, stapling, and verification succeed', async () => {
  await fixture(async (directory, run) => {
    const result = run(releaseArgs);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Signed, notarized, stapled package:/);
    assert.equal(await readFile(join(directory, 'output/devbox/macos/bos-devbox-3.6.0.pkg'), 'utf8'), 'fixture package\n');
    assert.equal(await readFile(join(directory, 'package-trace.txt'), 'utf8'),
      'pkgbuild\nnotarytool:submit\nstapler:staple\nsignature\nassessment\n');
  });
});

test('each failed release gate preserves the previous published artifact', async () => {
  for (const failure of ['pkgbuild', 'notarytool:submit', 'stapler:staple', 'signature', 'assessment']) {
    await fixture(async (directory, run) => {
      const published = join(directory, 'output/devbox/macos/bos-devbox-3.6.0.pkg');
      await writeFile(published, 'previous validated artifact\n');
      const result = run(releaseArgs, failure);
      assert.notEqual(result.status, 0, failure);
      assert.doesNotMatch(result.stdout, /Signed, notarized, stapled package:/);
      assert.equal(await readFile(published, 'utf8'), 'previous validated artifact\n', failure);
      const steps = (await readFile(join(directory, 'package-trace.txt'), 'utf8')).trim().split('\n');
      assert.equal(steps.at(-1), failure);
    });
  }
});

test('unsigned packages are separate and signing options cannot silently downgrade to unsigned', async () => {
  await fixture(async (directory, run) => {
    const result = run(['--unsigned']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /UNSIGNED validation package only/);
    assert.equal(await readFile(join(directory, 'output/devbox/macos/bos-devbox-3.6.0-unsigned.pkg'), 'utf8'), 'fixture package\n');
    assert.equal(await readFile(join(directory, 'package-trace.txt'), 'utf8'), 'pkgbuild\n');
    for (const args of [[], ['--sign'], ['--notary-profile'], ['--unsigned', ...releaseArgs]]) {
      assert.notEqual(run(args).status, 0);
    }
  });
});
