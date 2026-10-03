// Any MODEL other than faux until W7 lands: every skill answers model_error.

import { ApiError } from '../errors.ts';
import type { Skills } from './types.ts';

export function createPendingSkills(model: string): Skills {
  const unavailable = (): never => {
    throw new ApiError(
      'model_error',
      `MODEL=${model} isn't available yet: the model-backed skills come in W7. Run the server with MODEL=faux for fixtures.`,
      { status: 503, retryable: false },
    );
  };
  return {
    name: `pending:${model}`,
    placeCard: async () => unavailable(),
    discover: async () => unavailable(),
    allergyCard: async () => unavailable(),
    mimo: async () => unavailable(),
  };
}
