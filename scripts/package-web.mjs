import { copyFile, cp, lstat, mkdir, realpath, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { configureWeb } from './configure-web.mjs';

const usage = 'Usage: node scripts/package-web.mjs WEB_BUILD_DIR --out NEW_RELEASE_DIR';
const scripts = dirname(fileURLToPath(import.meta.url));
const requiredFiles = ['index.html', 'flutter_bootstrap.js', 'main.dart.js'];
const optionalFiles = [
  'flutter.js', 'flutter_service_worker.js', 'favicon.png', 'manifest.json', 'version.json',
];
const assetDirectories = ['assets', 'canvaskit', 'icons'];
const instructions = `# NekoTribe Flutter Web

Publish only the site directory as the document root of IIS, Nginx, or your static server.
Use HTTPS for sign-in from other machines. If hosted below a URL prefix, use the prefix
selected when building Flutter. Allow the site origin on the backend when using a different origin.

From this directory, configure the browser-accessible API and verify the resulting addresses:

    node configure-web.mjs site --api https://api.example.com
    node configure-web.mjs site --check

Use --realtime, --media, or --share-site to override those addresses separately.
From the browser's machine, verify API, realtime, media and CORS separately:

    node check-deployment-endpoints.mjs --api https://api.example.com --origin https://site.example.com

The public file site/assets/assets/config/app_config.json must be served with revalidation.
Existing endpoint settings stored in a browser take priority over these defaults.

For a local preview with Node.js, double-click start.cmd on Windows or run sh start.sh
on Linux. Open the printed loopback URL. Pass --port PORT to select another port.
`;

async function sourceEntry(path, directory, optional = false) {
  const info = await lstat(path).catch(error => {
    if (optional && error.code === 'ENOENT') return null;
    throw error;
  });
  if (!info) return false;
  if (directory ? !info.isDirectory() : !info.isFile()) {
    throw Error('The Flutter build must contain regular files and directories.');
  }
  return true;
}

export async function packageWeb(build, destination) {
  const source = await realpath(build);
  const target = join(await realpath(dirname(destination)), basename(destination));
  const inside = relative(source, target);
  if (!inside || (!isAbsolute(inside) && inside !== '..' && !inside.startsWith(`..${sep}`))) {
    throw Error('The release directory must be outside the source build.');
  }
  await configureWeb(source);
  for (const name of requiredFiles) await sourceEntry(join(source, name), false);
  for (const name of ['assets', 'canvaskit']) await sourceEntry(join(source, name), true);
  await sourceEntry(join(source, 'canvaskit', 'canvaskit.wasm'), false);

  await mkdir(target);
  const site = join(target, 'site');
  await mkdir(site);
  for (const name of [...requiredFiles, ...optionalFiles]) {
    if (await sourceEntry(join(source, name), false, optionalFiles.includes(name))) {
      await copyFile(join(source, name), join(site, name));
    }
  }
  for (const name of assetDirectories) {
    const directory = join(source, name);
    if (!await sourceEntry(directory, true, name === 'icons')) continue;
    await cp(directory, join(site, name), {
      recursive: true,
      async filter(path) {
        const entry = await lstat(path);
        if (!entry.isDirectory() && !entry.isFile()) {
          throw Error('The Flutter build must contain regular files and directories.');
        }
        return true;
      },
    });
  }
  await copyFile(join(scripts, 'configure-web.mjs'), join(target, 'configure-web.mjs'));
  await copyFile(join(scripts, 'serve-web.mjs'), join(target, 'serve-web.mjs'));
  await copyFile(join(scripts, 'check-deployment-endpoints.mjs'), join(target, 'check-deployment-endpoints.mjs'));
  for (const extension of ['cmd', 'sh']) {
    await copyFile(join(scripts, 'release', `start-web.${extension}`), join(target, `start.${extension}`));
  }
  await writeFile(join(target, 'README.md'), instructions, {flag:'wx'});
  return configureWeb(site);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [source, flag, out, ...extra] = process.argv.slice(2);
    if (!source || flag !== '--out' || !out || extra.length) throw Error(usage);
    console.info(JSON.stringify(await packageWeb(resolve(source), resolve(out))));
  } catch (error) {
    console.error(error.code === 'EEXIST' ? 'Release directory already exists.' :
      error.code ? 'Could not read the Flutter build or write the release.' : error.message);
    process.exitCode = 1;
  }
}
