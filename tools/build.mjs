import { chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { configurationFields, defaults, mergeConfiguration, root, service, serviceRoot, validateConfiguration } from './configuration.mjs';
import { buildRemoteAccess } from './build-remote-access.mjs';

function region(source, name, replacement) {
  const start = `# >>> devbox:${name} >>>`;
  const end = `# <<< devbox:${name} <<<`;
  const first = source.indexOf(start);
  const last = source.indexOf(end);
  if (first < 0 || last <= first || source.indexOf(start, first + 1) >= 0) {
    throw new Error(`Expected one ${name} build region.`);
  }
  return `${source.slice(0, first)}${replacement}${source.slice(last + end.length)}`;
}

const psQuote = value => `'${String(value).replaceAll("'", "''")}'`;

export async function build({ output = new URL('output/devbox/', root), configuration } = {}) {
  const desired = configuration !== undefined
    ? mergeConfiguration(defaults, validateConfiguration(configuration))
    : structuredClone(defaults);
  validateConfiguration(desired);
  const json = JSON.stringify(desired, null, 2);
  const fields = configurationFields();
  const windowsOutput = new URL('windows/', output);
  const macosOutput = new URL('macos/', output);
  await Promise.all([mkdir(windowsOutput, { recursive: true }), mkdir(macosOutput, { recursive: true })]);
  const read = async relative => (await readFile(new URL(relative, serviceRoot), 'utf8')).replaceAll('\r\n', '\n');

  let windowsConfiguration = await read('windows/configuration.ps1');
  const psFields = fields.map(field => {
    const entries = Object.entries(field).map(([key, value]) => {
      // .NET's $ also accepts a trailing LF; keep the schema's strict end anchor.
      const native = key === 'pattern' && value.endsWith('$') ? `${value.slice(0, -1)}\\z` : value;
      return `${key} = ${typeof native === 'number' ? native : psQuote(native)}`;
    });
    return `    [pscustomobject]@{ ${entries.join('; ')} }`;
  }).join('\n');
  windowsConfiguration = region(windowsConfiguration, 'configuration-data',
    `$DevboxReleaseVersion = ${psQuote(service.versions.windows)}\n$DevboxDefaultsJson = @'\n${json}\n'@\n$DevboxConfigurationFields = @(\n${psFields}\n)`);

  const worker = await read('windows/devbox-worker.ps1');
  for (const name of ['detect-devbox.ps1', 'remediate-devbox.ps1']) {
    let source = region(await read(`windows/${name}`), 'configuration', windowsConfiguration);
    if (name === 'remediate-devbox.ps1') {
      if (worker.includes("\n'@")) throw new Error('Worker cannot contain a closing single-quoted here-string delimiter.');
      source = region(source, 'worker', `$WorkerSource = @'\n${worker.trimEnd()}\n'@`);
    }
    await writeFile(new URL(name, windowsOutput), source, 'utf8');
  }
  await writeFile(new URL('devbox-worker.ps1', windowsOutput), worker, 'utf8');

  const bashFields = fields.map(field => [
    field.path, field.type === 'boolean' ? 'bool' : field.type,
    field.minimum ?? '', field.maximum ?? '', field.pattern,
    field.minItems ?? '', field.env
  ].join('|')).join('\n');
  if (fields.some(field => field.pattern.includes('|'))) throw new Error('Native field patterns cannot contain a pipe.');
  let macosConfiguration = await read('macos/configuration.sh');
  macosConfiguration = region(macosConfiguration, 'configuration-data',
    `DEVBOX_RELEASE_VERSION='${service.versions.macos}'\nDEVBOX_DEFAULTS_JSON="$(/bin/cat <<'DEVBOX_JSON'\n${json}\nDEVBOX_JSON\n)"\nDEVBOX_CONFIGURATION_FIELDS="$(/bin/cat <<'DEVBOX_FIELDS'\n${bashFields}\nDEVBOX_FIELDS\n)"`);
  const macos = region(await read('macos/manage-devbox.sh'), 'configuration', macosConfiguration);
  await writeFile(new URL('manage-devbox.sh', macosOutput), macos, 'utf8');
  await chmod(new URL('manage-devbox.sh', macosOutput), 0o755);
  const packageRoot = new URL('package-root/', macosOutput);
  await rm(packageRoot, { recursive: true, force: true });
  const executableDirectory = new URL('usr/local/libexec/bos-endpoint-toolkit/devbox/', packageRoot);
  const configDirectory = new URL('Library/Application Support/BlackoutSecure/EndpointToolkit/devbox/', packageRoot);
  const agentDirectory = new URL('Library/LaunchAgents/', packageRoot);
  const documentationDirectory = new URL('usr/local/share/doc/bos-endpoint-toolkit/devbox/', packageRoot);
  await Promise.all([executableDirectory, configDirectory, agentDirectory, documentationDirectory]
    .map(directory => mkdir(directory, { recursive: true })));
  await writeFile(new URL('manage-devbox.sh', executableDirectory), macos, 'utf8');
  await chmod(new URL('manage-devbox.sh', executableDirectory), 0o755);
  await writeFile(new URL('desired-config.json', configDirectory), `${json}\n`, 'utf8');
  const xml = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  const label = `${desired.macos.launchdPrefix}.initialize`;
  const initializationAgent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${xml(label)}</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/usr/local/libexec/bos-endpoint-toolkit/devbox/manage-devbox.sh</string>
    <string>--config</string>
    <string>/Library/Application Support/BlackoutSecure/EndpointToolkit/devbox/desired-config.json</string>
    <string>install</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
`;
  await writeFile(new URL(`${label}.plist`, agentDirectory), initializationAgent, 'utf8');
  for (const name of ['LICENSE', 'NOTICE']) {
    const contents = (await readFile(new URL(name, root), 'utf8')).replaceAll('\r\n', '\n');
    await Promise.all([windowsOutput, macosOutput, documentationDirectory]
      .map(directory => writeFile(new URL(name, directory), contents, 'utf8')));
  }
  await writeFile(new URL('desired-config.json', output), `${json}\n`, 'utf8');
  await writeFile(new URL('service.json', output), `${JSON.stringify(service, null, 2)}\n`, 'utf8');
  return { output, configuration: desired };
}

export async function buildAll() {
  await build();
  await buildRemoteAccess();
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let configuration;
  let selected;
  const seen = new Set();
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    if (!['--config', '--service'].includes(flag) || !args[index + 1] || seen.has(flag)) {
      throw new Error('Usage: npm run build -- [--service devbox|ghostbsd-remote-access] [--config <JSON file>]');
    }
    seen.add(flag);
    if (flag === '--config') configuration = JSON.parse(await readFile(args[index + 1], 'utf8'));
    else selected = args[index + 1];
  }
  if (selected && !['devbox', 'ghostbsd-remote-access'].includes(selected)) throw new Error(`Unknown service: ${selected}`);
  if (selected === 'ghostbsd-remote-access') {
    const result = await buildRemoteAccess({ configuration });
    console.log(`Built GhostBSD Remote Access in ${fileURLToPath(result.output)}`);
  } else {
    const result = await build({ configuration });
    console.log(`Built standalone Devbox packages in ${fileURLToPath(result.output)}`);
    if (!selected) {
      const remote = await buildRemoteAccess();
      console.log(`Built GhostBSD Remote Access in ${fileURLToPath(remote.output)}`);
    }
  }
}
