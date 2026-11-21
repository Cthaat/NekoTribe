import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const [mode,root,manifest,...extra] = process.argv.slice(2);
if (!['--plan','--apply'].includes(mode) || !root || !manifest || extra.length) {
  console.error('Usage: node scripts/migrate-storage-s3.mjs --plan|--apply <local-storage-root> <manifest.json>');
  process.exitCode = 2;
} else {
  try {
    const entry = fileURLToPath(new URL('./lib/storage-s3-migration.ts',import.meta.url));
    const compiled = await build({entryPoints:[entry],platform:'node',format:'esm',bundle:true,write:false});
    const code = Buffer.from(compiled.outputFiles[0].text).toString('base64');
    const {migrateStorage} = await import(`data:text/javascript;base64,${code}`);
    try { console.info(JSON.stringify(await migrateStorage({root,manifest,apply:mode==='--apply'}))); }
    catch(error) {
      if (error instanceof Error && error.cause) console.error(error.message);
      else console.error('Could not read the migration manifest or storage root.');
      process.exitCode = 1;
    }
  } catch {
    console.error('Could not load the storage migration tool.');
    process.exitCode = 1;
  }
}
