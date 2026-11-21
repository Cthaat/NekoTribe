interface AiPostDraft {
  text: string;
  revision: number;
}

const pending = new WeakMap<object, AiPostDraft>();

export function stageAiPostDraft(app: object, revision: number, text: string): () => void {
  const draft = { revision, text };
  pending.set(app, draft);
  return () => {
    if (pending.get(app) === draft) pending.delete(app);
  };
}

export function takeAiPostDraft(app: object, revision: number): string {
  const draft = pending.get(app);
  pending.delete(app);
  return draft?.revision === revision ? draft.text : '';
}
