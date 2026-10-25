import assert from 'node:assert/strict';
import test from 'node:test';
import { configurationFields, defaults, mergeConfiguration, validateConfiguration } from '../configuration.mjs';

test('shared defaults preserve native units, schedule, retention, and workspace folders', () => {
  validateConfiguration(defaults);
  assert.equal(defaults.windows.sizeGiB * 1024 ** 3, 107374182400);
  assert.equal(Math.ceil(defaults.macos.sizeGB * 1e9 / 4096) * 4096, 100000002048);
  assert.equal(defaults.backupHour, 2);
  assert.equal(defaults.backupMinute, 0);
  assert.equal(defaults.retention, 14);
  assert.equal(defaults.workspaceDirectories.length, 12);
});

test('partial profiles override leaves, not unrelated platform settings', () => {
  const profile = { schemaVersion: 1, retention: 21, macos: { hideVolume: true } };
  const merged = mergeConfiguration(defaults, validateConfiguration(profile));
  validateConfiguration(merged);
  assert.equal(merged.retention, 21);
  assert.equal(merged.macos.hideVolume, true);
  assert.equal(merged.macos.sizeGB, 100);
  assert.deepEqual(merged.windows, defaults.windows);
  assert.equal(defaults.retention, 14);
});

test('schema rejects invalid, misspelled, unsafe, and unsupported values', () => {
  const invalid = [
    {}, null, [], { schemaVersion: 2 }, { schemaVersion: '1' },
    { schemaVersion: 1, retension: 14 }, { schemaVersion: 1, windows: { sizeGB: 100 } },
    { schemaVersion: 1, name: '../escape' }, { schemaVersion: 1, name: 'DEVBOX' },
    { schemaVersion: 1, name: 'devbox\n' },
    { schemaVersion: 1, windows: { volumeLabel: 'devbox\n' } },
    { schemaVersion: 1, workspaceDirectories: ['repos\n'] },
    { schemaVersion: 1, backupHour: 24 }, { schemaVersion: 1, backupMinute: -1 },
    { schemaVersion: 1, retention: 0 }, { schemaVersion: 1, retention: 1.5 },
    { schemaVersion: 1, windows: { sizeGiB: 49 } },
    { schemaVersion: 1, macos: { sizeGB: 65537 } },
    { schemaVersion: 1, macos: { hideVolume: 'true' } },
    { schemaVersion: 1, macos: null },
    { schemaVersion: 1, workspaceDirectories: ['repos', 'repos'] },
    { schemaVersion: 1, workspaceDirectories: ['../repos'] },
    { schemaVersion: 1, workspaceDirectories: [] },
    { schemaVersion: 1, windows: { preferredDriveLetters: ['v'] } }
  ];
  for (const value of invalid) assert.throws(() => validateConfiguration(value), /Invalid Devbox configuration/);
});

test('all defaults have native validation descriptors derived from the schema', () => {
  const fields = configurationFields();
  function leafPaths(value, prefix = '') {
    return Object.entries(value).flatMap(([key, child]) => {
      const path = prefix ? `${prefix}.${key}` : key;
      return child !== null && typeof child === 'object' && !Array.isArray(child) ? leafPaths(child, path) : [path];
    });
  }
  assert.deepEqual(fields.map(field => field.path).sort(), leafPaths(defaults).sort());
  assert.equal(fields.find(field => field.path === 'macos.sizeGB').env, 'DEVBOX_SIZE_GB');
});

test('new schema constructs cannot silently bypass native runtime validation', () => {
  assert.throws(() => configurationFields({
    properties: { value: { type: 'integer', minimum: 1, maximum: 3, enum: [1, 3] } }
  }), /Unsupported native field/);
  assert.throws(() => configurationFields({
    properties: { value: { type: 'array', minItems: 1, items: { type: 'string' } } }
  }), /Unsupported native array/);
});
