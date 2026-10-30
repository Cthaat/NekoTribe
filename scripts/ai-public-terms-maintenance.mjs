import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';
import {loadOracleDriver} from './migrate-db.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const catalogPath=resolve(root,'specifications/requirements/ai-public-terms-catalog.json');
const knownErrors=new Set(['TERMS_AUTHORITY_CONFLICT','TERMS_AUTHORITY_COMMIT_UNCERTAIN','TERMS_AUTHORITY_WRITE_FAILED','TERMS_AUTHORITY_INVALID_INPUT']);

// Source checkouts build in memory; release images load their build-time bundle.
async function loadMaintenanceRuntime() {
  if(process.env.NEKO_TERMS_PACKAGED==='1') {
    const bundle=resolve(root,'.output/server/ai-terms-maintenance.cjs');
    return createRequire(bundle)(bundle);
  }
  const {buildTermsMaintenanceBundle}=await import('./lib/ai-public-terms-build.mjs');
  const built=await buildTermsMaintenanceBundle();
  const module={exports:{}};
  new Function('require','module','exports',built.outputFiles[0].text)(createRequire(resolve(root,'package.json')),module,module.exports);
  return module.exports;
}

function parseArgs(args) {
  let mode,expected,dotenv;
  for(let i=0;i<args.length;i++) {
    const arg=args[i];
    if(['--plan','--status','--publish','--disable'].includes(arg)){if(mode)throw Error('INVALID_ARGUMENTS');mode=arg.slice(2)}
    else if(arg==='--expected'){if(expected!==undefined || !/^(0|[1-9][0-9]{0,14})$/.test(args[i+1]??''))throw Error('INVALID_ARGUMENTS');expected=Number(args[++i])}
    else if(arg==='--dotenv'){if(dotenv!==undefined || !args[i+1] || args[i+1].startsWith('--'))throw Error('INVALID_ARGUMENTS');dotenv=args[++i]}
    else throw Error('INVALID_ARGUMENTS');
  }
  mode??='plan';
  if((mode==='plan' && (dotenv!==undefined || expected!==undefined)) || (mode==='status' && (!dotenv || expected!==undefined)) || (['publish','disable'].includes(mode) && (!dotenv || expected===undefined || expected>=999999999999999 || (mode==='disable' && expected===0)))) throw Error('INVALID_ARGUMENTS');
  return {mode,expected,dotenv};
}

export async function maintainTerms({args=[],env=process.env,readEnv=path=>parseEnv(readFileSync(path,'utf8')),loadRuntime=loadMaintenanceRuntime,loadDriver=()=>loadOracleDriver(root),output=console.log}={}) {
  const {mode,expected,dotenv}=parseArgs(args);
  const catalog=JSON.parse(readFileSync(catalogPath,'utf8'));
  const runtime=await loadRuntime();const digest=runtime.termsCatalogDigest(catalog);
  if(mode==='plan'){const result={mode,digest,connected:false};output(JSON.stringify(result));return result}
  const config={...readEnv(resolve(root,dotenv)),...env};const get=name=>config[`NUXT_${name}`]??config[name];
  const [user,password,host,port,service]=['ORACLE_USER','ORACLE_PASSWORD','ORACLE_HOST','ORACLE_PORT','ORACLE_SERVICE_NAME'].map(get);
  if(![user,password,host,port,service].every(v=>typeof v==='string' && v.length>0))throw Error('TERMS_AUTHORITY_CONFIGURATION_INVALID');
  let connection,result;
  try {
    const imported=await loadDriver();const driver=imported.default??imported;
    connection=await driver.getConnection({user,password,connectString:`${host}:${port}/${service}`});
    if(mode==='status'){
      const query=await connection.execute('SELECT catalog_digest,generation,enabled FROM n_ai_terms_active WHERE singleton_id=:singleton_id',{singleton_id:1},{outFormat:driver.OUT_FORMAT_OBJECT});
      if(!query.rows || query.rows.length>1)throw Error('STATUS_INVALID');
      const row=query.rows[0];
      if(row && (typeof row.CATALOG_DIGEST!=='string' || !/^[a-f0-9]{64}$/.test(row.CATALOG_DIGEST) || !Number.isSafeInteger(row.GENERATION) || row.GENERATION<1 || row.GENERATION>999999999999999 || ![0,1].includes(row.ENABLED)))throw Error('STATUS_INVALID');
      result=row?{mode,digest:row.CATALOG_DIGEST,generation:row.GENERATION,enabled:row.ENABLED===1,localDigest:digest}:{mode,initialized:false,localDigest:digest};
    } else {
      result=await runtime.changeTermsAuthority(connection,mode==='publish'?{action:'publish',expectedGeneration:expected,catalog}:{action:'disable',expectedGeneration:expected});
    }
  } catch(error) {
    throw Error(knownErrors.has(error?.message)?error.message:'TERMS_AUTHORITY_OPERATION_FAILED');
  } finally {
    if(connection)try {await connection.close()} catch {throw Error('TERMS_AUTHORITY_CONNECTION_CLOSE_FAILED')}
  }
  output(JSON.stringify(result));return result;
}

if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {await maintainTerms({args:process.argv.slice(2)})} catch(error) {
    const code=knownErrors.has(error?.message) || ['INVALID_ARGUMENTS','TERMS_AUTHORITY_CONFIGURATION_INVALID','TERMS_AUTHORITY_OPERATION_FAILED','TERMS_AUTHORITY_CONNECTION_CLOSE_FAILED'].includes(error?.message)?error.message:'TERMS_AUTHORITY_OPERATION_FAILED';
    console.error(`${code}: use --plan, --status --dotenv PATH, --publish --expected N --dotenv PATH, or --disable --expected N --dotenv PATH. For uncertain commit, read status before any further operation.`);process.exitCode=1;
  }
}
