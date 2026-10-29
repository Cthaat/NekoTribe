import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {test} from 'node:test';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url)),require=createRequire(import.meta.url);
const compiled=await build({entryPoints:[path.join(root,'server/storage/index.ts')],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'external',setup(builder){builder.onResolve({filter:/.*/},args=>{if(args.path.startsWith('node:'))return{path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return{path:pathToFileURL(require.resolve(args.path)).href,external:true};});}}]});
const {selectMediaFileType}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/media-type-selection.json'),'utf8'));
for(const c of vectors.cases)test(`media type selection: ${c.id}`,()=>{
 assert.deepEqual(selectMediaFileType(c.name,c.uploaded,c.detected??undefined),c.expected);
});
