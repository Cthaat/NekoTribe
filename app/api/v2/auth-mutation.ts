import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';

export function authMutation<T>(
  action: () => Promise<T>,
  identityChange = false
): Promise<T> {
  const app = useNuxtApp();
  const queue = authQueueFor(app);
  const run = () => app.runWithContext(action);
  return identityChange ? queue.runIdentityChange(run) : queue.run(run);
}

export function currentSessionMutation<T>(action: () => Promise<T>): Promise<T> {
  const app = useNuxtApp();
  return authQueueFor(app).runForCurrentIdentity(() => app.runWithContext(action));
}
