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

test('post detail contract describes anonymous access and actual rich response', () => {
  const operation = spec.paths['/api/v2/posts/{id}'].get;
  assert.ok(operation.security.some(item => Object.keys(item).length === 0));
  assert.ok(operation.security.some(item => Object.hasOwn(item, 'accessTokenCookie')));
  const pointer = '/api/v2/posts/{id}'.replaceAll('/', '~1');
  const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-detail-vectors.json', import.meta.url)));
  const value = {code: 200, message: 'success', data: fixture.post, meta: null};
  assert.equal(check(value), true, JSON.stringify(check.errors));
  value.data.media[0].width = null;
  value.data.media[0].height = null;
  value.data.media[0].alt_text = null;
  value.data.media[0].description = null;
  assert.equal(check(value), true, JSON.stringify(check.errors));
  value.data.mentions = ['not a public user'];
  assert.equal(check(value), false);
  const error = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/503/content/application~1json/schema`});
  const businessError = {code: 50301, message: '服务暂不可用，请稍后重试。', data: null, meta: null};
  assert.equal(error(businessError), true, JSON.stringify(error.errors));
  assert.equal(error({error: true, url: '/api/v2/posts/1', statusCode: 503, statusMessage: 'Service temporarily unavailable', message: 'Service temporarily unavailable', data: businessError}), true, JSON.stringify(error.errors));
});

test('post list contract permits anonymous and rich results with compatible pagination', () => {
  const operation = spec.paths['/api/v2/posts'].get;
  assert.ok(operation.security.some(item => Object.keys(item).length === 0));
  assert.ok(operation.security.some(item => Object.hasOwn(item, 'accessTokenCookie')));
  const pointer = '/api/v2/posts'.replaceAll('/', '~1');
  const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-detail-vectors.json', import.meta.url)));
  const value = {code: 200, message: 'success', data: [fixture.post], meta: {page: 1.5, page_size: 2.5, total: 3, has_next: false}};
  assert.equal(check(value), true, JSON.stringify(check.errors));
  value.data[0].mentions = ['not a user'];
  assert.equal(check(value), false);
});

test('trending and personal list contracts match the common post payload', () => {
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-detail-vectors.json', import.meta.url)));
  const value = {code: 200, message: 'success', data: [fixture.post], meta: {page: 1, page_size: 20, total: 1, has_next: false}};
  for (const path of ['/api/v2/posts/trending', '/api/v2/users/me/posts', '/api/v2/users/me/bookmarks', '/api/v2/users/me/likes']) {
    const operation = spec.paths[path].get;
    assert.ok(operation.security.some(item => Object.hasOwn(item, 'accessTokenCookie')), path);
    assert.equal(operation.security.some(item => Object.keys(item).length === 0), path.endsWith('/trending'), path);
    const pointer = path.replaceAll('/', '~1');
    const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
    assert.equal(check(value), true, `${path}: ${JSON.stringify(check.errors)}`);
  }
});

test('scoped list contracts use authenticated access and a consistent post payload', () => {
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-detail-vectors.json', import.meta.url)));
  const value = {code: 200, message: 'success', data: [fixture.post], meta: {page: 1, page_size: 20, total: 1, has_next: false}};
  for (const path of ['/api/v2/users/{id}/posts', '/api/v2/tags/{name}/posts', '/api/v2/posts/{id}/replies', '/api/v2/posts/{id}/retweets']) {
    const op = spec.paths[path].get;
    assert.ok(op.security.some(item => Object.hasOwn(item, 'accessTokenCookie')), path);
    assert.ok(!op.security.some(item => Object.keys(item).length === 0), path);
    const pointer = path.replaceAll('/', '~1');
    const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
    assert.equal(check(value), true, `${path}: ${JSON.stringify(check.errors)}`);
    if (path.includes('{id}')) assert.equal(op.parameters.find(param => param.name === 'id').schema.maximum, 9007199254740991, path);
  }
});

test('tag list contracts describe authenticated tag objects and fractional score', () => {
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/tag-list.json', import.meta.url)));
  const value = {code: 200, message: 'success', data: fixture.items, meta: {page: 1.5, page_size: 2.5, total: 3, has_next: false}};
  for (const path of ['/api/v2/tags', '/api/v2/tags/trending']) {
    const op = spec.paths[path].get;
    assert.ok(op.security.some(item => Object.hasOwn(item, 'accessTokenCookie')), path);
    assert.ok(!op.parameters.some(item => item.name === 'limit'), path);
    const pointer = path.replaceAll('/', '~1');
    const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
    assert.equal(check(value), true, `${path}: ${JSON.stringify(check.errors)}`);
  }
});

test('tag analytics contract describes viewer-scoped fractional aggregate', () => {
  const op = spec.paths['/api/v2/tags/{name}/analytics'].get;
  assert.ok(op.security.some(item => Object.hasOwn(item, 'accessTokenCookie')));
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/tag-analytics.json', import.meta.url)));
  const pointer = '/api/v2/tags/{name}/analytics'.replaceAll('/', '~1');
  const check = ajv.compile({$ref: `${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
  assert.equal(check({code:200, message:'success', data:fixture.result, meta:null}), true, JSON.stringify(check.errors));
});
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

test('password reset contract requires scalar fields and documents both error transports', () => {
  const validateRequest = requestValidator('post', '/api/v2/auth/password-reset');
  const body = {email:'fake@example.test',verification_id:'otp_fixture',code:'123456',new_password:'synthetic'};
  assert.equal(validateRequest(body),true);
  assert.equal(validateRequest({...body,email:'  '}),false);
  assert.equal(validateRequest({...body,code:123456,extension:true}),true);
  const missing = {...body}; delete missing.new_password;
  assert.equal(validateRequest(missing),false);
  for (const status of ['400','401','404','500']) {
    const pointer='/api/v2/auth/password-reset'.replaceAll('/','~1');
    const validateError=ajv.compile({$ref:`${base}#/paths/${pointer}/post/responses/${status}/content/application~1json/schema`});
    const business={code:Number(status)*100+1,message:'test',data:null,meta:null};
    assert.equal(validateError(business),true);
    assert.equal(validateError({error:true,url:'/api/v2/auth/password-reset',statusCode:Number(status),statusMessage:'test',message:'test',data:business}),true);
  }
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

test('self profile contract represents nullable fields, online status and both error transports', () => {
  const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/user-self-profile.json',import.meta.url)));
  const pointer='/api/v2/users/me'.replaceAll('/','~1');
  const success=ajv.compile({$ref:`${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
  assert.equal(success({code:200,message:'success',data:fixture.profile,meta:null}),true);
  const missing={...fixture.profile};delete missing.email;
  assert.equal(success({code:200,message:'success',data:missing,meta:null}),false);
  for(const status of ['401','404','500']) {
    const check=ajv.compile({$ref:`${base}#/paths/${pointer}/get/responses/${status}/content/application~1json/schema`});
    const business={code:Number(status)*100+1,message:'test',data:null,meta:null};
    assert.equal(check(business),true);
    assert.equal(check({error:true,url:'/api/v2/users/me',statusCode:Number(status),statusMessage:'test',message:'test',data:business}),true);
  }
  assert.deepEqual(spec.paths['/api/v2/users/me'].get.security,[{bearerAuth:[]},{accessTokenCookie:[]}]);
  assert.equal(spec.paths['/api/v2/users/me'].get.responses['200'].headers['Cache-Control'].schema.enum[0],'private, no-store');
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

test('self profile patch contract matches successful response, cookie auth and permissive updates', () => {
  const update=requestValidator('patch','/api/v2/users/me');
  for(const value of [{},{bio:'hello'},{birth_date:null},{phone:42},{bio:false,unknown:'ignored'},{location:[],website:{}}]) assert.equal(update(value),true);
  assert.equal(update([]),false);
  const pointer='/api/v2/users/me'.replaceAll('/','~1');
  const result=ajv.compile({$ref:`${base}#/paths/${pointer}/patch/responses/200/content/application~1json/schema`});
  const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/user-self-profile.json',import.meta.url)));
  assert.equal(result({code:200,message:'success',data:fixture.profile,meta:null}),true);
  assert.deepEqual(spec.paths['/api/v2/users/me'].patch.security,[{bearerAuth:[]},{accessTokenCookie:[]}]);
});

test('public profile contract documents bounded IDs, presence privacy and cookie authentication', () => {
  const op=spec.paths['/api/v2/users/{id}'].get;
  assert.equal(op.parameters[0].schema.minimum,1);assert.equal(op.parameters[0].schema.maximum,9007199254740991);
  assert.deepEqual(op.security,[{bearerAuth:[]},{accessTokenCookie:[]}]);
  const pointer='/api/v2/users/{id}'.replaceAll('/','~1');const check=ajv.compile({$ref:`${base}#/paths/${pointer}/get/responses/200/content/application~1json/schema`});
  const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/user-public-profile.json',import.meta.url)));const profile=structuredClone(fixture.profile);profile.online_status='hidden';profile.last_seen_at=null;
  assert.equal(check({code:200,message:'success',data:profile,meta:null}),true,JSON.stringify(check.errors));assert.equal(check({code:200,message:'success',data:{...profile,email:'secret'},meta:null}),false);
});
