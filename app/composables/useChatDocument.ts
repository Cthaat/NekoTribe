import { isChatPath } from '#shared/utils/chat-document';

export function useChatDocument() {
  // A client-side route change keeps the original HTML document's Permissions-Policy.
  return useState('chat-document', () => isChatPath(useRequestURL().pathname));
}
