import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Ajv = require('ajv');
const spec = JSON.parse(readFileSync(new URL('../doc/v2.openapi.json', import.meta.url)));
const evidence = JSON.parse(readFileSync(new URL('../docs/audits/2026-10-25-contract-payloads/evidence.json', import.meta.url)));
const ajv = new Ajv({ nullable: true, unknownFormats: 'ignore', strictKeywords: false });
const base = 'https://neko.invalid/payload-contract';
ajv.addSchema(spec, base);
const validate = (name, value) => ajv.compile({ $ref: `${base}#/components/schemas/${name}` })(value);
// Local refs in operation fragments need the document's canonical base.
function requestValidator(method, path) {
  const pointer = path.replaceAll('~', '~0').replaceAll('/', '~1');
  return ajv.compile({ $ref: `${base}#/paths/${pointer}/${method}/requestBody/content/application~1json/schema` });
}

test('OTP SMS failure is documented for Nuxt and native error envelopes', () => {
  const path='/api/v2/auth/otp'.replaceAll('~','~0').replaceAll('/','~1');
  const validate501=ajv.compile({$ref:`${base}#/paths/${path}/post/responses/501/content/application~1json/schema`});
  const business={code:50101,message:'短信验证码暂不可用',data:null,meta:null};
  assert.equal(validate501(business),true);
  assert.equal(validate501({error:true,url:'/api/v2/auth/otp',statusCode:501,statusMessage:'短信验证码暂不可用',message:'短信验证码暂不可用',data:business}),true);
});

test('registration contract requires consent and documents duplicate or unverified OTP', () => {
  const validateRequest=requestValidator('post','/api/v2/auth/registration');
  const body={email:'new@example.test',username:'newuser',password:'synthetic',confirm_password:'synthetic',display_name:'New User',verification_id:'otp_fixture',agree_to_terms:true};
  assert.equal(validateRequest(body),true);assert.equal(validateRequest({...body,agree_to_terms:false}),false);assert.equal(validateRequest({...body,display_name:'   '}),false);assert.equal(validateRequest({...body,username:123}),true);
  for(const status of ['409','422']) {const pointer='/api/v2/auth/registration'.replaceAll('/','~1');const validateError=ajv.compile({$ref:`${base}#/paths/${pointer}/post/responses/${status}/content/application~1json/schema`});assert.equal(validateError({code:Number(status)*100+1,message:'test',data:null,meta:null}),true);}
});

test('the 39 audited operations have concrete success contracts and retain evidence', () => {
  assert.equal(evidence.operations, 39);
  const keys = new Set();
  for (const item of evidence.evidence) {
    const key = item.method.toUpperCase() + ' ' + item.path;
    assert(!keys.has(key), key);
    keys.add(key);
    const operation = spec.paths[item.path][item.method];
    assert.equal(operation['x-contract-audit'].status, 'source-audited', key);
    assert.equal(operation['x-schema-audit-status'], undefined, key);
    assert(operation.responses['200'].content['application/json'].schema, key);
  }
  assert.equal(keys.size, 39);
});

test('JSON errors preserve the actual Nitro outer transport and optional business envelope', () => {
  const outer = { error: true, url: 'https://neko.invalid/api/v2/example', statusCode: 401, statusMessage: 'Unauthorized', message: 'Not authenticated' };
  const business = { code: 40101, message: 'Not authenticated', data: null, meta: null };
  assert.equal(validate('V2HttpErrorTransport', { ...outer, data: business }), true);
  assert.equal(validate('V2HttpErrorTransport', outer), true);
  assert.equal(validate('V2HttpErrorTransport', business), false);
  assert.equal(validate('V2HttpErrorTransport', { ...outer, statusCode: '401' }), false);
});

test('notification and partial post bodies preserve documented omission and coercion semantics', () => {
  const preference = requestValidator('put', '/api/v2/groups/{id}/notification-preference');
  assert.equal(preference({}), true);
  assert.equal(preference({ is_enabled: 'YES' }), true);
  assert.equal(preference({ is_enabled: null }), true);
  assert.equal(preference([]), false);
  const update = requestValidator('put', '/api/v2/posts/{id}');
  assert.equal(update({}), true);
  assert.equal(update({ visibility: 'public', media_ids: [] }), true);
  assert.equal(update({ visibility: 'unknown' }), false);
  assert.equal(update({ media_ids: 'not-an-array' }), true); // Actual helper normalizes this to [].
});

test('account required text matches scalar coercion without accepting blank or object input', () => {
  for (const value of ['password', 123, true]) assert.equal(validate('AuditedAccountRequiredText', value), true);
  for (const value of ['', '   ', null, {}, []]) assert.equal(validate('AuditedAccountRequiredText', value), false);
});

test('SentimentFlow contracts preserve the pinned upstream body and explicitly identify stubs', () => {
  assert.equal(validate('AuditedSentimentPredictRequest', { text: 'hello', model: null }), true);
  assert.equal(validate('AuditedSentimentPredictRequest', { text: '', model: 'lstm' }), false);
  assert.equal(validate('AuditedSentimentPredictRequest', { text: 'hello', model: 'unknown' }), false);
  assert.equal(validate('AuditedSentimentPredictRequest', { text: 'hello', client_extension: true }), true);
  assert.equal(validate('AuditedSentimentLoginStub', { message: 'login stub' }), true);
  assert.equal(validate('AuditedSentimentLoginStub', { access_token: 'invented-token' }), false);
  for (const [path, operations] of Object.entries(spec.paths)) {
    for (const operation of Object.values(operations)) {
      if (operation['x-implementation-kind'] !== 'dynamic-proxy') continue;
      assert.equal(operation['x-contract-audit'].upstream.commit, '744b7a448588266f1c54b1d1db38e07ae7e0894e');
      assert.equal(operation['x-contract-audit'].runtimeVerification, 'pending');
      assert(operation.responses['400'].content['application/json'].schema, path);
      assert(operation.responses['500'].content['application/json'].schema, path);
    }
  }
});
