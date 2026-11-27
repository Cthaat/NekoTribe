export function useCommandChatSearch() {
  return useState<{ query: string; owner: number } | null>('command-chat-search', () => null);
}
