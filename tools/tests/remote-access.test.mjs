import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import { buildRemoteAccess, remoteAccess, remoteAccessRoot } from '../build-remote-access.mjs';
import { configurationFields } from '../configuration.mjs';

async function fixture(action) {
  const directory = await mkdtemp(join(tmpdir(), 'bos-remote-access-'));
  try {
    await action(pathToFileURL(`${directory}${sep}`));
  } finally {
    await rm(directory, { recursive: true });
  }
}

function checkedRun(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 120000, ...options });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result;
}

test('remote-access defaults and all native descriptor leaves share a validated source', () => {
  remoteAccess.validateConfiguration(remoteAccess.defaults);
  assert.equal(remoteAccess.service.name, 'ghostbsd-remote-access');
  assert.equal(remoteAccess.defaults.sshPort, 22);
  assert.equal(remoteAccess.defaults.rdpPort, 3389);
  assert.equal(remoteAccess.defaults.hostSshPort, 2222);
  assert.deepEqual(configurationFields(remoteAccess.schema).map(field => field.path).sort(), Object.keys(remoteAccess.defaults).sort());
  for (const field of ['sshPort', 'rdpPort', 'hostSshPort', 'localRdpPort']) {
    for (const value of [0, 65536, -1, 1.5, '22', false]) {
      assert.throws(() => remoteAccess.validateConfiguration({ schemaVersion: 1, [field]: value }), /Invalid/);
    }
    for (const value of [1, 65535]) remoteAccess.validateConfiguration({ schemaVersion: 1, [field]: value });
  }
});

test('remote-access profiles fail before writing artifacts, including invalid identifiers and port collisions', async () => {
  await fixture(async output => {
    const invalid = [
      null, false, [], {}, { schemaVersion: 2 }, { schemaVersion: '1' },
      { schemaVersion: 1, username: 'personal-account' },
      { schemaVersion: 1, platform: 'linux' }, { schemaVersion: 1, platform: 'auto\n' },
      { schemaVersion: 1, hostName: '-oProxyCommand=bad' },
      { schemaVersion: 1, hostName: 'host; command' }, { schemaVersion: 1, hostName: 'localhost\n' },
      { schemaVersion: 1, sshPort: 3389 }, { schemaVersion: 1, videoMemoryMiB: 257 }
    ];
    for (const configuration of invalid) {
      await assert.rejects(buildRemoteAccess({ output, configuration }), /Invalid|line breaks|different guest ports/);
      assert.deepEqual(await readdir(output), []);
    }
  });
});

test('standalone operator embeds the exact generated guest, with deterministic profiles and legal files', async () => {
  await fixture(async output => {
    const configuration = { schemaVersion: 1, platform: 'hyperv', hostSshPort: 22, rdpPort: 3390 };
    await buildRemoteAccess({ output, configuration });
    const guest = await readFile(new URL('ghostbsd/manage-remote-access.sh', output), 'utf8');
    const windows = await readFile(new URL('windows/manage-remote-access.ps1', output), 'utf8');
    assert.equal(Buffer.from(windows.match(/\$RemoteAccessGuestBase64 = '([A-Za-z0-9+/=]+)'/)[1], 'base64').toString('utf8'), guest);
    assert.match(windows, /\[int\]\$SshPort = 22/);
    assert.match(guest, /RDP_PORT='3390'/);
    for (const source of [guest, windows]) {
      assert.doesNotMatch(source, /# >>> ghostbsd-remote-access:|\r/);
      assert.doesNotMatch(source, /discardstate|savestate|acpipowerbutton|ExecutionPolicy Bypass|ipfw[^\n]*flush/);
    }
    for (const platform of ['ghostbsd', 'windows']) {
      assert.match(await readFile(new URL(`${platform}/LICENSE`, output), 'utf8'), /Apache/);
      assert.ok((await readFile(new URL(`${platform}/NOTICE`, output), 'utf8')).length > 0);
    }
    const desired = JSON.parse(await readFile(new URL('desired-config.json', output), 'utf8'));
    assert.equal(desired.platform, 'hyperv');
    assert.equal(desired.localRdpPort, remoteAccess.defaults.localRdpPort);
    await buildRemoteAccess({ output, configuration });
    assert.equal(await readFile(new URL('ghostbsd/manage-remote-access.sh', output), 'utf8'), guest);
    assert.equal(await readFile(new URL('windows/manage-remote-access.ps1', output), 'utf8'), windows);
  });
});

test('guest contracts use only private files and mocked native boundaries', async () => {
  await fixture(async output => {
    await buildRemoteAccess({ output });
    const bash = process.env.BOS_BASH ?? (process.platform === 'win32'
      ? join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe') : 'bash');
    const contracts = await readFile(new URL('ghostbsd/tests/contracts.sh', remoteAccessRoot), 'utf8');
    const result = checkedRun(bash, ['--noprofile', '--norc', '-s', '--', fileURLToPath(new URL('ghostbsd/manage-remote-access.sh', output))], {
      input: contracts.replaceAll('\r\n', '\n')
    });
    assert.match(result.stdout, /PASS guest read-only, preview, failure, configuration, session, and key contracts/);
  });
});

test('Windows operator contracts never call a real VM or remote host', { skip: process.platform !== 'win32' }, async () => {
  await fixture(async output => {
    await buildRemoteAccess({ output });
    const result = checkedRun('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('windows/tests/contracts.ps1', remoteAccessRoot)),
      '-ScriptPath', fileURLToPath(new URL('windows/manage-remote-access.ps1', output))
    ]);
    assert.match(result.stdout, /PASS Windows argument, preview, VM, NAT, and tunnel-ownership contracts/);
  });
});
