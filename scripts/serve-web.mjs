import { createReadStream } from 'node:fs';
import { readFile, realpath, stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.webp': 'image/webp', '.gif': 'image/gif', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8',
};

function decodePath(value) {
  const path = decodeURIComponent(value);
  if (!path.startsWith('/') || path.startsWith('//') || /[\\:\x00-\x1f\x7f?#]/.test(path) ||
      path.split('/').some(part => part.startsWith('.'))) throw Error('Invalid URL path.');
  return path;
}

async function publicFile(root, name) {
  try {
    const path = await realpath(join(root, name));
    const location = relative(root, path);
    if (!location || isAbsolute(location) || location === '..' || location.startsWith(`..${sep}`)) return null;
    const info = await stat(path);
    return info.isFile() ? {path, size:info.size} : null;
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null;
    throw error;
  }
}

export async function startWebPreview(site, port = 30004) {
  const root = await realpath(site);
  const index = await publicFile(root, 'index.html');
  if (!index) throw Error('The release is missing site/index.html.');
  const html = await readFile(index.path, 'utf8');
  const base = /<base\s+href\s*=\s*(["'])(.*?)\1/i.exec(html)?.[2];
  if (!base?.endsWith('/')) throw Error('The Flutter build needs an absolute base href with a trailing slash.');
  const prefix = decodePath(base);

  const server = createServer({headersTimeout:5000,requestTimeout:10000}, async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405, {Allow:'GET, HEAD'}).end();
      return;
    }

    let route;
    try { route = decodePath(request.url.split('?', 1)[0]); }
    catch { response.writeHead(400).end(); return; }
    if (!route.startsWith(prefix) || route.slice(prefix.length).startsWith('/')) {
      response.writeHead(404).end();
      return;
    }

    const name = route.slice(prefix.length);
    try {
      let file = name ? await publicFile(root, name) : index;
      if (!file && !extname(name) && request.headers.accept?.includes('text/html')) file = index;
      if (!file) { response.writeHead(404).end(); return; }
      response.writeHead(200, {
        'Content-Type': types[extname(file.path).toLowerCase()] ?? 'application/octet-stream',
        'Content-Length': file.size,
      });
      if (request.method === 'HEAD') response.end();
      else await pipeline(createReadStream(file.path), response);
    } catch {
      if (response.headersSent) response.destroy();
      else response.writeHead(500).end();
    }
  });
  await new Promise((ready, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => {
      server.off('error', reject);
      ready();
    });
  });
  return {server, url:`http://127.0.0.1:${server.address().port}${base}`};
}

const script = fileURLToPath(import.meta.url);
if (process.argv[1] && resolve(process.argv[1]) === script) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 2 || args[0] !== '--port' || !/^\d{1,5}$/.test(args[1]) ||
        Number(args[1]) < 1 || Number(args[1]) > 65535)) throw Error('Usage: node serve-web.mjs [--port PORT]');
    const {url} = await startWebPreview(fileURLToPath(new URL('./site/', import.meta.url)), args.length ? Number(args[1]) : 30004);
    console.info(`Flutter Web: ${url}`);
  } catch (error) {
    console.error(error.code === 'EADDRINUSE' ? 'The preview port is already in use.' :
      error.code ? 'Could not open the Flutter Web release.' : error.message);
    process.exitCode = 1;
  }
}
