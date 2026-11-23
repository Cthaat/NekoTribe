import { defineEventHandler, setResponseHeader, type H3Error, type H3Event } from 'h3';
import type { AiDeltaListener } from './inference-transport';

export function generationDeltas(event: H3Event): AiDeltaListener | undefined {
  return event.context?.aiGenerationDeltas;
}

export function defineAiGenerationHandler<T>(generate: (event: H3Event) => Promise<T>) {
  return defineEventHandler(async event => {
    const accept = event.node?.req?.headers?.accept ?? '';
    const streamed = accept.split(',').some(value => {
      const [media, ...parameters] = value.split(';').map(item => item.trim());
      return media?.toLowerCase() === 'text/event-stream' && !parameters.includes('q=0');
    });
    if (!streamed) return generate(event);

    const response = event.node.res;
    let started = false;
    const start = () => {
      if (started) return;
      setResponseHeader(event, 'Content-Type', 'text/event-stream; charset=utf-8');
      setResponseHeader(event, 'Cache-Control', 'private, no-store');
      setResponseHeader(event, 'X-Accel-Buffering', 'no');
      started = true;
    };
    const frame = (kind: string, data: unknown) => `event: ${kind}\ndata: ${JSON.stringify(data)}\n\n`;
    event.context.aiGenerationDeltas = (text: string) => new Promise<void>((resolve, reject) => {
      if (response.destroyed) {
        reject(new Error('AI stream closed'));
        return;
      }
      start();
      response.write(frame('delta', { text }), error => error ? reject(error) : resolve());
    });
    try {
      const result = await generate(event);
      if (!response.destroyed) {
        start();
        response.end(frame('done', result));
      }
    } catch (error) {
      if (!started) throw error;
      if (!response.destroyed) {
        const data = (error as H3Error | null)?.data;
        response.end(frame('failed', data ?? { code: 50001, message: '服务器内部错误', data: null, meta: null }));
      }
    } finally {
      delete event.context.aiGenerationDeltas;
    }
  });
}
