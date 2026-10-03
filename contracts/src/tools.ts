import { Type, type Static } from 'typebox';
import { StringEnum, Strict } from './helpers.ts';
import { ClockTime } from './common.ts';

// Design §6.4. Mimo's tools. Mimo names places; the device resolves them with MapKit.

export const TOOL_NAMES = ['show_places', 'web_search'] as const;
export const ToolName = StringEnum(TOOL_NAMES);
export type ToolName = Static<typeof ToolName>;

export const ShownPlace = Strict({
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  why: Type.String({ minLength: 1, maxLength: 80, description: 'One line, home language' }),
  order: Type.Optional(Type.Integer({ minimum: 1, maximum: 5, description: 'Stop number when this is a plan' })),
  when: Type.Optional(ClockTime),
});
export type ShownPlace = Static<typeof ShownPlace>;

/** show_places: the model's arguments and the tool_end details share this shape. */
export const ShowPlacesDetails = Strict({
  places: Type.Array(ShownPlace, { minItems: 1, maxItems: 5 }),
});
export type ShowPlacesDetails = Static<typeof ShowPlacesDetails>;
export const ShowPlacesParams = ShowPlacesDetails;
export type ShowPlacesParams = ShowPlacesDetails;

export const WebSearchParams = Strict({
  query: Type.String({ minLength: 1, maxLength: 200 }),
});
export type WebSearchParams = Static<typeof WebSearchParams>;

export const WebSource = Strict({
  title: Type.String({ minLength: 1, maxLength: 200 }),
  url: Type.String({ format: 'uri', pattern: '^https?://' }),
});
export type WebSource = Static<typeof WebSource>;

export const WebSearchDetails = Strict({
  sources: Type.Array(WebSource, { maxItems: 8 }),
});
export type WebSearchDetails = Static<typeof WebSearchDetails>;
