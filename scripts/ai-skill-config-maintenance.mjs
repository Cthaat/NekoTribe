import {readFileSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';
import {loadOracleDriver} from './migrate-db.mjs';
import {loadMaintenanceRuntime} from './ai-public-terms-maintenance.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const knownErrors=new Set(['SKILL_CONFIG_CONFLICT','SKILL_CONFIG_COMMIT_UNCERTAIN','SKILL_CONFIG_WRITE_FAILED','SKILL_CONFIG_INVALID_INPUT']);
function parseArgs(args) {
  let mode,expected,dotenv,enabled;
  for(let i=0;i<args.length;i++) {
    const arg=args[i];
    if(['--plan','--status','--publish'].includes(arg)){if(mode)throw Error('INVALID_ARGUMENTS');mode=arg.slice(2)}
    else if(arg==='--expected'){if(expected!==undefined || !/^(0|[1-9][0-9]{0,14})$/.test(args[i+1]??''))throw Error('INVALID_ARGUMENTS');expected=Number(args[++i])}
    else if(arg==='--dotenv'){if(dotenv!==undefined || !args[i+1] || args[i+1].startsWith('--'))throw Error('INVALID_ARGUMENTS');dotenv=args[++i]}
    else if(arg==='--enabled-json'){if(enabled!==undefined || !args[i+1] || Buffer.byteLength(args[i+1],'utf8')>512)throw Error('INVALID_ARGUMENTS');try {enabled=JSON.parse(args[++i])} catch {throw Error('INVALID_ARGUMENTS')}}
    else throw Error('INVALID_ARGUMENTS');
  }
  mode??='plan';
  if((mode==='plan' && (dotenv!==undefined || expected!==undefined)) || (mode==='status' && (!dotenv || expected!==undefined || enabled!==undefined)) || (mode==='publish' && (!dotenv || expected===undefined || expected>=999999999999999 || enabled===undefined)))throw Error('INVALID_ARGUMENTS');
  return {mode,expected,dotenv,enabled};
}
export async function maintainSkills({args=[],env=process.env,readEnv=path=>parseEnv(readFileSync(path,'utf8')),loadRuntime=loadMaintenanceRuntime,loadDriver=()=>loadOracleDriver(root),output=console.log}={}) {
  const {mode,expected,dotenv,enabled}=parseArgs(args);const runtime=await loadRuntime();const configured=enabled===undefined?[]:enabled;
  if(mode!=='status')try {new runtime.SkillRegistry(configured)} catch {throw Error('SKILL_CONFIG_INVALID_INPUT')}
  if(mode==='plan'){const result={mode,enabled:[...configured].sort(),connected:false};output(JSON.stringify(result));return result}
  const config={...readEnv(resolve(root,dotenv)),...env};const get=name=>config[`NUXT_${name}`]??config[name];
  const [user,password,host,port,service]=['ORACLE_USER','ORACLE_PASSWORD','ORACLE_HOST','ORACLE_PORT','ORACLE_SERVICE_NAME'].map(get);
  if(![user,password,host,port,service].every(v=>typeof v==='string' && v.length>0))throw Error('SKILL_CONFIG_CONFIGURATION_INVALID');
  let connection,result;
  try {
    const imported=await loadDriver();const driver=imported.default??imported;
    connection=await driver.getConnection({user,password,connectString:`${host}:${port}/${service}`});
    if(mode==='status'){
      const query=await connection.execute('SELECT generation,enabled_ids FROM n_ai_skill_config WHERE singleton_id=:singleton_id',{singleton_id:1},{outFormat:driver.OUT_FORMAT_OBJECT});
      if(!query.rows || query.rows.length>1)throw Error('STATUS_INVALID');const row=query.rows[0];
      if(row){if(!Number.isSafeInteger(row.GENERATION) || row.GENERATION<1 || row.GENERATION>999999999999999 || typeof row.ENABLED_IDS!=='string' || Buffer.byteLength(row.ENABLED_IDS,'utf8')>512)throw Error('STATUS_INVALID');const items=JSON.parse(row.ENABLED_IDS);new runtime.SkillRegistry(items);result={mode,generation:row.GENERATION,enabled:items};}
      else result={mode,initialized:false};
    } else result=await runtime.publishSkillConfig(connection,{expectedGeneration:expected,enabled});
  } catch(error) {throw Error(knownErrors.has(error?.message)?error.message:'SKILL_CONFIG_OPERATION_FAILED')}
  finally {if(connection)try {await connection.close()} catch {throw Error('SKILL_CONFIG_CONNECTION_CLOSE_FAILED')}}
  output(JSON.stringify(result));return result;
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {await maintainSkills({args:process.argv.slice(2)})} catch(error) {
    const code=knownErrors.has(error?.message) || ['INVALID_ARGUMENTS','SKILL_CONFIG_CONFIGURATION_INVALID','SKILL_CONFIG_OPERATION_FAILED','SKILL_CONFIG_CONNECTION_CLOSE_FAILED'].includes(error?.message)?error.message:'SKILL_CONFIG_OPERATION_FAILED';
    console.error(`${code}: use --plan [--enabled-json JSON], --status --dotenv PATH, or --publish --expected N --enabled-json JSON --dotenv PATH. Read status before retrying an uncertain commit.`);process.exitCode=1;
  }
}
