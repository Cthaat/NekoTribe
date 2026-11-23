import settings from '../../../specifications/requirements/webrtc-calls.json';
import stateScript from '../../../specifications/requirements/webrtc-call-state.json';
import { getRedisClient, publishMessage, REDIS_CHANNELS } from '~/server/utils/redis';
import { sendWsToUser, WS_SERVER_ID } from '~/server/utils/wsSession';
import {
  callActions, isMediaSignal, parseCallEvent, parseCallPayload,
  type CallClientEventType, type CallEvent, type CallEventData, type CallMode, type CallPayload, type CallServerEventType,
} from '~/server/utils/webrtc-signaling';

type Action = typeof callActions[CallClientEventType] | 'expire' | 'disconnect';
interface StoredCall {
  call_id: string;
  conversation_id: string;
  caller_id: string;
  callee_id: string;
  mode: CallMode;
  caller_client_id: string;
  caller_connection: string;
  callee_client_id?: string;
  callee_connection?: string;
  stage?: string;
}
interface OwnedCall { payload: CallPayload; peer: number }

const callKey = (id: string) => `${settings.redis_key_prefix}call:${id}`;
const userKey = (id: number) => `${settings.redis_key_prefix}user:${id}`;
const script = stateScript.lines.join('\n');

function decodeStoredCall(raw: unknown): StoredCall | null {
  return typeof raw === 'string' && raw ? JSON.parse(raw) as StoredCall : null;
}

function event(type: CallServerEventType, call: StoredCall, payload?: CallPayload): CallEvent | null {
  const data = parseCallEvent(type, {
    call_id:call.call_id,conversation_id:Number(call.conversation_id),caller_id:Number(call.caller_id),callee_id:Number(call.callee_id),
    mode:call.mode,caller_client_id:call.caller_client_id,...(call.callee_client_id ? {callee_client_id:call.callee_client_id} : {}),
    ...(payload?.sdp ? {sdp:payload.sdp} : {}),...(payload?.candidates ? {candidates:payload.candidates} : {}),server_id:WS_SERVER_ID,
  });
  return data && {type,data,timestamp:Date.now()};
}

async function relay(message: CallEvent, recipients: number[]) {
  await Promise.allSettled(recipients.map(user => {
    void sendWsToUser(user,message);
    return publishMessage(REDIS_CHANNELS.USER_MESSAGE + user,message);
  }));
}

export function createWebRtcSocket(options: {
  userId: number;
  sessionId: string;
  findPeer: (conversation: number) => Promise<number | null>;
  isActive: () => boolean;
  reply: (frame: CallEvent) => Promise<void>;
  reject: (id?: string) => Promise<void>;
}) {
  const {userId,sessionId} = options;
  let owned: OwnedCall | null = null;
  let ringTimer: ReturnType<typeof setTimeout> | undefined;

  async function run(action: Action, payload: CallPayload, peer: number) {
    const redis = getRedisClient();
    if (!redis) throw new Error('Call state unavailable');
    const result = await redis.eval(script, 3, callKey(payload.call_id), userKey(userId), userKey(peer),
      action, payload.call_id, payload.conversation_id, userId, peer, payload.client_id, sessionId,
      payload.mode ?? '', Date.now(), settings.ring_ms, settings.active_ms);
    if (!Array.isArray(result) || typeof result[0] !== 'string') throw new Error('Invalid call state result');
    return {status:result[0],call:decodeStoredCall(result[1])};
  }

  function stopOwned(call: OwnedCall) {
    if (owned?.payload.call_id !== call.payload.call_id) return;
    clearTimeout(ringTimer);
    owned = null;
  }

  async function finish(call: OwnedCall, action: 'expire' | 'disconnect') {
    try {
      const state = await run(action, call.payload, call.peer);
      if (!state.call) return;
      const type = state.status === 'timeout' ? 'call_timeout' : state.call.callee_client_id ? 'call_hangup' : 'call_cancel';
      const frame = event(type, state.call);
      if (frame) await relay(frame,[userId,call.peer]);
      stopOwned(call);
    } catch { /* The Redis expiry also releases the call if the connection is gone. */ }
  }

  async function handle(type: CallClientEventType, value: unknown) {
    const payload = parseCallPayload(type,value);
    if (!payload) return options.reject();
    const peer = await options.findPeer(payload.conversation_id).catch(() => null);
    if (!peer || peer === userId || !options.isActive()) return options.reject(payload.call_id);
    const current = {payload,peer};
    let result: Awaited<ReturnType<typeof run>>;
    try {
      result = await run(callActions[type],payload,peer);
    } catch {
      result = {status:'unavailable',call:null};
    }
    if (!options.isActive()) {
      if (result.status === 'ok' && (type === 'call_invite' || type === 'call_accept')) await finish(current,'disconnect');
      return;
    }
    if (type === 'call_invite' && payload.mode && (result.status === 'busy' || result.status === 'unavailable')) {
      const frame = event(result.status === 'busy' ? 'call_busy' : 'call_unavailable', {
        call_id:payload.call_id,conversation_id:String(payload.conversation_id),caller_id:String(userId),callee_id:String(peer),
        mode:payload.mode,caller_client_id:payload.client_id,caller_connection:sessionId,
      });
      if (frame) await options.reply(frame);
      return;
    }
    if (result.status !== 'ok' && result.status !== 'timeout' || !result.call) return options.reject(payload.call_id);
    const eventType = result.status === 'timeout' ? 'call_timeout' : type;
    if (result.status === 'ok' && (type === 'call_invite' || type === 'call_accept')) {
      clearTimeout(ringTimer);
      owned = current;
      if (type === 'call_invite') ringTimer = setTimeout(() => { void finish(current, 'expire'); }, settings.ring_ms);
      ringTimer?.unref();
    } else if (result.status === 'timeout' || ['call_reject','call_cancel','call_hangup'].includes(type)) {
      stopOwned(current);
    }
    const frame = event(eventType,result.call,eventType === type ? payload : undefined);
    if (frame) await relay(frame,isMediaSignal(eventType) ? [peer] : [userId,peer]);
  }

  async function authorize(type: CallServerEventType, data: CallEventData): Promise<boolean> {
    const caller = data.caller_id === userId;
    if (!caller && data.callee_id !== userId) return false;
    const peer = caller ? data.callee_id : data.caller_id;
    if (await options.findPeer(data.conversation_id) !== peer) return false;
    if (!isMediaSignal(type) && type !== 'call_invite' && type !== 'call_accept') return true;
    const redis = getRedisClient();
    const call = redis && decodeStoredCall(await redis.get(callKey(data.call_id)));
    const exact = !!call && Number(call.conversation_id) === data.conversation_id && Number(call.caller_id) === data.caller_id &&
      Number(call.callee_id) === data.callee_id && call.caller_client_id === data.caller_client_id &&
      call.callee_client_id === data.callee_client_id;
    if (!exact || !call) return false;
    if (type === 'call_invite') return call.stage === 'ringing';
    if (call.stage === 'ringing' || !call.callee_client_id) return false;
    if (type === 'call_accept') return true;
    if (type === 'call_sdp_offer' && caller || type === 'call_sdp_answer' && !caller) return false;
    return (caller ? call.caller_connection : call.callee_connection) === sessionId;
  }

  async function close() {
    const current = owned;
    clearTimeout(ringTimer);
    owned = null;
    if (current) await finish(current,'disconnect');
  }

  return {handle,authorize,close};
}
