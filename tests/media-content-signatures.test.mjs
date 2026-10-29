import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {fileTypeFromBuffer} from 'file-type';

const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/media-content-signatures.json',import.meta.url),'utf8'));
for(const c of vectors.cases)test(`Nuxt media signature: ${c.id}`,async()=>{
 assert.deepEqual((await fileTypeFromBuffer(Buffer.from(c.hex,'hex')))??null,c.expected);
});
