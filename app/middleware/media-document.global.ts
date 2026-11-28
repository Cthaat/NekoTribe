import { isChatPath } from '#shared/utils/chat-document';

export default defineNuxtRouteMiddleware(to => {
  const documentAllowsCalls = useChatDocument().value;
  if (import.meta.server || documentAllowsCalls === isChatPath(to.path)) return;
  if (documentAllowsCalls && useWebRtcCalls().call.value) return;
  const target = new URL(useRouter().resolve(to.fullPath).href, location.origin);
  if (target.origin !== location.origin) return abortNavigation();
  return navigateTo(target.href, { external: true });
});
