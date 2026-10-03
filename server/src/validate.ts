// Request and response validation against the contracts schemas.

import type { Context } from 'hono';
import type { Static, TSchema } from 'typebox';
import { Value } from 'typebox/value';
import { ApiError, clampMessage } from './errors.ts';

type SchemaError = ReturnType<typeof Value.Errors>[number];

/** `/profile/allergies/0/id` → `profile.allergies[0].id` */
function pathOf(pointer: string, child?: string): string {
  const parts = pointer.split('/').slice(1).map((p) => p.replace(/~1/g, '/').replace(/~0/g, '~'));
  if (child !== undefined) parts.push(child);
  if (parts.length === 0) return 'the body';
  return parts.reduce((path, part) => (/^\d+$/.test(part) ? `${path}[${part}]` : path ? `${path}.${part}` : part), '');
}

/** `profile.version is missing`, or `profile.version, profile.diet and 7 more are missing`. */
function listFields(error: SchemaError, names: string[], one: string, many: string): string {
  if (names.length === 0) return `${pathOf(error.instancePath)} ${error.message}`;
  const shown = names.slice(0, 2).map((name) => pathOf(error.instancePath, name));
  if (names.length === 1) return `${shown[0]} ${one}`;
  const rest = names.length - shown.length;
  return `${shown.join(', ')}${rest > 0 ? ` and ${rest} more` : ''} ${many}`;
}

function describe(error: SchemaError): string | null {
  const params = (error as { params?: Record<string, unknown> }).params ?? {};
  switch (error.keyword) {
    case 'boolean':
      return null; // "schema is false" repeats an additionalProperties error
    case 'required':
      return listFields(error, (params.requiredProperties as string[] | undefined) ?? [], 'is missing', 'are missing');
    case 'additionalProperties':
      return listFields(error, (params.additionalProperties as string[] | undefined) ?? [], "isn't allowed", "aren't allowed");
    case 'enum': {
      const allowed = params.allowedValues as unknown[] | undefined;
      return `${pathOf(error.instancePath)} must be one of ${allowed?.map((v) => JSON.stringify(v)).join(', ') ?? 'the allowed values'}`;
    }
    default:
      return `${pathOf(error.instancePath)} ${error.message}`;
  }
}

/** The first few schema problems, in plain words. */
export function describeErrors(schema: TSchema, value: unknown, limit = 3): string {
  const lines: string[] = [];
  for (const error of Value.Errors(schema, value)) {
    const line = describe(error);
    if (line && !lines.includes(line)) lines.push(line);
    if (lines.length >= limit) break;
  }
  return lines.join('; ') || 'it does not match the schema';
}

/** Parses the JSON body and checks it against `schema`, or throws invalid_request. */
export async function readJson<T extends TSchema>(c: Context, schema: T, contract: string): Promise<Static<T>> {
  const text = await c.req.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new ApiError('invalid_request', `The request body isn't valid JSON (${contract} contract).`);
  }
  if (!Value.Check(schema, body)) {
    throw new ApiError('invalid_request', clampMessage(`The request body doesn't match the ${contract} contract: ${describeErrors(schema, body)}.`));
  }
  return body as Static<T>;
}

/** Checks a skill's output before it's sent. A miss is the skill's fault: invalid_model_output. */
export function checkResponse<T extends TSchema>(schema: T, value: unknown, contract: string): Static<T> {
  if (!Value.Check(schema, value)) {
    throw new ApiError('invalid_model_output', clampMessage(`The ${contract} response didn't pass its contract check: ${describeErrors(schema, value, 1)}.`));
  }
  return value as Static<T>;
}
