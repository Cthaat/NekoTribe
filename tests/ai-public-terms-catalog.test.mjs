import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {buildPublicTermsCatalog,checkPublicTermsPage} from '../scripts/lib/ai-public-terms-catalog.mjs';

const load=locale=>JSON.parse(readFileSync(new URL(`../i18n/locales/${locale}.json`,import.meta.url),'utf8'));
test('catalog reflects each visible terms section and preserves translated text',()=>{
 const zh=load('zh'),en=load('en');const catalog=buildPublicTermsCatalog({zh,en});
 assert.equal(catalog.documents.length,8);
 const conduct=catalog.documents.find(x=>x.locale==='zh' && x.key==='terms.conduct');
 assert.equal(conduct.href,'/zh/auth/terms#conduct');
 assert.deepEqual(conduct.blocks,[zh.auth.terms.sections.conduct.content,zh.auth.terms.sections.conduct.alertTitle,...Object.values(zh.auth.terms.sections.conduct.prohibited)]);
 assert.equal(catalog.documents.find(x=>x.locale==='en' && x.key==='terms.acceptance').blocks[0],en.auth.terms.sections.acceptance.content);
});
test('missing, malformed or empty page text fails catalog generation',()=>{
 const zh=load('zh'),en=load('en');zh.auth.terms.sections.conduct.prohibited.item2='';
 assert.throws(()=>buildPublicTermsCatalog({zh,en}),/terms/);
 assert.throws(()=>buildPublicTermsCatalog({zh,en:{}}),/terms/);
});
test('detects when source page removes a referenced section',()=>{
 const page=readFileSync(new URL('../app/pages/auth/terms.vue',import.meta.url),'utf8');
 assert.doesNotThrow(()=>checkPublicTermsPage(page));
 assert.throws(()=>checkPublicTermsPage(page.replace("id: '#conduct'","id: '#other'")),/structure changed/);
});
test('checked-in shared catalogs match page translations',()=>{
 const expected=JSON.stringify(buildPublicTermsCatalog({zh:load('zh'),en:load('en')}),null,2)+'\n';
 for(const path of ['../specifications/requirements/ai-public-terms-catalog.json','../../rust/contracts/requirements/ai-public-terms-catalog.json','../../go/contracts/requirements/ai-public-terms-catalog.json']) {
  assert.equal(readFileSync(new URL(path,import.meta.url),'utf8').replaceAll('\r\n','\n'),expected,path);
 }
});
