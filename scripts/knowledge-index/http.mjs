export async function readJson(body, limit) {
  if (!body) throw Error('INVALID_RESPONSE');
  const pieces = [];
  let received = 0;
  for await (const chunk of body) {
    received += chunk.length;
    if (received > limit) throw Error('BODY_TOO_LARGE');
    pieces.push(chunk);
  }
  return JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(Buffer.concat(pieces)));
}

export async function requestJson(url, { method='GET', body, headers, signal, timeout=10000, limit=65536 } = {}) {
  const deadline = AbortSignal.timeout(timeout);
  const response = await fetch(url, {
    method, redirect:'error',
    headers:{ accept:'application/json', ...(body === undefined ? {} : {'content-type':'application/json'}), ...headers },
    ...(body === undefined ? {} : {body:JSON.stringify(body)}),
    signal:signal ? AbortSignal.any([deadline,signal]) : deadline,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw Error(response.status === 404 ? 'NOT_FOUND' : 'DEPENDENCY_UNAVAILABLE');
  }
  return readJson(response.body, limit);
}
