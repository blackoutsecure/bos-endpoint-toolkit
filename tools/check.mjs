import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { lint as lintMarkdown } from 'markdownlint/promise';
import { buildAll } from './build.mjs';
import { root } from './configuration.mjs';

const directory = fileURLToPath(root);
const files = [];
async function walk(path) {
  for (const entry of await readdir(path, { withFileTypes: true })) {
    if (['.git', 'node_modules', 'output', 'target'].includes(entry.name)) continue;
    const child = join(path, entry.name);
    if (entry.isDirectory()) await walk(child);
    else files.push(child);
  }
}
await walk(directory);
const markdownConfig = JSON.parse(await readFile(new URL('.markdownlint.json', root), 'utf8'));
const markdownResults = await lintMarkdown({ files: files.filter(file => file.endsWith('.md')), config: markdownConfig });
if (Object.values(markdownResults).some(errors => errors.length > 0)) {
  console.error(markdownResults.toString());
  throw new Error('Markdownlint reported documentation findings.');
}
for (const file of files) {
  if ((/\.(?:sh|ps1|mjs|json|ya?ml|rs|toml)$/.test(file) || file.endsWith('Cargo.lock')) && (await readFile(file)).includes(13)) {
    throw new Error(`CRLF is not permitted in source/configuration: ${file}`);
  }
  if (file.endsWith('.json')) JSON.parse(await readFile(file, 'utf8'));
  if (file.endsWith('.md')) {
    const source = await readFile(file, 'utf8');
    for (const match of source.matchAll(/\]\(([^)]+)\)/g)) {
      const target = match[1];
      if (/^[a-z][a-z0-9+.-]*:|^#/i.test(target)) continue;
      await readFile(new URL(target.split('#')[0], pathToFileURL(file)));
    }
  }
}
await buildAll();
const bash = process.env.BOS_BASH ?? (process.platform === 'win32'
  ? join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe') : 'bash');
function run(command, args) {
  const result = spawnSync(command, args, { cwd: directory, stdio: 'inherit', timeout: 120000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal}).`);
}
const shellFiles = files.filter(file => file.endsWith('.sh'));
shellFiles.push(join(directory, 'output', 'devbox', 'macos', 'manage-devbox.sh'));
shellFiles.push(join(directory, 'output', 'ghostbsd-remote-access', 'ghostbsd', 'manage-remote-access.sh'));
for (const file of shellFiles) run(bash, ['--noprofile', '--norc', '-n', file]);
run(process.platform === 'win32' ? 'shellcheck.exe' : 'shellcheck', ['-x', '-P', 'SCRIPTDIR', ...shellFiles]);
const psFiles = files.filter(file => file.endsWith('.ps1'));
for (const name of ['detect-devbox.ps1', 'remediate-devbox.ps1', 'devbox-worker.ps1']) {
  psFiles.push(join(directory, 'output', 'devbox', 'windows', name));
}
psFiles.push(join(directory, 'output', 'ghostbsd-remote-access', 'windows', 'manage-remote-access.ps1'));
const psLiteral = value => `'${value.replaceAll("'", "''")}'`;
const parse = `$ErrorActionPreference = 'Stop'; foreach ($path in @(${psFiles.map(psLiteral).join(',')})) { $tokens = $null; $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors); if ($errors.Count) { throw ($errors | Out-String) }; Write-Output "PASS PowerShell parse: $path" }`;
run(process.platform === 'win32' ? 'powershell.exe' : 'pwsh', ['-NoProfile', '-NonInteractive', '-Command', parse]);
console.log('PASS Markdownlint, JSON, local documentation links, LF source files, native syntax, and ShellCheck.');
