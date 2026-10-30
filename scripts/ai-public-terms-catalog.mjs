import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildPublicTermsCatalog,checkPublicTermsPage} from './lib/ai-public-terms-catalog.mjs';

const mode=process.argv[2];
if(!['--write','--check'].includes(mode) || process.argv.length!==3) throw new Error('Use --write or --check');
const read=locale=>JSON.parse(readFileSync(new URL(`../i18n/locales/${locale}.json`,import.meta.url),'utf8'));
const page=readFileSync(new URL('../app/pages/auth/terms.vue',import.meta.url),'utf8');
checkPublicTermsPage(page);
const text=JSON.stringify(buildPublicTermsCatalog({zh:read('zh'),en:read('en')}),null,2)+'\n';
for(const path of ['../specifications/requirements/ai-public-terms-catalog.json','../../rust/contracts/requirements/ai-public-terms-catalog.json','../../go/contracts/requirements/ai-public-terms-catalog.json']) {
  const url=new URL(path,import.meta.url);
  if(mode==='--write') {mkdirSync(dirname(fileURLToPath(url)),{recursive:true});writeFileSync(url,text,'utf8');}
  else if(readFileSync(url,'utf8').replaceAll('\r\n','\n')!==text) throw new Error(`Public terms catalog is stale: ${path}`);
}
if(mode==='--check') console.log('Public terms catalog matches page translations and shared copies.');
