import { aiQuotaRetry } from './ai-quota-notice';
import { validateAiConversationPage } from '../utils/ai-conversation-page';

export const aiMessageMaxBytes = 65_536;

export function aiMessageContent(draft: string, instruction?: string): string {
  const content = draft.trim();
  return content && instruction ? `${instruction}\n\n${content}` : content;
}

export function aiMessageBytes(content: string): number {
  return new TextEncoder().encode(content).length;
}

export interface WritingConversation { conversation_id: string; purpose: string; title: string | null; updated_at: string }
export interface KnowledgeCitation { kind: 'post' | 'comment' | 'terms' | 'group_post' | 'group_comment'; id: number; version: string; post_id?: number; group_id?: number }
type CitationTarget =
  | {kind:'post';id:number}
  | {kind:'terms';href:string}
  | {kind:'group';groupId:number;postId:number;commentId?:number};
const validCitationId = (id: unknown): id is number =>
  typeof id === 'number' && Number.isSafeInteger(id) && id >= 1 && id <= 999_999_999_999_999;

export function citationTarget(source:KnowledgeCitation):CitationTarget|null {
  if(!source || !Number.isSafeInteger(source.id) || source.id<1 || source.id>999999999999999 || typeof source.version!=='string' || source.version.length!==64 || !/^[0-9a-f]{64}$/.test(source.version)) return null;
  if (source.kind === 'group_post' || source.kind === 'group_comment') {
    if (!validCitationId(source.group_id) || !validCitationId(source.post_id) ||
        (source.kind === 'group_post' && source.post_id !== source.id)) return null;
    return source.kind === 'group_comment'
      ? {kind:'group',groupId:source.group_id,postId:source.post_id,commentId:source.id}
      : {kind:'group',groupId:source.group_id,postId:source.post_id};
  }
  if ('group_id' in source) return null;
  if(source.kind==='terms') {
    if(source.post_id!==undefined || source.id>8) return null;
    const locale=source.id<=4?'zh':'en',section=['acceptance','accounts','conduct','termination'][(source.id-1)%4];
    return {kind:'terms',href:`/${locale}/auth/terms?citation=${source.id}.${source.version}#${section}`};
  }
  if(source.kind!=='post' && source.kind!=='comment') return null;
  const id=source.post_id ?? (source.kind==='post'?source.id:null);
  if(typeof id!=='number' || !Number.isSafeInteger(id) || id<1 || id>999999999999999 || (source.kind==='post' && id!==source.id)) return null;
  return {kind:'post',id};
}
export interface WritingMessage { message_id: string; sequence_no: number; role: string; content: string; citations?: KnowledgeCitation[]; model_version?: string | null; config_revision?: number | null }
function validateMessageReceipt(receipt: unknown, id: string, role: 'user' | 'assistant'): number {
  const value = receipt as Partial<WritingMessage & {conversation_id: string}> | null;
  if (!value || value.conversation_id !== id || value.role !== role ||
      typeof value.message_id !== 'string' || !value.message_id ||
      typeof value.sequence_no !== 'number' || !Number.isSafeInteger(value.sequence_no) ||
      value.sequence_no < 1 || value.sequence_no > 9_999_999_999) throw Error(`invalid ${role} receipt`);
  return value.sequence_no;
}
export function validateUserReceipt(receipt: unknown, id: string): number {
  return validateMessageReceipt(receipt, id, 'user');
}
export function validateAssistantReceipt(receipt: unknown, id: string, expectedUserSequence?: number): void {
  const sequence = validateMessageReceipt(receipt, id, 'assistant');
  if (expectedUserSequence !== undefined && sequence !== expectedUserSequence + 1) throw Error('invalid assistant sequence');
}
export interface WritingPage { items: WritingConversation[]; next_cursor: string | null }
interface AiRoleFlags { knowledge: boolean; writing: boolean; group?: boolean; moderation?: boolean }
export type AiSkillPurpose = keyof AiRoleFlags;
export interface AiSkillSummary { id: string; purpose: AiSkillPurpose; version: number; enabled: boolean; explicitSelection?: boolean }
export interface AiAvailability extends AiRoleFlags { inference?: AiRoleFlags; skills?: AiSkillSummary[]; modelConfigRevision?: number }
export type AiAvailabilityState = 'loading' | 'enabled' | 'disabled' | 'unconfigured' | 'unknown';
export interface WritingApi {
  availability(signal?: AbortSignal): Promise<AiAvailability>;
  create(signal?: AbortSignal, title?: string): Promise<{ conversation_id: string }>;
  read(id: string, signal?: AbortSignal): Promise<WritingConversation>;
  append(id: string, content: string, signal?: AbortSignal): Promise<number>;
  generate(id: string, searchPhrase?: string, signal?: AbortSignal, selectSkill?: boolean, expectedSequence?: number): Promise<unknown>;
  messages(id: string, after: number, signal?: AbortSignal, before?: number): Promise<WritingMessage[]>;
  list(after: string | null, signal?: AbortSignal): Promise<WritingPage>;
  remove(id: string, signal?: AbortSignal): Promise<unknown>;
}
export type WritingError = 'generation' | 'generation-stopped' | 'reply-saved' | 'append-unknown' | 'history' | 'delete-unknown' | 'conversation-missing' | 'sequence-conflict' | 'title-too-long' | 'too-long' | 'search-invalid' | 'quota';
export interface WritingState {
  availability: AiAvailabilityState;
  skill?: AiSkillSummary;
  modelConfigRevision?: number;
  explicitSkill: boolean;
  id: string | null; draft: string; titleDraft: string; searchPhrase: string; messages: WritingMessage[]; history: WritingConversation[];
  hasOlderMessages: boolean;
  historyCursor: string | null; historyLoaded: boolean; historyBusy: boolean;
  busy: boolean; refreshRequired: boolean; savedReplyPending: boolean; error: WritingError | null; insufficientEvidence: boolean;
  generating: boolean;
  quotaRetry: number;
}
export function initialWritingState(): WritingState {
  return {availability:'loading',skill:undefined,modelConfigRevision:undefined,explicitSkill:false,id:null,draft:'',titleDraft:'',searchPhrase:'',messages:[],hasOlderMessages:false,history:[],historyCursor:null,historyLoaded:false,historyBusy:false,busy:false,generating:false,refreshRequired:false,savedReplyPending:false,error:null,insufficientEvidence:false,quotaRetry:0};
}
export function createWritingController(
  api: WritingApi, state: WritingState, purpose: 'writing' | 'knowledge' = 'writing',
  onConversationMissing?: (id: string) => void
) {
  let availabilityRequest = 0;
  let historyRevision = 0;
  let forwardOnly = false;
  const session = new AbortController();
  const { signal } = session;
  let generation: AbortController | undefined;
  async function request<T>(action: () => Promise<T>) {
    signal.throwIfAborted();
    const result = await action();
    signal.throwIfAborted();
    return result;
  }
  function close() {
    session.abort();
    generation?.abort();
    Object.assign(state, initialWritingState());
  }
  function stopGeneration() {
    generation?.abort();
  }
  async function loadAvailability() {
    if (signal.aborted) return;
    const revision = ++availabilityRequest;
    state.availability = 'loading';
    state.skill = undefined;
    state.modelConfigRevision = undefined;
    state.explicitSkill = false;
    try {
      const flags = await request(() => api.availability(signal));
      if (!signal.aborted && revision === availabilityRequest) {
        state.skill = flags.skills?.find(skill => skill.purpose === purpose);
        state.modelConfigRevision = flags.modelConfigRevision;
        if (!flags[purpose]) state.availability = 'disabled';
        else state.availability = flags.inference?.[purpose] === false ? 'unconfigured' : 'enabled';
      }
    } catch {
      if (!signal.aborted && revision === availabilityRequest) state.availability = 'unknown';
    }
  }
  function validatedPhrase(): string | undefined {
    if (purpose !== 'knowledge') return undefined;
    const raw=state.searchPhrase, phrase=raw.trim();
    if (!raw.isWellFormed() || !phrase || /[\u0000-\u001f\u007f]/.test(phrase) || new TextEncoder().encode(phrase).length>256) { state.error='search-invalid'; return undefined; }
    return phrase;
  }
  async function generateReply(id: string, expectedSequence: number, phrase?: string) {
    const current = new AbortController();
    generation = current;
    state.generating = true;
    try {
      const selectSkill = state.explicitSkill &&
        state.skill?.explicitSelection === true && state.skill.enabled;
      const result = await request(() => api.generate(id, phrase, current.signal, selectSkill, expectedSequence));
      current.signal.throwIfAborted();
      if (purpose === 'knowledge') {
        if (!result || typeof result !== 'object' || !('status' in result) || !['generated', 'insufficient_evidence'].includes(String(result.status))) throw Error('invalid generation result');
        state.insufficientEvidence = result.status === 'insufficient_evidence';
      }
      state.savedReplyPending = !state.insufficientEvidence;
    } catch (error) {
      signal.throwIfAborted();
      if (current.signal.aborted) {
        state.refreshRequired = true;
        state.error = 'generation-stopped';
        return;
      }
      const failure = error as {statusCode?: number; status?: number} | null;
      if ((failure?.statusCode ?? failure?.status) === 409) {
        state.refreshRequired = true;
        state.error = 'sequence-conflict';
        return;
      }
      const retry = aiQuotaRetry(error);
      if (retry === null) throw error;
      state.error = 'quota';
      state.quotaRetry = retry;
    } finally {
      generation = undefined;
      if (!signal.aborted) state.generating = false;
    }
  }
  async function readMessagePage(id: string, after: number, before?: number): Promise<WritingMessage[]> {
    const page = await request(() => api.messages(id, after, signal, before));
    if (!Array.isArray(page) || page.length > 50) throw Error('invalid history');
    for (const message of page) {
      if (!Number.isSafeInteger(message.sequence_no) || message.sequence_no <= after ||
          (before !== undefined && message.sequence_no >= before) ||
          typeof message.content !== 'string' || !['user', 'assistant'].includes(message.role)) throw Error('invalid message');
      after = message.sequence_no;
    }
    return page;
  }
  async function readForwardWindow(id: string, result: WritingMessage[] = [], before = 10_000_000_000) {
    let after = result.at(-1)?.sequence_no ?? 0;
    for (;;) {
      const page = await readMessagePage(id, after);
      result = [...result, ...page.filter(message => message.sequence_no < before)].slice(-50);
      const last = page.at(-1)?.sequence_no ?? after;
      if (page.length < 50 || last >= before) return result;
      after = last;
    }
  }
  async function readRecent(id: string): Promise<{messages: WritingMessage[]; forwardOnly: boolean}> {
    const recent = await readMessagePage(id, 0, 10_000_000_000);
    // Older servers ignore before_sequence and may return their first full page.
    const legacy = recent.length === 50 && recent[0]?.sequence_no === 1;
    return {messages: legacy ? await readForwardWindow(id, recent) : recent, forwardOnly: legacy};
  }
  async function readOlder(id: string, before: number) {
    if (!forwardOnly) return readMessagePage(id, 0, before);
    const after = Math.max(0, before - 51);
    const nearby = (await readMessagePage(id, after)).filter(message => message.sequence_no < before);
    // Gaps in older histories can leave part or all of the page outside this range.
    return after === 0 || nearby.length === 50 ? nearby : readForwardWindow(id, [], before);
  }
  function displayMessages(messages: WritingMessage[], fullPage = messages.length === 50) {
    state.messages = messages;
    state.hasOlderMessages = fullPage && (messages[0]?.sequence_no ?? 0) > 1;
  }
  async function loadOlderMessages() {
    const id = state.id;
    const before = state.messages[0]?.sequence_no;
    if (!id || !before || !state.hasOlderMessages || state.busy || state.savedReplyPending || signal.aborted) return;
    state.busy = true;
    state.error = null;
    try {
      const page = await readOlder(id, before);
      displayMessages([...page, ...state.messages], page.length === 50);
    } catch (error) {
      if (!forgetMissing(id, error) && !signal.aborted) state.error = 'history';
    } finally {
      if (!signal.aborted) state.busy = false;
    }
  }
  async function refresh() {
    if (!state.id) return;
    const recent = await readRecent(state.id);
    signal.throwIfAborted();
    forwardOnly = recent.forwardOnly;
    displayMessages(recent.messages); state.refreshRequired=false;
    state.savedReplyPending = false;
  }
  function matchesLatestUser(sequence: number): boolean {
    const latest = state.messages.at(-1);
    return latest?.role === 'user' && latest.sequence_no === sequence;
  }
  function forgetMissing(id: string | null, error: unknown, submitted?: string): boolean {
    const failure = error as {statusCode?: number; status?: number} | null;
    if (signal.aborted || !id || (failure?.statusCode ?? failure?.status) !== 404) return false;
    historyRevision++;
    state.history = state.history.filter(item => item.conversation_id !== id);
    if (state.id === id) {
      state.id = null;
      displayMessages([]);
      state.refreshRequired = false;
      state.savedReplyPending = false;
      state.insufficientEvidence = false;
      if (!state.draft && submitted) state.draft = submitted;
    }
    state.error = 'conversation-missing';
    onConversationMissing?.(id);
    return true;
  }
  async function send(instruction?: string, onConversationCreated?: (id: string) => void) {
    const draft=state.draft.trim();
    if (signal.aborted || state.busy || state.refreshRequired || state.availability !== 'enabled' || !draft) return;
    const title = state.id === null ? state.titleDraft.trim() : '';
    if (title.length > 200) {state.error='title-too-long';return}
    const content = aiMessageContent(draft, purpose === 'writing' ? instruction : undefined);
    if (aiMessageBytes(content) > aiMessageMaxBytes) {state.error='too-long';return}
    const phrase=validatedPhrase();if (purpose==='knowledge' && phrase===undefined) return;
    state.busy=true;state.error=null;state.insufficientEvidence=false;
    try {
      const existing = state.id;
      const id=existing ?? (await request(() => api.create(signal, title || undefined))).conversation_id;
      signal.throwIfAborted();
      if (!id) throw Error('invalid conversation');
      state.id=id;
      state.titleDraft='';
      if (existing === null) onConversationCreated?.(id);
      let sequence: number;
      try {
        sequence = await request(() => api.append(id,content,signal));
      } catch (error) {
        if (!forgetMissing(id, error) && !signal.aborted) {
          state.refreshRequired = true;
          state.error = 'append-unknown';
        }
        return;
      }
      signal.throwIfAborted();
      state.draft='';
      await refresh();
      if (!matchesLatestUser(sequence)) {
        state.error = 'sequence-conflict';
        return;
      }
      await generateReply(id,sequence,phrase);
      if (state.savedReplyPending) await refresh();
    } catch (error) {
      if (!forgetMissing(state.id, error, draft) && !signal.aborted) {
        state.refreshRequired = state.id !== null;
        state.error = state.savedReplyPending ? 'reply-saved' : 'generation';
      }
    }
    finally {if (!signal.aborted) state.busy=false}
  }
  async function retry(generate=true) {
    if (signal.aborted || state.busy || !state.id ||
        (generate && (state.availability !== 'enabled' || state.savedReplyPending))) return;
    const id = state.id;
    const last = state.messages.at(-1);
    const expected = last?.role === 'user' ? last.sequence_no : undefined;
    const phrase=generate ? validatedPhrase() : undefined;
    if (generate && purpose==='knowledge' && phrase===undefined) return;
    state.busy=true;state.error=null;state.insufficientEvidence=false;
    if (!generate && purpose === 'knowledge') displayMessages([]);
    try {
      await refresh();
      if (generate && expected !== undefined) {
        if (!matchesLatestUser(expected)) {
          state.error = 'sequence-conflict';
          return;
        }
        await generateReply(id,expected,phrase);
        if (state.savedReplyPending) await refresh();
      }
    }
    catch (error) {
      if (!forgetMissing(id, error) && !signal.aborted) {
        state.refreshRequired = true;
        state.error = state.savedReplyPending ? 'reply-saved' : !generate && purpose === 'knowledge' ? 'history' : 'generation';
      }
    }
    finally {if (!signal.aborted) state.busy=false}
  }
  async function loadHistory(reset=true) {
    if (signal.aborted || state.historyBusy) return;
    state.historyBusy=true;state.error=null;
    const revision = historyRevision;
    try {
      const cursor=reset?null:state.historyCursor;
      const page=await request(() => api.list(cursor,signal));
      signal.throwIfAborted();
      if (revision !== historyRevision) return;
      if (!Array.isArray(page.items) || page.items.length > 50) throw Error('invalid history page');
      const next = validateAiConversationPage(page.items.map(item => item?.conversation_id), cursor, page.next_cursor);
      const items=page.items.filter(item=>item.purpose===purpose);
      state.history=reset?items:[...state.history,...items];state.historyCursor=next;state.historyLoaded=true;
    } catch {if (!signal.aborted && revision === historyRevision) state.error='history'}
    finally {if (!signal.aborted) state.historyBusy=false}
  }
  async function select(id:string, current: () => boolean = () => true) {
    if(signal.aborted || state.busy)return;
    const alreadyOpen = state.id === id;
    state.busy=true;state.error=null;
    if (alreadyOpen && purpose === 'knowledge') displayMessages([]);
    try {
      const record = await request(() => api.read(id, signal));
      if (!current()) return;
      if (record.conversation_id !== id || record.purpose !== purpose) {
        if (alreadyOpen) state.refreshRequired = true;
        state.error = 'conversation-missing';
        return;
      }
      const recent=await readRecent(id);signal.throwIfAborted();
      if (!current()) return;
      forwardOnly = recent.forwardOnly;
      if (!alreadyOpen) {
        state.draft = '';
        state.titleDraft = '';
        state.searchPhrase = '';
      }
      state.id=id;displayMessages(recent.messages);state.refreshRequired=false;state.savedReplyPending=false;state.insufficientEvidence=false;
    }
    catch (error) {
      if (current() && !forgetMissing(id, error) && !signal.aborted) {
        if (alreadyOpen) state.refreshRequired = true;
        state.error = 'history';
      }
    }
    finally {if (!signal.aborted) state.busy=false}
  }
  async function remove() {
    if(signal.aborted || state.busy||!state.id)return;
    const id = state.id;
    state.busy=true;state.error=null;
    try {await request(() => api.remove(id,signal));signal.throwIfAborted();state.id=null;displayMessages([]);state.draft='';state.searchPhrase='';state.refreshRequired=false;state.savedReplyPending=false;state.historyLoaded=false;state.insufficientEvidence=false}
    catch (error) {
      if (!forgetMissing(id, error) && !signal.aborted) {
        state.error = 'delete-unknown';
        state.refreshRequired = true;
      }
    }
    finally {if (!signal.aborted) state.busy=false}
  }
  function reset() {if(!state.busy){state.id=null;displayMessages([]);state.draft='';state.titleDraft='';state.searchPhrase='';state.error=null;state.refreshRequired=false;state.savedReplyPending=false;state.insufficientEvidence=false}}
  return {send,retry,loadHistory,loadOlderMessages,loadAvailability,select,remove,reset,stopGeneration,close};
}
