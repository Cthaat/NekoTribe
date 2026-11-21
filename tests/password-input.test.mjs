import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse,compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import {z} from 'zod/v3';
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-password-input.json',import.meta.url),'utf8'));
const pages=[['pages/auth/login.vue','loginFormSchema','password',true],['pages/auth/sign-up.vue','signUpFormSchema','password',false],['pages/auth/forgot-password.vue','forgotPasswordFormSchema','newPassword',false],['components/SecurityPagePasswordForm.vue','passwordChangeFormSchema','newPassword',false]];
for(const [file,name,key,login]of pages){
 const {descriptor}=parse(readFileSync(new URL('../app/'+file,import.meta.url),'utf8'));const ast=compileScript(descriptor,{id:'password-input'}).scriptSetupAst;
 const n=ast.find(n=>n.type==='VariableDeclaration'&&n.declarations.some(d=>d.id.name===name));const built=await transform(descriptor.scriptSetup.content.slice(n.start,n.end),{loader:'ts'});const schema=new Function('z','t',built.code+';return '+name)(z,x=>x);
 for(const c of fixture.cases)test(`${file}: ${c.id}`,()=>{
  const body={account:'edge',email:'edge@example.test',username:'edge',displayName:'Edge',phone:'',location:'',bio:'',captcha:'123456',agreeToTerms:true,[key]:c.raw,confirmPassword:c.confirm};
  const result=schema.safeParse(body);assert.equal(result.success,login?c.validLogin:c.validNewPassword&&c.matches);
  if(result.success)assert.equal(result.data[key],c.normalized);
 });
}
