interface SaveFileHandle {
  createWritable(): Promise<WritableStream<Uint8Array>>;
}

type SaveFilePicker = (options: { suggestedName: string }) => Promise<SaveFileHandle>;

export function browserSaveFilePicker(): SaveFilePicker | undefined {
  const browser = window as Window & { showSaveFilePicker?: SaveFilePicker };
  return typeof browser.showSaveFilePicker === 'function'
    ? browser.showSaveFilePicker.bind(browser)
    : undefined;
}

export async function savePrivateStream(
  pick: SaveFilePicker,
  filename: string,
  openBody: () => Promise<ReadableStream<Uint8Array>>,
  signal: AbortSignal,
): Promise<void> {
  signal.throwIfAborted();
  const handle = await pick({ suggestedName: filename });
  signal.throwIfAborted();
  const target = await handle.createWritable();
  try {
    signal.throwIfAborted();
    const body = await openBody();
    await body.pipeTo(target, { signal });
  } catch (error) {
    await target.abort().catch(() => {});
    throw error;
  }
}
