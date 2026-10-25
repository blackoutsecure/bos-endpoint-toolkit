import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { build } from '../build.mjs';
import { defaults, serviceRoot } from '../configuration.mjs';

async function fixture(action) {
  const directory = await mkdtemp(join(tmpdir(), 'bos-endpoint-build-'));
  try {
    await action(pathToFileURL(`${directory}${sep}`));
  } finally {
    await rm(directory, { recursive: true });
  }
}

async function inventory(directory, prefix = '') {
  const result = {};
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const name = `${prefix}${entry.name}`;
    const target = new URL(entry.name + (entry.isDirectory() ? '/' : ''), directory);
    if (entry.isDirectory()) Object.assign(result, await inventory(target, `${name}/`));
    else result[name] = createHash('sha256').update(await readFile(target)).digest('hex');
  }
  return result;
}

test('standalone packages embed defaults, validators, and the single authored worker', async () => {
  await fixture(async output => {
    await build({ output });
    for (const path of ['windows/detect-devbox.ps1', 'windows/remediate-devbox.ps1', 'macos/manage-devbox.sh']) {
      const source = await readFile(new URL(path, output), 'utf8');
      assert.doesNotMatch(source, /# >>> devbox:|DEVBOX_DEFAULTS_JSON=''|source "\$SCRIPT_DIRECTORY\/configuration.sh"/);
      assert.equal(source.includes('\r'), false);
      assert.match(source, /schemaVersion/);
    }
    const worker = (await readFile(new URL('windows/devbox-worker.ps1', serviceRoot), 'utf8')).replaceAll('\r\n', '\n').trimEnd();
    const remediation = await readFile(new URL('windows/remediate-devbox.ps1', output), 'utf8');
    assert.ok(remediation.includes(`$WorkerSource = @'\n${worker}\n'@`));
    assert.deepEqual(JSON.parse(await readFile(new URL('desired-config.json', output), 'utf8')), defaults);
  });
});

test('builds are deterministic across repeated invocations', async () => {
  await fixture(async output => {
    await build({ output });
    const first = await inventory(output);
    await build({ output });
    assert.deepEqual(await inventory(output), first);
  });
});

test('deployment profiles are schema-validated before artifacts are written', async () => {
  await fixture(async output => {
    await assert.rejects(build({ output, configuration: { schemaVersion: 1, retention: -1 } }), /Invalid/);
    assert.deepEqual(await readdir(output), []);
    await build({ output, configuration: { schemaVersion: 1, retention: 21, windows: { sizeGiB: 200 } } });
    const config = JSON.parse(await readFile(new URL('desired-config.json', output), 'utf8'));
    assert.equal(config.retention, 21);
    assert.equal(config.windows.sizeGiB, 200);
    assert.equal(config.macos.sizeGB, 100);
  });
});

test('explicit false-like and non-object profiles cannot silently select defaults', async () => {
  await fixture(async output => {
    for (const configuration of [null, false, 0, '', [], [{ schemaVersion: 1 }]]) {
      await assert.rejects(build({ output, configuration }), /Invalid Devbox configuration/);
      assert.deepEqual(await readdir(output), []);
    }
  });
});

test('macOS package stages a user LaunchAgent, not root user-data initialization', async () => {
  await fixture(async output => {
    await build({ output });
    const root = new URL('macos/package-root/', output);
    const agent = await readFile(new URL('Library/LaunchAgents/com.blackoutsecure.devbox.initialize.plist', root), 'utf8');
    assert.match(agent, /LimitLoadToSessionType/);
    assert.match(agent, /Aqua/);
    assert.match(agent, /--config/);
    assert.doesNotMatch(agent, /<key>UserName<\/key>|<string>root<\/string>|LaunchDaemons|sudo/);
    assert.ok((await readFile(new URL('usr/local/libexec/bos-endpoint-toolkit/devbox/manage-devbox.sh', root), 'utf8')).startsWith('#!/bin/bash\n'));
    assert.deepEqual(JSON.parse(await readFile(new URL('Library/Application Support/BlackoutSecure/EndpointToolkit/devbox/desired-config.json', root), 'utf8')), defaults);
    assert.ok((await readFile(new URL('usr/local/share/doc/bos-endpoint-toolkit/devbox/LICENSE', root), 'utf8')).includes('Apache'));
  });
});

test('rebuilding a package with a new agent prefix does not retain stale agents', async () => {
  await fixture(async output => {
    await build({ output });
    await build({ output, configuration: { schemaVersion: 1, macos: { launchdPrefix: 'com.example.devbox' } } });
    const agents = await readdir(new URL('macos/package-root/Library/LaunchAgents/', output));
    assert.deepEqual(agents, ['com.example.devbox.initialize.plist']);
  });
});
