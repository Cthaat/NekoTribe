import assert from 'node:assert/strict';
import { test } from 'node:test';
import { classifySentimentTexts, decodeSentimentSignal } from '../server/services/ai/sentiment-flow.ts';

test('normalizes the deployed and legacy prediction shapes', () => {
  assert.deepEqual(decodeSentimentSignal({data:{prediction:{label:'clearly_positive',confidence:0.72}}}),
    {label:'positive',confidence:0.72});
  assert.deepEqual(decodeSentimentSignal({score:2,confidence:0.6}),{label:'negative',confidence:0.6});
  assert.equal(decodeSentimentSignal({prediction:{label:'neutral',confidence:8}}),null);
  assert.equal(decodeSentimentSignal({label:'unknown',score:2,confidence:0.6}),null);
});

test('disabled configuration does not make requests and repeated upstream failure opens the circuit', async t => {
  const url = 'http://sentiment.fixture.test/predict/';
  const config = {AI_SENTIMENTFLOW_ENABLED:'0',AI_SENTIMENTFLOW_URL:url};
  const previous = Object.fromEntries(Object.keys(config).map(key=>[key,process.env[key]]));
  Object.assign(process.env,config);
  t.after(()=>{
    for (const [key,value] of Object.entries(previous)) {
      if (value===undefined) delete process.env[key]; else process.env[key]=value;
    }
  });
  let calls = 0;
  t.mock.method(globalThis,'fetch',async (endpoint,options)=>{
    calls++;
    assert.equal(endpoint.href,url);
    assert.equal(options.redirect,'error');
    assert.deepEqual(JSON.parse(options.body),{text:'Test',model:'lstm',return_probabilities:false,include_metadata:false});
    return new Response(null,{status:503});
  });
  assert.equal(await classifySentimentTexts(['Test']),null);
  assert.equal(calls,0);
  process.env.AI_SENTIMENTFLOW_ENABLED = '1';
  for (let attempt=0; attempt<4; attempt++) assert.equal(await classifySentimentTexts(['Test']),null);
  assert.equal(calls,3);
});

test('the entire optional batch uses the independent deadline', async t => {
  const env = {AI_SENTIMENTFLOW_ENABLED:'1',AI_SENTIMENTFLOW_URL:'http://timeout.fixture.test/predict/'};
  const previous = Object.fromEntries(Object.keys(env).map(key=>[key,process.env[key]]));
  Object.assign(process.env,env);
  t.after(()=>{
    for(const [key,value] of Object.entries(previous)) {
      if(value===undefined) delete process.env[key]; else process.env[key]=value;
    }
  });
  t.mock.method(AbortSignal,'timeout',delay=>{
    assert.equal(delay,1200);
    return AbortSignal.abort();
  });
  t.mock.method(globalThis,'fetch',async (_url,{signal})=>{
    signal.throwIfAborted();
    throw new Error('optional request received no deadline');
  });
  assert.equal(await classifySentimentTexts(['Synthetic text','Another excerpt']),null);
});
