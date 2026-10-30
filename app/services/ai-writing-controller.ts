export interface WritingConversation { conversation_id: string; purpose: string; title: string | null; updated_at: string }
export interface KnowledgeCitation { kind: 'post' | 'comment'; id: number; version: string }
export interface WritingMessage { message_id: string; sequence_no: number; role: string; content: string; citations?: KnowledgeCitation[] }
export interface WritingPage { items: WritingConversation[]; next_cursor: string | null }
export interface WritingApi {
  create(): Promise<{ conversation_id: string }>;
  append(id: string, content: string): Promise<unknown>;
  generate(id: string, searchPhrase?: string): Promise<unknown>;
  messages(id: string, after: number): Promise<WritingMessage[]>;
  list(after: string | null): Promise<WritingPage>;
  remove(id: string): Promise<unknown>;
}
export type WritingError = 'generation' | 'append-unknown' | 'history' | 'delete-unknown' | 'too-long' | 'search-invalid';
export interface WritingState {
  id: string | null; draft: string; searchPhrase: string; messages: WritingMessage[]; history: WritingConversation[];
  historyCursor: string | null; historyLoaded: boolean; historyBusy: boolean;
  busy: boolean; refreshRequired: boolean; error: WritingError | null; insufficientEvidence: boolean;
}
export function initialWritingState(): WritingState {
  return {id:null,draft:'',searchPhrase:'',messages:[],history:[],historyCursor:null,historyLoaded:false,historyBusy:false,busy:false,refreshRequired:false,error:null,insufficientEvidence:false};
}
export function createWritingController(api: WritingApi, state: WritingState, purpose: 'writing' | 'knowledge' = 'writing') {
  function validatedPhrase(): string | undefined {
    if (purpose !== 'knowledge') return undefined;
    const raw=state.searchPhrase, phrase=raw.trim();
    if (!raw.isWellFormed() || !phrase || /[\u0000-\u001f\u007f]/.test(phrase) || new TextEncoder().encode(phrase).length>256) { state.error='search-invalid'; return undefined; }
    return phrase;
  }
  async function generateReply(id: string, phrase?: string) {
    const result = await api.generate(id, phrase);
    if (purpose === 'knowledge') {
      if (!result || typeof result !== 'object' || !('status' in result) || !['generated', 'insufficient_evidence'].includes(String(result.status))) throw Error('invalid generation result');
      state.insufficientEvidence = result.status === 'insufficient_evidence';
    }
  }
  async function readAll(id: string): Promise<WritingMessage[]> {
    const result: WritingMessage[]=[];
    let after=0;
    for (;;) {
      const page=await api.messages(id,after);
      if (!Array.isArray(page) || page.length>50) throw Error('invalid history');
      for (const message of page) {
        if (!Number.isSafeInteger(message.sequence_no) || message.sequence_no<=after || typeof message.content!=='string' || !['user','assistant'].includes(message.role)) throw Error('invalid message');
        after=message.sequence_no; result.push(message);
      }
      if (page.length<50) return result;
    }
  }
  async function refresh() {
    if (!state.id) return;
    state.messages=await readAll(state.id); state.refreshRequired=false;
  }
  async function send() {
    const content=state.draft.trim();
    if (state.busy || state.refreshRequired || !content) return;
    if (new TextEncoder().encode(content).length>65536) {state.error='too-long';return}
    const phrase=validatedPhrase();if (purpose==='knowledge' && phrase===undefined) return;
    state.busy=true;state.error=null;state.insufficientEvidence=false;
    try {
      const id=state.id ?? (await api.create()).conversation_id;
      if (!id) throw Error('invalid conversation');
      state.id=id;
      try {await api.append(id,content)} catch {state.refreshRequired=true;state.error='append-unknown';return}
      state.draft='';await refresh();await generateReply(id,phrase);await refresh();
    } catch {state.refreshRequired=state.id!==null;state.error='generation'}
    finally {state.busy=false}
  }
  async function retry(generate=true) {
    if (state.busy || !state.id) return;
    const phrase=generate ? validatedPhrase() : undefined;
    if (generate && purpose==='knowledge' && phrase===undefined) return;
    state.busy=true;state.error=null;state.insufficientEvidence=false;
    try {await refresh();if(generate && state.messages.at(-1)?.role==='user'){await generateReply(state.id,phrase);await refresh()}}
    catch {state.refreshRequired=true;state.error='generation'}
    finally {state.busy=false}
  }
  async function loadHistory(reset=true) {
    if (state.historyBusy) return;
    state.historyBusy=true;state.error=null;
    try {
      const cursor=reset?null:state.historyCursor;
      const page=await api.list(cursor);
      if (!Array.isArray(page.items) || (page.next_cursor!==null && (typeof page.next_cursor!=='string' || (cursor!==null && page.next_cursor<=cursor)))) throw Error('invalid cursor');
      const items=page.items.filter(item=>item.purpose===purpose);
      state.history=reset?items:[...state.history,...items];state.historyCursor=page.next_cursor;state.historyLoaded=true;
    } catch {state.error='history'}
    finally {state.historyBusy=false}
  }
  async function select(id:string) {
    if(state.busy)return;
    state.busy=true;state.error=null;
    try {const messages=await readAll(id);state.id=id;state.messages=messages;state.draft='';state.searchPhrase='';state.refreshRequired=false;state.insufficientEvidence=false}
    catch {state.error='history'}
    finally {state.busy=false}
  }
  async function remove() {
    if(state.busy||!state.id)return;
    state.busy=true;state.error=null;
    try {await api.remove(state.id);state.id=null;state.messages=[];state.draft='';state.searchPhrase='';state.refreshRequired=false;state.historyLoaded=false;state.insufficientEvidence=false}
    catch {state.error='delete-unknown';state.refreshRequired=true}
    finally {state.busy=false}
  }
  function reset() {if(!state.busy){state.id=null;state.messages=[];state.draft='';state.searchPhrase='';state.error=null;state.refreshRequired=false;state.insufficientEvidence=false}}
  return {send,retry,loadHistory,select,remove,reset};
}
