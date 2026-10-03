// Schema helpers shared by every contract.
//
// StringEnum mirrors pi-ai's helper of the same name: it emits a flat
// {type: 'string', enum: [...]} schema, never anyOf/const, so the same JSON
// Schema works for providers that reject anyOf/const (e.g. Gemini).

import { Type, type TSchema, type TUnsafe, type TObject, type TProperties, type TUnion, type TNull } from 'typebox';

export function StringEnum<const T extends readonly string[]>(
  values: T,
  options: { description?: string; default?: T[number] } = {},
): TUnsafe<T[number]> {
  return Type.Unsafe<T[number]>({ type: 'string', enum: [...values], ...options });
}

/** `T | null`. In the profile, `null` means "skipped" (design §7.2). */
export function Nullable<T extends TSchema>(schema: T): TUnion<[T, TNull]> {
  return Type.Union([schema, Type.Null()]);
}

/** An object that rejects unknown properties. Every contract object uses this. */
export function Strict<T extends TProperties>(properties: T, options: { description?: string; title?: string } = {}): TObject<T> {
  return Type.Object(properties, { ...options, additionalProperties: false });
}
