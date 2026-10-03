import { createHash } from 'node:crypto';

// Profile.version = sha-256 (lowercase hex) of the canonical JSON of the profile
// with `version` removed. Canonical JSON: object keys sorted by UTF-16 code unit,
// no whitespace, JSON.stringify string escaping. The server treats the version as an
// opaque cache key; only the device needs to compute it consistently.

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`;
}

export function profileVersion(profile: Record<string, unknown>): string {
  const { version: _ignored, ...rest } = profile;
  return createHash('sha256').update(canonicalJson(rest), 'utf8').digest('hex');
}
