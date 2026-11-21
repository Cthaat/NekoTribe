import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { checkDeploymentEndpoints } from '../scripts/check-deployment-endpoints.mjs';

async function listen(t, handler, upgrade) {
  const server = createServer(handler);
  if (upgrade) server.on('upgrade', upgrade);
  await new Promise((resolve, reject) => server.on('error', reject).listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

const json = (response, value) => {
  response.setHeader('content-type', 'application/json');
  response.end(JSON.stringify(value));
};

test('check follows separate prefixes and never sends credentials', async t => {
  const origin = 'https://client.example.test';
  const requests = [];
  const api = await listen(t, (request,response) => {
    requests.push(`${request.method} ${request.url}`);
    assert.equal(request.headers.authorization,undefined);
    assert.equal(request.headers.cookie,undefined);
    if (request.url === '/service/api/ready') return json(response,{status:'ready'});
    assert.equal(request.url,'/service/api/v2/users/me');
    assert.equal(request.headers.origin,origin);
    assert.equal(request.method,'OPTIONS');
    response.writeHead(204,{
      'access-control-allow-origin':origin, 'access-control-allow-credentials':'true',
      'access-control-allow-methods':'GET', 'access-control-allow-headers':request.headers['access-control-request-headers'],
    }).end();
  });
  const media = await listen(t, (request,response) => {
    requests.push(`${request.method} ${request.url}`);
    assert.equal(request.url,'/media/storage/default-avatar.png');
    assert.equal(request.headers.origin,origin);
    response.writeHead(200,{'content-length':52,'content-type':'image/png','access-control-allow-origin':origin}).end();
  });
  const realtime = await listen(t, (request,response) => {
    requests.push(`${request.method} ${request.url}`);
    assert.equal(request.headers.origin,origin);
    assert.equal(request.headers.upgrade,'websocket');
    assert.equal(request.headers.authorization,undefined);
    response.statusCode = 401;
    json(response,{code:40101});
  });
  const result = await checkDeploymentEndpoints({api:`${api}/service/`,media:`${media}/media`,realtime:`${realtime.replace('http:','ws:')}/socket`,origin});
  assert.deepEqual(result,{ok:true,checks:{api:{ok:true,status:200},media:{ok:true,status:200},realtime:{ok:true,status:401},apiCors:{ok:true,status:204}}});
  assert.deepEqual(requests.sort(), ['GET /service/api/ready','GET /socket/_ws','HEAD /media/storage/default-avatar.png','OPTIONS /service/api/v2/users/me']);
  requests.length = 0;
  const configured = await checkDeploymentEndpoints({api:`${api}/service`,media:`${media}/media`,realtime:`${realtime}/socket/_ws`,origin});
  assert.deepEqual(configured,result);
  assert.ok(requests.includes('GET /socket/_ws'));
});

test('check accepts a valid upgrade and reports unrelated HTTP responses independently', async t => {
  const base = await listen(t,(request,response) => {
    if (request.url === '/api/ready') return response.end('<html>fallback</html>');
    response.writeHead(302,{location:'/another-host'}).end();
  }, (request,socket) => {
    assert.equal(request.url,'/_ws');
    const key = request.headers['sec-websocket-key'];
    const digest = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.end(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${digest}\r\n\r\n`);
  });
  const result = await checkDeploymentEndpoints({api:base, origin:base});
  assert.deepEqual(result,{ok:false,checks:{
    api:{ok:false,status:200,reason:'invalid-readiness-response'},
    media:{ok:false,status:302,reason:'redirect'},
    realtime:{ok:true,status:101},
  }});
  await assert.rejects(()=>checkDeploymentEndpoints({api:base,realtime:`${base}?token=fixture`}), /credentials/);
});

test('check distinguishes an unavailable backend, rejected CORS and an unrelated authentication response', async t => {
  const base = await listen(t,(request,response) => {
    if (request.url === '/api/ready') {
      response.statusCode = 503;
      return json(response,{status:'unavailable'});
    }
    if (request.method === 'HEAD') {
      return response.writeHead(200,{'content-length':52,'content-type':'image/png'}).end();
    }
    if (request.method === 'OPTIONS') return response.writeHead(204).end();
    response.statusCode = 401;
    json(response,{code:123});
  });
  const result = await checkDeploymentEndpoints({api:base,origin:'https://client.example.test'});
  assert.deepEqual(result,{ok:false,checks:{
    api:{ok:false,status:503,reason:'backend-not-ready'},
    media:{ok:false,status:200,reason:'media-cors-rejected'},
    realtime:{ok:false,status:401,reason:'invalid-realtime-response'},
    apiCors:{ok:false,status:204,reason:'api-cors-rejected'},
  }});
});
