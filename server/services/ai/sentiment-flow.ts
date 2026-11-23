import policy from '../../../specifications/requirements/ai-sentiment.json' with { type:'json' };

export type SentimentLabel = keyof typeof policy.labels;
export type SentimentSignal = {label: SentimentLabel; confidence: number};
export const communitySentimentTool = policy.tool;
export const sentimentSampleLimit = policy.max_samples;
export const sentimentQueueQuery = policy.queue_post_query;
export const sentimentWindowLimit = policy.sample_per_window;

function configuredSentiment() {
  if (process.env.AI_SENTIMENTFLOW_ENABLED !== '1' || !process.env.AI_SENTIMENTFLOW_URL) return null;
  try {
    const endpoint = new URL(process.env.AI_SENTIMENTFLOW_URL);
    if (!['http:', 'https:'].includes(endpoint.protocol) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) return null;
    const token = process.env.AI_SENTIMENTFLOW_TOKEN;
    if (token && !/^[\x21-\x7e]+$/.test(token)) return null;
    return {endpoint,token};
  } catch { return null; }
}

export const sentimentEnabled = () => configuredSentiment() !== null;
let circuit = { endpoint:'', failures:0, retryAt:0 };

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

export function decodeSentimentSignal(value: unknown): SentimentSignal | null {
  const body = asRecord(value);
  const data = asRecord(body?.data) ?? body;
  const nested = asRecord(data?.prediction);
  const prediction = nested ?? data;
  const score = prediction?.score;
  let label: SentimentLabel | undefined;
  if (typeof prediction?.label === 'string') {
    const normalized = prediction.label.trim().toLowerCase();
    label = (Object.keys(policy.labels) as SentimentLabel[]).find(kind => policy.labels[kind].includes(normalized));
  } else if (!nested && typeof score === 'number' && Number.isInteger(score)) {
    const mapped = policy.old_scores[score];
    if (mapped === 'negative' || mapped === 'neutral' || mapped === 'positive') label = mapped;
  }
  const confidence = prediction?.confidence;
  return label && typeof confidence === 'number' && Number.isFinite(confidence) && confidence >= 0 && confidence <= 1
    ? {label,confidence} : null;
}

async function readReply(response: Response) {
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    throw new Error('SENTIMENT_UNAVAILABLE');
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const {done,value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > policy.max_reply_bytes) throw new Error('SENTIMENT_UNAVAILABLE');
      chunks.push(value);
    }
    return decodeSentimentSignal(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks,size))));
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

/** All classifications belong to one bounded batch. The main feature can continue on null. */
export async function classifySentimentTexts(texts: readonly string[], parent?: AbortSignal) {
  const configuration = configuredSentiment();
  if (!configuration || parent?.aborted || texts.length < 1 || texts.length > policy.max_samples ||
      texts.some(text => !text.trim() || !text.isWellFormed() || Buffer.byteLength(text) > 1600)) return null;
  const {endpoint,token} = configuration;
  if (circuit.endpoint !== endpoint.href) circuit = {endpoint:endpoint.href,failures:0,retryAt:0};
  const state = circuit;
  if (state.retryAt > Date.now()) return null;
  const batch = new AbortController();
  const deadline = AbortSignal.timeout(policy.timeout_ms);
  const signal = AbortSignal.any(parent ? [deadline,batch.signal,parent] : [deadline,batch.signal]);
  try {
    const predictions = await Promise.all(texts.map(async text => {
      const response = await fetch(endpoint, {
        method:'POST', signal, redirect:'error',
        headers:{'Content-Type':'application/json',Accept:'application/json',...(token ? {Authorization:`Bearer ${token}`} : {})},
        body:JSON.stringify({text,model:'lstm',return_probabilities:false,include_metadata:false}),
      });
      const reply = await readReply(response);
      if (!reply) throw new Error('SENTIMENT_UNAVAILABLE');
      return reply;
    }));
    signal.throwIfAborted();
    state.failures = 0;
    state.retryAt = 0;
    return predictions;
  } catch {
    batch.abort();
    if (!parent?.aborted && ++state.failures >= policy.failure_limit) {
      state.retryAt = Date.now() + policy.cooldown_ms;
    }
    return null;
  }
}
