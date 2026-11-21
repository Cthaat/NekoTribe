import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse,compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import {z} from 'zod/v3';
const rules=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-account-input.json',import.meta.url)));
for(const [file,name] of [['pages/auth/sign-up.vue','signUpFormSchema'],['pages/auth/forgot-password.vue','forgotPasswordFormSchema'],['components/SecurityPageEmail.vue','emailChangeFormSchema']]){
 const {descriptor}=parse(readFileSync(new URL('../app/'+file,import.meta.url),'utf8'));
 const ast=compileScript(descriptor,{id:'account-input'}).scriptSetupAst;
 const node=ast.find(n=>n.type==='VariableDeclaration'&&n.declarations.some(d=>d.id.name===name));
 const built=await transform(descriptor.scriptSetup.content.slice(node.start,node.end),{loader:'ts'});
 const schema=new Function('z','t',built.code+';return '+name)(z,x=>x);
 const cases=file.includes('sign-up')?rules.cases:rules.emailCases.map(c=>({...c,field:'email'}));
 for(const c of cases.filter(c=>typeof c.raw==='string'))test(`${file}: ${c.id}`,()=>{
  const key=c.field==='display_name'?'displayName':c.field;
  const body={email:'new@example.test',username:'edge',displayName:'Edge',phone:'',location:'',bio:'',captcha:'123456',agreeToTerms:true,password:'synthetic',newPassword:'synthetic',confirmPassword:'synthetic',[key]:c.raw};
  const out=schema.safeParse(body);assert.equal(out.success,c.valid,c.id);if(out.success)assert.equal(out.data[key],c.normalized);
 });
}
