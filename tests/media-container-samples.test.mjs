import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {fileTypeFromBuffer} from 'file-type';

const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/media-container-samples.json',import.meta.url),'utf8'));
for(const c of vectors.cases)test(`Nuxt media container: ${c.id}`,async()=>{
 const data=Buffer.from(c.base64,'base64');assert.ok(data.length>4096);
 assert.deepEqual(await fileTypeFromBuffer(data),c.expected);
});
