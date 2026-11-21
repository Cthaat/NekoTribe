import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {schemaFeatures} from '../server/database/schema-definition.mjs';
import {describeStep,planSchema} from '../server/database/schema.mjs';
import {schemaFixture} from '../tests/helpers/schema-fixture.mjs';

const feature=schemaFeatures.find(value=>value.id==='ai-skills');
if(!feature || feature.steps.length!==1)throw new Error('Skill schema changed; review catalog.');
const ledger=describeStep({id:'ledger',kind:'table',name:'N_SCHEMA_MIGRATIONS',sql:'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)'});
const sources=['server/database/schema-definition.mjs','server/database/schema.mjs'].map(path=>({path,sha256:createHash('sha256').update(readFileSync(new URL(`../${path}`,import.meta.url),'utf8').replaceAll('\r\n','\n')).digest('hex')}));
const catalog={id:'AI-SKILL-SCHEMA-CATALOG',revision:1,scope:'Read-only shared AI skill configuration schema; absence of ledger is allowed',sources,ledger,migrationChecksums:Object.fromEntries(planSchema().flatMap(group=>group.steps.map(step=>[step.id,step.checksum]))),feature:{id:'ai-skills',steps:feature.steps.map(describeStep)}};
const auth=JSON.parse(readFileSync(new URL('../specifications/scenarios/two-factor-readiness.json',import.meta.url),'utf8')).baseline;
const baseline={owner:auth.owner,ledgerPresent:true,tables:{N_SCHEMA_MIGRATIONS:auth.tables.N_SCHEMA_MIGRATIONS,N_AI_SKILL_CONFIG:schemaFixture().state.tables.get('N_AI_SKILL_CONFIG')},records:auth.records,sequences:{},indexes:{}};
const change=(op,path,value)=>({op,path,...(op==='set'?{value}:{})});
const vectors={id:'AI-SKILL-READINESS',revision:1,baseline,cases:[
 {id:'SKILL-SCHEMA-01',ready:true,mutations:[]},
 {id:'SKILL-SCHEMA-02',ready:true,mutations:[change('set',['ledgerPresent'],false)]},
 {id:'SKILL-SCHEMA-03',ready:false,mutations:[change('set',['owner','schema'],'OTHER')]},
 {id:'SKILL-SCHEMA-04',ready:false,mutations:[change('delete',['tables','N_AI_SKILL_CONFIG'])]},
 {id:'SKILL-SCHEMA-05',ready:false,mutations:[change('delete',['tables','N_AI_SKILL_CONFIG','columns',0])]},
 {id:'SKILL-SCHEMA-06',ready:false,mutations:[change('set',['tables','N_AI_SKILL_CONFIG','columns',2,'CHAR_LENGTH'],128)]},
 {id:'SKILL-SCHEMA-07',ready:false,mutations:[change('delete',['tables','N_AI_SKILL_CONFIG','constraints',1])]},
 {id:'SKILL-SCHEMA-08',ready:false,mutations:[change('set',['records',0,'CHECKSUM'],'bad')]}
]};
for(const [path,value] of [['../specifications/requirements/ai-skill-schema-catalog.json',catalog],['../specifications/scenarios/ai-skill-readiness.json',vectors]]) {
 const output=new URL(path,import.meta.url),text=JSON.stringify(value,null,2)+'\n';
 if(process.argv[2]==='--write')writeFileSync(output,text);
 else if(process.argv[2]==='--check'){if(readFileSync(output,'utf8').replaceAll('\r\n','\n')!==text)throw new Error('Skill schema data is stale.')}
 else throw new Error('Use --write or --check');
}
if(process.argv[2]==='--check')console.log('AI skill schema catalog and scenarios match migration definitions.');
