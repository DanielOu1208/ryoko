// Gemini embeddings for trip memory (design §8.2, §8.3): gemini-embedding-001
// at 768 dimensions, over REST with the same GEMINI_API_KEY as the models.
// Never log the key.

export const EMBEDDING_MODEL = 'gemini-embedding-001';
export const EMBEDDING_DIMS = 768;

/** Stored events are documents; a Mimo message looking for them is a query. */
export type EmbedTask = 'RETRIEVAL_DOCUMENT' | 'RETRIEVAL_QUERY';

export type Embed = (texts: string[], task: EmbedTask, signal?: AbortSignal) => Promise<number[][]>;

const URL_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

/** One batch call for any number of texts (Gemini allows 100). Fails fast; callers carry on without vectors. */
export function createGeminiEmbed(apiKey: string, options: { fetch?: typeof fetch; timeoutMs?: number } = {}): Embed {
  const doFetch = options.fetch ?? fetch;
  return async (texts, task, signal) => {
    if (texts.length === 0) return [];
    const timeout = AbortSignal.timeout(options.timeoutMs ?? 3000);
    const response = await doFetch(`${URL_BASE}/${EMBEDDING_MODEL}:batchEmbedContents`, {
      method: 'POST',
      headers: { 'x-goog-api-key': apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        requests: texts.map((text) => ({
          model: `models/${EMBEDDING_MODEL}`,
          content: { parts: [{ text }] },
          taskType: task,
          outputDimensionality: EMBEDDING_DIMS,
        })),
      }),
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!response.ok) throw new Error(`Gemini embeddings answered HTTP ${response.status}.`);
    const body = (await response.json()) as { embeddings?: { values?: number[] }[] };
    const vectors = (body.embeddings ?? []).map((e) => e.values ?? []);
    if (vectors.length !== texts.length || vectors.some((v) => v.length !== EMBEDDING_DIMS)) {
      throw new Error('Gemini embeddings came back in an unexpected shape.');
    }
    return vectors;
  };
}

/** pgvector's text form: `[0.1,0.2,…]`. */
export function vectorLiteral(values: readonly number[]): string {
  return `[${values.join(',')}]`;
}
