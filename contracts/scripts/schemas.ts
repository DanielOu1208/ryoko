// The schemas emitted to contracts/json-schema/, by file name. Keep in sync with design §7.

import type { TSchema } from 'typebox';
import * as C from '../src/index.ts';

export const SCHEMAS: Record<string, TSchema> = {
  Situation: C.Situation,
  Place: C.Place,
  Profile: C.Profile,
  Phrase: C.Phrase,
  CardPhrase: C.CardPhrase,
  PlaceCardRequest: C.PlaceCardRequest,
  PlaceCardResponse: C.PlaceCardResponse,
  DiscoverRequest: C.DiscoverRequest,
  DiscoverResponse: C.DiscoverResponse,
  AllergyCardRequest: C.AllergyCardRequest,
  AllergyCardResponse: C.AllergyCardResponse,
  TranslateRequest: C.TranslateRequest,
  TranslateResponse: C.TranslateResponse,
  SonioxKeyResponse: C.SonioxKeyResponse,
  TripEventsRequest: C.TripEventsRequest,
  TripEventsResponse: C.TripEventsResponse,
  MimoMessageRequest: C.MimoMessageRequest,
  MimoModelsResponse: C.MimoModelsResponse,
  SseEvent: C.SseEvent,
  ErrorEnvelope: C.ErrorEnvelope,
  ShowPlacesParams: C.ShowPlacesParams,
  ShowPlacesDetails: C.ShowPlacesDetails,
  WebSearchParams: C.WebSearchParams,
  WebSearchDetails: C.WebSearchDetails,
  LangCodeTable: C.LangCodeTable,
  CategoryTable: C.CategoryTable,
  AllergyTemplateTable: C.AllergyTemplateTable,
};

/** The emitted file for one schema: plain JSON Schema 2020-12. */
export function jsonSchemaDocument(name: string, schema: TSchema): Record<string, unknown> {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: `https://ryoko.invalid/contracts/${name}.schema.json`,
    title: name,
    ...JSON.parse(JSON.stringify(schema)),
  };
}
