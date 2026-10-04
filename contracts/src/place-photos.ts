import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { Coordinate } from './common.ts';

// POST /v1/place-photos. A photo of each place for the app's thumbnails and
// the Map place card's header, from the Foursquare Places API. The server
// looks each place up by name near its coordinate and caches the answer, "no
// photo" included. The app falls back to Look Around, then a satellite tile,
// when a place has no url, so a server without FOURSQUARE_API_KEY (or in
// MODEL=faux) answers every place with no url.

export const PLACE_PHOTOS_MAX = 25;

export const PlacePhotoQuery = Strict({
  key: Type.String({ minLength: 1, maxLength: 120, description: "The app's key for the place, echoed back (MapKit identifier, or name@lat,lon)" }),
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120, description: 'Local-script name; may match instead of name' })),
  coordinate: Coordinate,
});
export type PlacePhotoQuery = Static<typeof PlacePhotoQuery>;

export const PlacePhotosRequest = Strict({
  places: Type.Array(PlacePhotoQuery, { minItems: 1, maxItems: PLACE_PHOTOS_MAX }),
});
export type PlacePhotosRequest = Static<typeof PlacePhotosRequest>;

export const PlacePhoto = Strict({
  key: Type.String({ minLength: 1, maxLength: 120 }),
  url: Type.Optional(Type.String({ format: 'uri', pattern: '^https://', maxLength: 2048, description: 'Absent when there is no photo' })),
  width: Type.Optional(Type.Integer({ minimum: 1, description: 'Pixels, when known' })),
  height: Type.Optional(Type.Integer({ minimum: 1 })),
});
export type PlacePhoto = Static<typeof PlacePhoto>;

/** One entry per distinct requested key, in request order. */
export const PlacePhotosResponse = Strict({
  photos: Type.Array(PlacePhoto, { maxItems: PLACE_PHOTOS_MAX }),
});
export type PlacePhotosResponse = Static<typeof PlacePhotosResponse>;
