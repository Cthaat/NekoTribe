import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {schemaFeatures} from '../server/database/schema-definition.mjs';
import {describeStep,planSchema} from '../server/database/schema.mjs';
import {schemaFixture} from '../tests/helpers/schema-fixture.mjs';
const feature=schemaFeatures.find(x=>x.id==='media');if(!feature||feature.steps.length!==1)throw Error('Media schema changed; review catalog.');
const ledger=describeStep({id:'ledger',kind:'table',name:'N_SCHEMA_MIGRATIONS',sql:'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)'});
const sources=['server/database/schema-definition.mjs','server/database/schema.mjs'].map(path=>({path,sha256:createHash('sha256').update(readFileSync(new URL(`../${path}`,import.meta.url),'utf8').replaceAll('\r\n','\n')).digest('hex')}));
const catalog={id:'MEDIA-SCHEMA-CATALOG',revision:1,scope:'Read-only Nuxt media schema expectations; absence of ledger is allowed',sources,ledger,migrationChecksums:Object.fromEntries(planSchema().flatMap(group=>group.steps.map(step=>[step.id,step.checksum]))),feature:{id:'media',steps:feature.steps.map(describeStep)}};
const auth=JSON.parse(readFileSync(new URL('../specifications/scenarios/two-factor-readiness.json',import.meta.url),'utf8')).baseline;const table=schemaFixture().state.tables.get('N_MEDIA_ASSETS');
const baseline={owner:auth.owner,ledgerPresent:true,tables:{N_SCHEMA_MIGRATIONS:auth.tables.N_SCHEMA_MIGRATIONS,N_MEDIA_ASSETS:table},records:auth.records,sequences:{},indexes:{}};
const mutation=(op,path,value)=>({op,path,...(op==='set'?{value}:{})});const C=['tables','N_MEDIA_ASSETS','columns',0];
const vectors={id:'MEDIA-READINESS',revision:1,baseline,cases:[
{id:'MEDIA-01',ready:true,mutations:[]},
{id:'MEDIA-02',ready:true,mutations:[mutation('set',['ledgerPresent'],false)]},
{id:'MEDIA-03',ready:false,mutations:[mutation('set',['owner','schema'],'OTHER')]},
{id:'MEDIA-04',ready:false,mutations:[mutation('delete',['tables','N_MEDIA_ASSETS'])]},
{id:'MEDIA-05',ready:false,mutations:[mutation('delete',['tables','N_MEDIA_ASSETS','columns',0])]},
{id:'MEDIA-06',ready:false,mutations:[mutation('set',[...C,'DATA_TYPE'],'NUMBER')]},
{id:'MEDIA-07',ready:false,mutations:[mutation('set',[...C,'CHAR_LENGTH'],999)]},
{id:'MEDIA-08',ready:false,mutations:[mutation('set',[...C,'NULLABLE'],'N')]},
{id:'MEDIA-09',ready:false,mutations:[mutation('set',[...C,'DATA_DEFAULT'],"'x'")]},
{id:'MEDIA-10',ready:false,mutations:[mutation('set',['records',0,'CHECKSUM'],'bad')]},
{id:'MEDIA-11',ready:false,mutations:[mutation('set',['records',0,'STEP_ID'],'unknown')]},
{id:'MEDIA-12',ready:false,mutations:[mutation('set',['tables','N_SCHEMA_MIGRATIONS','columns',0,'CHAR_LENGTH'],127)]},
{id:'MEDIA-13',ready:false,mutations:[mutation('set',['owner','user'],'')]},
{id:'MEDIA-14',ready:true,mutations:[mutation('set',['records'],[])]}
]};
for(const [path,data] of [['../specifications/requirements/media-schema-catalog.json',catalog],['../specifications/scenarios/media-readiness.json',vectors]]){const url=new URL(path,import.meta.url),output=JSON.stringify(data,null,2)+'\n';if(process.argv[2]==='--write')writeFileSync(url,output);else if(process.argv[2]==='--check'){if(readFileSync(url,'utf8').replaceAll('\r\n','\n')!==output)throw Error(`${path} is stale`)}else throw Error('Use --write or --check')}
