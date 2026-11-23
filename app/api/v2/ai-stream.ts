export type GenerationDelta = (text: string) => void;

export async function readAiStream<T>(
  stream: ReadableStream<Uint8Array>,
  onDelta: GenerationDelta
): Promise<T> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error('AI stream ended without a result');
      buffer += decoder.decode(chunk.value, { stream: true });
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        const lines = buffer.slice(0, boundary).split('\n');
        buffer = buffer.slice(boundary + 2);
        const event = lines.find(line => line.startsWith('event: '))?.slice(7);
        const json = lines.find(line => line.startsWith('data: '))?.slice(6);
        if (event && json) {
          const payload = JSON.parse(json) as { text?: string; data?: T; code?: number; message?: string };
          if (event === 'delta' && typeof payload.text === 'string') onDelta(payload.text);
          if (event === 'done' && payload.code === 200 && 'data' in payload) return payload.data as T;
          if (event === 'failed') {
            throw Object.assign(new Error(payload.message ?? 'Generation failed'), {
              statusCode: Math.floor((payload.code ?? 50001) / 100), data: payload
            });
          }
        }
        boundary = buffer.indexOf('\n\n');
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
}
