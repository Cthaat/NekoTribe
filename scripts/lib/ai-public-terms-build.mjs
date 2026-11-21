import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');

/** Bundle the same reviewed component for a source checkout or production image. */
export async function buildTermsMaintenanceBundle({outfile}={}) {
  const {build}=await import('esbuild');
  const readiness=`import oracledb from 'oracledb';import {assertSchemaReady} from './server/database/schema.mjs';export async function requireFeatureSchema(connection,feature){await assertSchemaReady({async execute(sql,binds={}){if(!/^SELECT\\b/i.test(sql.trim()))throw Error('readonly');return connection.execute(sql,binds,{outFormat:oracledb.OUT_FORMAT_OBJECT})}},feature)}`;
  const stubs={'~/server/database/readiness':readiness,'~/server/utils/v2':`export function v2Auth(){throw Error('not available in maintenance')}`};
  return build({stdin:{contents:`export {changeTermsAuthority} from './server/services/ai/public-terms-publication.ts';export {termsCatalogDigest} from './server/services/ai/public-terms-authority.ts';export {parseTermsCatalog} from './server/services/ai/public-terms-source.ts';export {publishSkillConfig} from './server/services/ai/skill-config-publication.ts';export {SkillRegistry} from './server/services/ai/skill-selection.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:!!outfile,...(outfile?{outfile}:{}),platform:'node',format:'cjs',packages:'external',plugins:[{name:'maintenance-boundary',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'maintenance'}:undefined);b.onLoad({filter:/.*/,namespace:'maintenance'},a=>({contents:stubs[a.path],resolveDir:root,loader:'js'}))}}]});
}
