/** One queue per Nuxt app; never share authentication work between SSR users. */
export class AuthRequestQueue {
  private version = 0;
  private pendingIdentityChanges = 0;
  private readonly observers = new Set<() => void>();
  get revision(): number { return this.version; }
  get isIdentityChanging(): boolean { return this.pendingIdentityChanges > 0; }
  subscribe(observer: () => void): () => void {
    this.observers.add(observer);
    return () => { this.observers.delete(observer); };
  }
  private notify(): void {
    for (const observer of [...this.observers]) {
      if (!this.observers.has(observer)) continue;
      try { observer(); } catch { /* UI observers must not interrupt authentication. */ }
    }
  }
  beginIdentityChange(): number {
    const revision = ++this.version;
    this.notify();
    return revision;
  }
  private pending: Promise<void> = Promise.resolve();

  run<T>(action: () => Promise<T>): Promise<T> {
    const result = this.pending.then(action);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  runIdentityChange<T>(action: () => Promise<T>): Promise<T> {
    this.pendingIdentityChanges++;
    this.beginIdentityChange();
    return this.run(action).finally(() => {
      this.pendingIdentityChanges--;
      this.notify();
    });
  }

  runForCurrentIdentity<T>(action: () => Promise<T>): Promise<T> {
    const revision = this.revision;
    const cancelled = (): Error => {
      const error = new Error('Authentication action superseded');
      error.name = 'AbortError';
      return error;
    };
    // During login/logout intent, the currently rendered account is ambiguous.
    if (this.pendingIdentityChanges > 0) return Promise.reject(cancelled());
    const assertCurrent = (): void => {
      if (this.revision !== revision) throw cancelled();
    };
    return this.run(async () => {
      assertCurrent();
      try {
        const result = await action();
        assertCurrent();
        return result;
      } catch (error) {
        assertCurrent();
        throw error;
      }
    });
  }
}

const queues = new WeakMap<object, AuthRequestQueue>();

export function authQueueFor(owner: object): AuthRequestQueue {
  let queue = queues.get(owner);
  if (!queue) {
    queue = new AuthRequestQueue();
    queues.set(owner, queue);
  }
  return queue;
}
