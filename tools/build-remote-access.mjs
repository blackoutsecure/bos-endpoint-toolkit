import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { configurationFields, loadServiceConfiguration, mergeConfiguration, root } from './configuration.mjs';

export const remoteAccessRoot = new URL('services/ghostbsd-remote-access/', root);
export const remoteAccess = await loadServiceConfiguration(remoteAccessRoot, 'GhostBSD Remote Access');

function replaceRegion(source, name, replacement) {
  const start = `# >>> ghostbsd-remote-access:${name} >>>`;
  const end = `# <<< ghostbsd-remote-access:${name} <<<`;
  const first = source.indexOf(start);
  const last = source.indexOf(end);
  if (first < 0 || last <= first || source.indexOf(start, first + 1) >= 0) {
    throw new Error(`Expected one remote-access ${name} build region.`);
  }
  return source.slice(0, first) + replacement + source.slice(last + end.length);
}

const shellQuote = value => `'${String(value).replaceAll("'", "'\"'\"'")}'`;
const psQuote = value => `'${String(value).replaceAll("'", "''")}'`;
const variable = path => path.replace(/[A-Z]/g, letter => `_${letter}`).toUpperCase();

export async function buildRemoteAccess({ output = new URL('output/ghostbsd-remote-access/', root), configuration } = {}) {
  const desired = configuration === undefined
    ? structuredClone(remoteAccess.defaults)
    : mergeConfiguration(remoteAccess.defaults, remoteAccess.validateConfiguration(configuration));
  remoteAccess.validateConfiguration(desired);
  for (const value of Object.values(desired)) {
    if (typeof value === 'string' && /[\r\n]/.test(value)) throw new Error('Remote-access configuration cannot contain line breaks.');
  }
  if (desired.sshPort === desired.rdpPort) throw new Error('SSH and RDP require different guest ports.');
  const fields = configurationFields(remoteAccess.schema);
  const assignments = fields.map(field => `${variable(field.path)}=${shellQuote(desired[field.path])}`);
  const validation = fields.map(field => {
    const name = variable(field.path);
    if (field.type === 'integer') {
      return `  [[ "$${name}" =~ ^[0-9]+$ ]] || die 'Invalid ${field.path}.'\n` +
        `  (( ${name} >= ${field.minimum} && ${name} <= ${field.maximum} )) || die 'Invalid ${field.path}.'`;
    }
    if (field.type !== 'string') throw new Error(`Unsupported remote-access field: ${field.path}`);
    return `  [[ ! "$${name}" == *$'\\n'* && ! "$${name}" == *$'\\r'* && "$${name}" =~ ${field.pattern} ]] || die 'Invalid ${field.path}.'`;
  });
  const read = async path => (await readFile(new URL(path, remoteAccessRoot), 'utf8')).replaceAll('\r\n', '\n');
  const guest = replaceRegion(await read('ghostbsd/manage-remote-access.sh'), 'configuration',
    `${assignments.join('\n')}\nvalidate_configuration() {\n${validation.join('\n')}\n}\n`);
  let windows = await read('windows/manage-remote-access.ps1');
  windows = replaceRegion(windows, 'parameters',
    `    [ValidatePattern(${psQuote(remoteAccess.schema.properties.hostName.pattern.slice(0, -1) + '\\z')})]\n` +
    `    [string]$ComputerName = ${psQuote(desired.hostName)},\n` +
    `    [ValidateRange(1, 65535)][int]$SshPort = ${desired.hostSshPort},\n` +
    `    [ValidateRange(1, 65535)][int]$LocalRdpPort = ${desired.localRdpPort},`);
  windows = replaceRegion(windows, 'configuration',
    `$RemoteAccessDefaults = @'\n${JSON.stringify(desired, null, 2)}\n'@ | ConvertFrom-Json\n` +
    `$RemoteAccessGuestBase64 = '${Buffer.from(guest, 'utf8').toString('base64')}'`);
  await Promise.all(['ghostbsd/', 'windows/'].map(path => mkdir(new URL(path, output), { recursive: true })));
  await writeFile(new URL('ghostbsd/manage-remote-access.sh', output), guest, 'utf8');
  await chmod(new URL('ghostbsd/manage-remote-access.sh', output), 0o755);
  await writeFile(new URL('windows/manage-remote-access.ps1', output), windows, 'utf8');
  for (const platform of ['ghostbsd/', 'windows/']) {
    for (const name of ['LICENSE', 'NOTICE']) {
      await writeFile(new URL(platform + name, output), (await readFile(new URL(name, root), 'utf8')).replaceAll('\r\n', '\n'), 'utf8');
    }
  }
  await writeFile(new URL('desired-config.json', output), `${JSON.stringify(desired, null, 2)}\n`, 'utf8');
  await writeFile(new URL('service.json', output), `${JSON.stringify(remoteAccess.service, null, 2)}\n`, 'utf8');
  return { output, configuration: desired };
}
