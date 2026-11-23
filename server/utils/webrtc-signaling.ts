import settings from '../../specifications/requirements/webrtc-calls.json';

export type CallMode = 'voice' | 'video';
export interface CallCandidate {
  candidate: string;
  sdp_mid?: string;
  sdp_mline_index?: number;
}
export interface CallPayload {
  call_id: string;
  conversation_id: number;
  client_id: string;
  mode?: CallMode;
  sdp?: string;
  candidates?: CallCandidate[];
}
export interface CallEventData {
  call_id: string;
  conversation_id: number;
  caller_id: number;
  callee_id: number;
  mode: CallMode;
  caller_client_id: string;
  callee_client_id?: string;
  sdp?: string;
  candidates?: CallCandidate[];
  server_id?: string;
}

export const callActions = {
  call_invite: 'invite', call_accept: 'accept', call_reject: 'reject', call_cancel: 'cancel',
  call_sdp_offer: 'offer', call_sdp_answer: 'answer', call_ice: 'ice', call_hangup: 'hangup',
} as const;
export type CallClientEventType = keyof typeof callActions;
export type CallServerEventType = CallClientEventType | 'call_timeout' | 'call_busy' | 'call_unavailable';
export type CallEvent = { type: CallServerEventType; data: CallEventData; timestamp: number };

export const isCallClientEvent = (type: string): type is CallClientEventType => Object.hasOwn(callActions, type);
export const isCallServerEvent = (type: string): type is CallServerEventType =>
  isCallClientEvent(type) || type === 'call_timeout' || type === 'call_busy' || type === 'call_unavailable';
export const isMediaSignal = (type: CallServerEventType) => type === 'call_sdp_offer' || type === 'call_sdp_answer' || type === 'call_ice';

const uuid = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(value);
const id = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
const mode = (value: unknown): value is CallMode => value === 'voice' || value === 'video';
const record = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const byteString = (value: unknown, limit: number): value is string => typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= limit;

function candidate(value: unknown): value is CallCandidate {
  return record(value) && Object.keys(value).every(key => ['candidate','sdp_mid','sdp_mline_index'].includes(key)) &&
    byteString(value.candidate, settings.max_ice_candidate_bytes) &&
    (value.sdp_mid === undefined || typeof value.sdp_mid === 'string' && value.sdp_mid.length <= 128) &&
    (value.sdp_mline_index === undefined || typeof value.sdp_mline_index === 'number' && Number.isInteger(value.sdp_mline_index) &&
      value.sdp_mline_index >= 0 && value.sdp_mline_index <= 65_535);
}

function signalFields(type: CallServerEventType, value: Record<string, unknown>): {sdp?: string; candidates?: CallCandidate[]} | null {
  if (type === 'call_sdp_offer' || type === 'call_sdp_answer') {
    return byteString(value.sdp, settings.max_sdp_bytes) ? {sdp:value.sdp} : null;
  }
  if (type === 'call_ice') {
    const list = value.candidates;
    return Array.isArray(list) && list.length > 0 && list.length <= settings.max_ice_candidates && list.every(candidate)
      ? {candidates:list} : null;
  }
  return {};
}

export function parseCallPayload(type: CallClientEventType, data: unknown): CallPayload | null {
  if (!record(data) || !uuid(data.call_id) || !id(data.conversation_id) || !uuid(data.client_id)) return null;
  const signal = signalFields(type, data);
  if (!signal) return null;
  const base = {call_id:data.call_id,conversation_id:data.conversation_id,client_id:data.client_id,...signal};
  if (type === 'call_invite') {
    return mode(data.mode) && Object.keys(data).length === 4 ? {...base,mode:data.mode} : null;
  }
  return Object.keys(data).length === Object.keys(base).length ? base : null;
}

export function parseCallEvent(type: CallServerEventType, data: unknown): CallEventData | null {
  if (!record(data) || !uuid(data.call_id) || !id(data.conversation_id) || !id(data.caller_id) || !id(data.callee_id) ||
      data.caller_id === data.callee_id || !mode(data.mode) || !uuid(data.caller_client_id) ||
      data.callee_client_id !== undefined && !uuid(data.callee_client_id) ||
      data.server_id !== undefined && !byteString(data.server_id, 256)) return null;
  if ((isMediaSignal(type) || type === 'call_accept' || type === 'call_hangup') && !data.callee_client_id) return null;
  const signal = signalFields(type, data);
  if (!signal) return null;
  const parsed = {
    call_id:data.call_id,conversation_id:data.conversation_id,caller_id:data.caller_id,callee_id:data.callee_id,mode:data.mode,
    caller_client_id:data.caller_client_id,...(data.callee_client_id ? {callee_client_id:data.callee_client_id} : {}),
    ...(data.server_id ? {server_id:data.server_id} : {}),...signal,
  };
  return Object.keys(data).length === Object.keys(parsed).length ? parsed : null;
}
