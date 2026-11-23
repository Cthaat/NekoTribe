import type { V2LoginData } from '@/types/v2';
import { authQueueFor } from '@/services/auth-request-queue';
import { authMutation } from './auth-mutation';
import { v2RequestData } from './client';

export interface GitHubLink {
  github_user_id: string;
  github_login: string;
  linked_at: string;
}

interface GitHubFlow {
  flow_id: string;
  flow_key: string;
  authorization_url: string;
  expires_in: number;
}

interface FlowClient {
  signal: AbortSignal;
  current: () => boolean;
  open: (url: string) => void;
}

type LoginReceipt = { status: 'completed'; login: V2LoginData };
type BindingReceipt = { status: 'completed'; link: GitHubLink };
type Pending = { status: 'pending' };

const loginFlows = '/api/v2/auth/oauth/github/login/flows';
const linkPath = '/api/v2/users/me/oauth/github';
const nonce = (value: unknown) => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(value);

export function openGitHubWindow() {
  const popup = window.open('about:blank', '_blank', 'popup');
  if (!popup) throw new Error('GitHub popup blocked');
  popup.opener = null;
  return { open: (url: string) => { popup.location.href = url; }, close: () => popup.close() };
}

function assertCurrent(client: FlowClient) {
  if (client.signal.aborted || !client.current()) throw new DOMException('GitHub action superseded', 'AbortError');
}

function pause(signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new DOMException('GitHub action superseded', 'AbortError')); return; }
    const abort = () => { clearTimeout(timer); reject(new DOMException('GitHub action superseded', 'AbortError')); };
    const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve(); }, 1200);
    signal.addEventListener('abort', abort, { once: true });
  });
}

function allowedGitHubUrl(flow: GitHubFlow): string {
  let url: URL | null = null;
  try { if (typeof flow?.authorization_url === 'string') url = new URL(flow.authorization_url); } catch { /* Invalid provider URI. */ }
  if (!nonce(flow?.flow_id) || !nonce(flow?.flow_key) || !Number.isSafeInteger(flow.expires_in) ||
      flow.expires_in < 1 || flow.expires_in > 300 || !url || url.origin !== 'https://github.com' ||
      url.pathname !== '/login/oauth/authorize' || url.username || url.password || url.hash ||
      !nonce(url.searchParams.get('state')) || !nonce(url.searchParams.get('code_challenge')) ||
      (url.searchParams.get('scope') ?? '') !== '' || url.searchParams.get('code_challenge_method') !== 'S256') {
    throw new Error('Invalid GitHub authorization response');
  }
  return url.href;
}

async function completeGitHub<T extends LoginReceipt | BindingReceipt>(flows: string, client: FlowClient, rememberMe?: boolean): Promise<T> {
  const app = useNuxtApp();
  assertCurrent(client);
  const flow = await v2RequestData<GitHubFlow>(flows, { method: 'POST', signal: client.signal });
  assertCurrent(client);
  client.open(allowedGitHubUrl(flow));
  const end = performance.now() + flow.expires_in * 1000;
  const body = { flow_key: flow.flow_key, ...(rememberMe === undefined ? {} : { remember_me: rememberMe }) };
  do {
    assertCurrent(client);
    const receipt = await app.runWithContext(() => v2RequestData<T | Pending, typeof body>(
      `${flows}/${encodeURIComponent(flow.flow_id)}/complete`, { method: 'POST', body, signal: client.signal },
    ));
    assertCurrent(client);
    if (receipt?.status === 'completed') return receipt;
    if (receipt?.status !== 'pending') throw new Error('Invalid GitHub completion');
    await pause(client.signal);
  } while (performance.now() < end);
  throw new Error('GitHub authorization expired');
}

export function authenticateGitHub(client: FlowClient, rememberMe: boolean): Promise<V2LoginData> {
  const app = useNuxtApp();
  const identity = authQueueFor(app);
  const operation = authMutation(async () => {
    const receipt = await completeGitHub<LoginReceipt>(loginFlows,
      { ...client, current: () => client.current() && identity.revision === revision }, rememberMe);
    return receipt.login;
  }, true);
  const revision = identity.revision;
  return operation;
}

function validLink(link: GitHubLink): boolean {
  return typeof link?.github_user_id === 'string' && /^[1-9][0-9]{0,31}$/u.test(link.github_user_id) &&
    typeof link.github_login === 'string' && link.github_login.length > 0 && typeof link.linked_at === 'string';
}

export async function bindGitHub(client: FlowClient): Promise<GitHubLink> {
  const { link } = await completeGitHub<BindingReceipt>(`${linkPath}/flows`, client);
  if (!validLink(link)) throw new Error('Unconfirmed GitHub binding');
  return link;
}

export async function getGitHubLink(): Promise<GitHubLink | null> {
  const data = await v2RequestData<{ link: GitHubLink | null }>(linkPath);
  if (!data || (data.link !== null && !validLink(data.link))) throw new Error('Invalid GitHub binding');
  return data.link;
}

export async function unlinkGitHub(): Promise<void> {
  const result = await v2RequestData<null>(linkPath, { method: 'DELETE' });
  if (result !== null) throw new Error('Unconfirmed GitHub unlink');
}
