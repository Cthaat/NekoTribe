export async function requestJson(target, { method = 'GET', path, body, token, timeoutMs = 8000, headers = {} }) {
  const url = new URL(path, target.baseUrl);
  if (!path.startsWith('/') || url.origin !== new URL(target.baseUrl).origin) {
    throw new Error('Request must stay on the configured backend.');
  }
  let response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        ...headers,
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw new Error('Backend request failed or timed out.');
  }
  try {
    return { status: response.status, body: await response.json() };
  } catch {
    throw Object.assign(new Error(`Backend response could not be read as JSON (HTTP ${response.status}).`), { status: response.status });
  }
}

export function expectStatus(response, status = 200) {
  if (response.status !== status) {
    throw new Error(`Expected HTTP ${status}, received HTTP ${response.status}.`);
  }
  return response.body;
}

export async function login(target, timeoutMs) {
  const { data } = expectStatus(await requestJson(target, {
    method: 'POST',
    path: '/api/v2/auth/tokens',
    body: { account: target.account, password: target.password, remember_me: true },
    timeoutMs,
  }));
  const session = {
    userId: data?.user?.user_id,
    sessionId: data?.tokens?.session_id,
    accessToken: data?.tokens?.access_token,
    refreshToken: data?.tokens?.refresh_token,
  };
  if (!Number.isSafeInteger(session.userId) || session.userId < 1 ||
      [session.sessionId, session.accessToken, session.refreshToken].some(value => typeof value !== 'string' || !value)) {
    throw new Error('Fixture login did not return an authenticated session.');
  }
  return session;
}
