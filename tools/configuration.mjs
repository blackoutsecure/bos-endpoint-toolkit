import { readFile } from 'node:fs/promises';
import Ajv2020 from 'ajv/dist/2020.js';

export const root = new URL('../', import.meta.url);
export const serviceRoot = new URL('services/devbox/', root);
const commonSchema = JSON.parse(await readFile(new URL('framework/schemas/configuration.schema.json', root), 'utf8'));

export async function loadServiceConfiguration(directory, label) {
  const read = async path => JSON.parse(await readFile(new URL(path, directory), 'utf8'));
  const [schema, defaults, service] = await Promise.all([
    read('config/schema.json'), read('config/defaults.json'), read('service.json')
  ]);
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addKeyword({ keyword: 'x-env', schemaType: 'string' });
  ajv.addSchema(commonSchema);
  const validate = ajv.compile(schema);
  function validateConfiguration(value) {
    if (!validate(value)) {
      throw new Error(`Invalid ${label} configuration: ${ajv.errorsText(validate.errors, { separator: '; ' })}`);
    }
    return value;
  }
  validateConfiguration(defaults);
  return { schema, defaults, service, validateConfiguration };
}

export const { schema, defaults, service, validateConfiguration } = await loadServiceConfiguration(serviceRoot, 'Devbox');

export function mergeConfiguration(base, override) {
  const merged = structuredClone(base);
  for (const [key, value] of Object.entries(override)) {
    merged[key] = value !== null && typeof value === 'object' && !Array.isArray(value)
      ? mergeConfiguration(base[key] ?? {}, value)
      : structuredClone(value);
  }
  return merged;
}

function dereference(value) {
  if (!value.$ref) return value;
  const [id, pointer] = value.$ref.split('#');
  if (id !== commonSchema.$id || !pointer.startsWith('/$defs/')) {
    throw new Error(`Unsupported configuration reference: ${value.$ref}`);
  }
  const target = commonSchema.$defs[pointer.slice('/$defs/'.length)];
  if (!target) throw new Error(`Unresolved configuration reference: ${value.$ref}`);
  return { ...target, ...value };
}

export function configurationFields(node = schema, prefix = '') {
  return Object.entries(node.properties).flatMap(([key, property]) => {
    const resolved = dereference(property);
    const path = prefix ? `${prefix}.${key}` : key;
    const supported = new Set(['$ref', 'type', 'minimum', 'maximum', 'pattern', 'minItems', 'uniqueItems', 'items', 'x-env']);
    if (resolved.type === 'object') {
      const objectKeys = new Set(['type', 'additionalProperties', 'properties']);
      if (resolved.additionalProperties !== false || Object.keys(resolved).some(name => !objectKeys.has(name))) {
        throw new Error(`Unsupported native object schema: ${path}`);
      }
    } else if (Object.keys(resolved).some(name => !supported.has(name)) ||
      !['integer', 'boolean', 'string', 'array'].includes(resolved.type)) {
      throw new Error(`Unsupported native field schema: ${path}`);
    }
    if (resolved.type === 'integer' &&
      (!Number.isSafeInteger(resolved.minimum) || !Number.isSafeInteger(resolved.maximum))) {
      throw new Error(`Native integer bounds are required: ${path}`);
    }
    if (resolved.type === 'array' &&
      (resolved.uniqueItems !== true || resolved.minItems !== 1 || resolved.items?.type !== 'string' ||
        Object.keys(resolved.items).some(name => !['type', 'pattern'].includes(name)))) {
      throw new Error(`Unsupported native array schema: ${path}`);
    }
    const pattern = resolved.pattern ?? resolved.items?.pattern ?? '';
    return resolved.type === 'object'
      ? configurationFields(resolved, path)
      : [{
          path,
          type: resolved.type,
          minimum: resolved.minimum,
          maximum: resolved.maximum,
          pattern,
          minItems: resolved.minItems,
          env: resolved['x-env'] ?? ''
        }];
  });
}

validateConfiguration(defaults);
