import { readFileSync, writeFileSync } from 'node:fs';

// Public synthetic vectors, derived only from versioned local fixtures.
const base=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-inference-transport.json',import.meta.url)));
const calls=[{id:'call-a',name:'lookup',arguments:{query:'cats'}},{id:'call-b',name:'lookup',arguments:{query:'dogs'}}];
const messages=[{role:'user',content:'Find posts'},{role:'assistant',content:'',toolCalls:calls},{role:'tool',content:'cat result',toolCallId:'call-a'},{role:'tool',content:'dog result',toolCallId:'call-b'}];
const tools=[{name:'lookup',description:'Find public posts',parameters:{type:'object',properties:{query:{type:'string'}}}}];
const make=(adapter,id,request,extra={})=>{const old=base.cases.find(x=>x.selection.adapter===adapter&&!x.selection.apiKeyEnv);return {...structuredClone(old),id,request,...extra};};
const encode=(adapter,list)=>list.map(m=>m.role==='assistant'&&m.toolCalls ? {role:'assistant',content:m.content,tool_calls:m.toolCalls.map((c,index)=>adapter==='ollama'?{type:'function',function:{index,name:c.name,arguments:c.arguments}}:{id:c.id,type:'function',function:{name:c.name,arguments:JSON.stringify(c.arguments)}})} : m.role==='tool' ? (adapter==='ollama'?{role:'tool',tool_name:calls.find(c=>c.id===m.toolCallId).name,content:m.content}:{role:'tool',tool_call_id:m.toolCallId,content:m.content}) : m);
const positive=adapter=>{const request={messages:structuredClone(messages),tools:structuredClone(tools)};const item=make(adapter,`TOOL-HISTORY-${adapter==='ollama'?'O':'C'}01`,request);item.expectedBody.messages=encode(adapter,request.messages);item.expectedBody.tools=request.tools.map(t=>({type:'function',function:t}));return item;};
const invalid=(id,list,extra={})=>make('openai-compatible',id,{messages:list,...extra},{expectedError:'INVALID_REQUEST',noNetwork:true,expectedBody:undefined});
const cases=[positive('ollama'),positive('openai-compatible')];
const historical=positive('openai-compatible');historical.id='TOOL-HISTORY-C02';historical.request={messages:structuredClone(messages)};delete historical.expectedBody.tools;cases.push(historical);
const noTools=positive('ollama');noTools.id='TOOL-HISTORY-O02';noTools.selection.capabilities=['structured-output'];noTools.expectedError='UNSUPPORTED_CAPABILITY';noTools.noNetwork=true;delete noTools.expectedBody;cases.push(noTools);
for(const adapter of ['ollama','openai-compatible']) {
  const multi=positive(adapter);multi.id=`TOOL-HISTORY-${adapter==='ollama'?'O':'C'}03`;
  multi.request.messages=[...structuredClone(messages),{role:'assistant',content:'first complete'},{role:'user',content:'again'},...structuredClone(messages.slice(1))];
  multi.expectedBody.messages=encode(adapter,multi.request.messages);cases.push(multi);
  const structured=structuredClone(base.cases.find(x=>x.id===`TRANSPORT-${adapter==='ollama'?'O':'C'}04`));
  structured.id=`TOOL-HISTORY-${adapter==='ollama'?'O':'C'}04`;structured.request.messages=structuredClone(messages);structured.expectedBody.messages=encode(adapter,structured.request.messages);cases.push(structured);
}
cases.push(invalid('TOOL-HISTORY-X01',[{role:'tool',content:'orphan',toolCallId:'call-a'}]));
cases.push(invalid('TOOL-HISTORY-X02',[messages[0],messages[1],{role:'tool',content:'bad',toolCallId:'unknown'}]));
cases.push(invalid('TOOL-HISTORY-X03',[messages[0],messages[1],messages[3],messages[2]]));
cases.push(invalid('TOOL-HISTORY-X04',[messages[0],messages[1],messages[2]]));
cases.push(invalid('TOOL-HISTORY-X05',[messages[0],{role:'assistant',content:'',toolCalls:[calls[0],calls[0]]},messages[2],messages[2]]));
cases.push(invalid('TOOL-HISTORY-X06',[messages[0],{role:'assistant',content:'',toolCalls:[{...calls[0],name:'bad-name'}]},messages[2]]));
cases.push(invalid('TOOL-HISTORY-X07',[messages[0],{role:'assistant',content:'',toolCalls:[{...calls[0],arguments:[]}]},messages[2]]));
cases.push(invalid('TOOL-HISTORY-X08',[messages[0],{role:'assistant',content:'',toolCalls:[]}]));
cases.push(invalid('TOOL-HISTORY-X09',[{role:'user',content:'bad',toolCalls:[calls[0]]}]));
cases.push(invalid('TOOL-HISTORY-X10',[messages[0],messages[1],messages[2],messages[2]]));
cases.push(invalid('TOOL-HISTORY-X11',[messages[0],messages[1],messages[2],{role:'user',content:'interrupt'}]));
cases.push(invalid('TOOL-HISTORY-X12',[messages[0],{role:'assistant',content:'',toolCalls:[{...calls[0],id:''}]},messages[2]]));
cases.push(invalid('TOOL-HISTORY-X13',[messages[0],{role:'assistant',content:'',toolCalls:[{...calls[0],extra:true}]},messages[2]]));
cases.push(invalid('TOOL-HISTORY-X14',[messages[0],messages[1],{role:'tool',content:'bad',toolCallId:[]}]));
cases.push(invalid('TOOL-HISTORY-X15',[messages[0],{role:'assistant',content:'',toolCalls:[{...calls[0],id:'x'.repeat(129)}]},messages[2]]));
cases.push(invalid('TOOL-HISTORY-X16',[messages[0],messages[1],messages[2],{role:'system',content:'interrupt'}]));
const result={schemaVersion:1,id:'AI-TOOL-HISTORY',revision:1,scope:'provider-transport-only',cases};
const output=JSON.stringify(result,null,2)+'\n';
const path=new URL('../specifications/scenarios/ai-tool-history.json',import.meta.url);
if(process.argv.includes('--check')){if(readFileSync(path,'utf8').replaceAll('\r\n','\n')!==output)process.exitCode=1;}else writeFileSync(path,output);
