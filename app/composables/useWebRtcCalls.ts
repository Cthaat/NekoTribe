import { readonly, ref, shallowRef, watch } from 'vue';
import { useNuxtApp } from '#app';
import { v2GetUserById } from '@/api/v2/users';
import { v2GetCallIceServers, type CallMode } from '@/api/v2/webrtc';
import { usePreferenceStore } from '@/stores/user';
import { useRealtimeSocket, type RealtimeMessage } from './useRealtimeSocket';
import policy from '../../specifications/requirements/webrtc-calls.json';

type Problem = 'insecure' | 'unsupported' | 'unavailable' | 'permission' | 'devices' | 'busy' | 'timeout' | 'failed' | 'declined';
interface ActiveCall {
  id: string;
  conversationId: number;
  peerId: number;
  name: string;
  mode: CallMode;
  role: 'caller' | 'callee';
  phase: 'preparing' | 'incoming' | 'outgoing' | 'connecting' | 'active';
}
type WireCandidate = {candidate: string; sdp_mid?: string; sdp_mline_index?: number};

function rtcSupport(): Problem | null {
  if (!globalThis.isSecureContext) return 'insecure';
  return typeof RTCPeerConnection === 'undefined' || !navigator.mediaDevices?.getUserMedia ? 'unsupported' : null;
}

function randomId(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const hex = [...crypto.getRandomValues(new Uint8Array(16))].map(byte => byte.toString(16).padStart(2,'0')).join('');
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}

function createCalls(app: ReturnType<typeof useNuxtApp>) {
  const realtime = useRealtimeSocket();
  const preferences = usePreferenceStore();
  const call = shallowRef<ActiveCall | null>(null);
  const localStream = shallowRef<MediaStream | null>(null);
  const remoteStream = shallowRef<MediaStream | null>(null);
  const problem = ref<Problem | null>(null);
  let clientId: string | undefined;
  let connection: RTCPeerConnection | null = null;
  let iceServers: RTCIceServer[] = [];
  let expiry: ReturnType<typeof setTimeout> | undefined;
  let sendIceTimer: ReturnType<typeof setTimeout> | undefined;
  let remoteCandidates: RTCIceCandidateInit[] = [];
  let sendCandidates: WireCandidate[] = [];
  let unsubscribe: (() => void) | undefined;
  let stopOwnerWatch: (() => void) | undefined;
  let stopConnectionWatch: (() => void) | undefined;
  let frameChain = Promise.resolve();
  const localAccount = () => preferences.preferences.user.id;
  const device = () => clientId ??= randomId();

  function signal(type: string, current: ActiveCall, extra: Record<string, unknown> = {}) {
    return realtime.send({type,data:{call_id:current.id,conversation_id:current.conversationId,client_id:device(),...extra}});
  }

  function clear(nextProblem: Problem | null = null) {
    clearTimeout(expiry);
    clearTimeout(sendIceTimer);
    expiry = sendIceTimer = undefined;
    call.value = null;
    const pc = connection;
    connection = null;
    pc?.close();
    for (const track of localStream.value?.getTracks() ?? []) track.stop();
    localStream.value = remoteStream.value = null;
    sendCandidates = [];
    remoteCandidates = [];
    iceServers = [];
    problem.value = nextProblem;
  }

  function end(nextProblem: Problem | null = null) {
    const current = call.value;
    if (!current) { clear(nextProblem); return; }
    if (current.phase === 'connecting' || current.phase === 'active') signal('call_hangup',current);
    else if (current.role === 'callee') signal('call_reject',current);
    else if (current.phase === 'outgoing') signal('call_cancel',current);
    clear(nextProblem);
  }

  function timeout(id: string, duration: number) {
    clearTimeout(expiry);
    expiry = setTimeout(() => { if (call.value?.id === id) end('timeout'); }, duration);
  }

  async function prepare(current: ActiveCall): Promise<boolean> {
    const support = rtcSupport();
    if (support) { end(support); return false; }
    let configuration: RTCIceServer[];
    try { configuration = await app.runWithContext(v2GetCallIceServers); }
    catch { if (call.value?.id === current.id) end('unavailable'); return false; }
    if (call.value?.id !== current.id) return false;
    iceServers = configuration;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({audio:true,video:current.mode === 'video'});
      if (call.value?.id !== current.id) {
        stream.getTracks().forEach(track => track.stop());
        return false;
      }
      localStream.value = stream;
      return true;
    } catch (error) {
      if (call.value?.id === current.id) end(error instanceof DOMException && error.name === 'NotAllowedError' ? 'permission' : 'devices');
      return false;
    }
  }

  async function start(conversationId: number, peerId: number, name: string, mode: CallMode) {
    if (call.value) { problem.value = 'busy'; return; }
    const support = rtcSupport();
    if (support) { problem.value = support; return; }
    if (!realtime.serverReady.value || !localAccount()) { problem.value = 'unavailable'; return; }
    const current: ActiveCall = {id:randomId(),conversationId,peerId,name,mode,role:'caller',phase:'preparing'};
    call.value = current;
    problem.value = null;
    if (!await prepare(current) || call.value?.id !== current.id) return;
    if (!signal('call_invite',current,{mode})) { clear('unavailable'); return; }
    call.value = {...current,phase:'outgoing'};
    timeout(current.id,policy.ring_ms);
  }

  async function accept() {
    const current = call.value;
    if (!current || current.phase !== 'incoming') return;
    call.value = {...current,phase:'preparing'};
    if (!await prepare(current) || call.value?.id !== current.id) return;
    if (!signal('call_accept',current)) { end('unavailable'); return; }
    call.value = {...call.value,phase:'connecting'};
    timeout(current.id,policy.ring_ms);
  }

  function queueLocalIce(current: ActiveCall, ice: RTCIceCandidate) {
    sendCandidates.push({candidate:ice.candidate,...(ice.sdpMid !== null ? {sdp_mid:ice.sdpMid} : {}),
      ...(ice.sdpMLineIndex !== null ? {sdp_mline_index:ice.sdpMLineIndex} : {})});
    if (sendIceTimer) return;
    sendIceTimer = setTimeout(() => {
      sendIceTimer = undefined;
      if (call.value?.id !== current.id) return;
      while (sendCandidates.length) {
        const candidates = sendCandidates.splice(0,policy.max_ice_candidates);
        if (!signal('call_ice',current,{candidates})) { end('unavailable'); break; }
      }
    }, 75);
  }

  async function openPeer(current: ActiveCall) {
    const stream = localStream.value;
    if (!stream || connection) return;
    const pc = new RTCPeerConnection({iceServers});
    connection = pc;
    call.value = {...current,phase:'connecting'};
    timeout(current.id,policy.ring_ms);
    for (const track of stream.getTracks()) pc.addTrack(track,stream);
    pc.ontrack = event => {
      if (connection !== pc) return;
      remoteStream.value = event.streams[0] ?? new MediaStream([event.track]);
    };
    pc.onicecandidate = ({candidate}) => {
      if (candidate?.candidate && connection === pc) queueLocalIce(current,candidate);
    };
    pc.onconnectionstatechange = () => {
      if (connection !== pc || call.value?.id !== current.id) return;
      if (pc.connectionState === 'connected') {
        call.value = {...call.value,phase:'active'};
        timeout(current.id,policy.active_ms);
      } else if (pc.connectionState === 'failed' || pc.connectionState === 'closed') end('failed');
    };
    if (current.role === 'caller') {
      await pc.setLocalDescription(await pc.createOffer());
      if (connection === pc && pc.localDescription?.sdp && !signal('call_sdp_offer',current,{sdp:pc.localDescription.sdp})) end('unavailable');
    }
  }

  async function setRemote(current: ActiveCall, sdp: string, type: 'offer' | 'answer') {
    const pc = connection;
    if (!pc) return;
    await pc.setRemoteDescription({type,sdp});
    if (connection !== pc) return;
    const queued = remoteCandidates;
    remoteCandidates = [];
    for (const candidate of queued) await pc.addIceCandidate(candidate);
    if (type === 'offer' && connection === pc) {
      await pc.setLocalDescription(await pc.createAnswer());
      if (connection === pc && pc.localDescription?.sdp && !signal('call_sdp_answer',current,{sdp:pc.localDescription.sdp})) end('unavailable');
    }
  }

  async function handle(frame: RealtimeMessage) {
    const data = frame.data;
    if (!data || typeof data.call_id !== 'string') return;
    const current = call.value;
    if (frame.type === 'call_invite' && !current && data.callee_id === localAccount() &&
        typeof data.conversation_id === 'number' && typeof data.caller_id === 'number' &&
        (data.mode === 'voice' || data.mode === 'video') && typeof frame.timestamp === 'number') {
      const remaining = policy.ring_ms - Math.max(0,Date.now() - frame.timestamp);
      if (remaining <= 0) return;
      const incoming: ActiveCall = {id:data.call_id,conversationId:data.conversation_id,peerId:data.caller_id,name:'',
        mode:data.mode,role:'callee',phase:'incoming'};
      call.value = incoming;
      problem.value = null;
      timeout(incoming.id,remaining);
      void app.runWithContext(() => v2GetUserById(incoming.peerId)).then(user => {
        if (call.value?.id === incoming.id) call.value = {...call.value,name:user.display_name || user.username};
      }).catch(() => undefined);
      return;
    }
    if (!current || data.call_id !== current.id) return;
    if (frame.type === 'error') { end('failed'); return; }
    if (current.conversationId !== data.conversation_id) return;
    if (current.role === 'caller' && data.caller_client_id !== device()) return;
    if (current.role === 'callee' && data.callee_client_id && data.callee_client_id !== device()) { clear(); return; }
    switch (frame.type) {
      case 'call_busy': clear('busy'); break;
      case 'call_unavailable': clear('unavailable'); break;
      case 'call_timeout': clear('timeout'); break;
      case 'call_reject': clear(current.role === 'caller' ? 'declined' : null); break;
      case 'call_cancel':
      case 'call_hangup': clear(); break;
      case 'call_accept': await openPeer(current); break;
      case 'call_sdp_offer':
        if (current.role === 'callee' && typeof data.sdp === 'string') {
          if (!connection) await openPeer(current);
          await setRemote(current,data.sdp,'offer');
        }
        break;
      case 'call_sdp_answer':
        if (current.role === 'caller' && typeof data.sdp === 'string') await setRemote(current,data.sdp,'answer');
        break;
      case 'call_ice': {
        const values: unknown[] = Array.isArray(data.candidates) ? data.candidates : [];
        for (const item of values) {
          if (!item || typeof item !== 'object' || !('candidate' in item) || typeof item.candidate !== 'string') continue;
          const candidate = {candidate:item.candidate,
            sdpMid:'sdp_mid' in item && typeof item.sdp_mid === 'string' ? item.sdp_mid : null,
            sdpMLineIndex:'sdp_mline_index' in item && typeof item.sdp_mline_index === 'number' ? item.sdp_mline_index : null};
          if (connection?.remoteDescription) await connection.addIceCandidate(candidate);
          else remoteCandidates.push(candidate);
        }
        break;
      }
    }
  }

  function attach() {
    if (!unsubscribe) {
      stopOwnerWatch = watch(realtime.ownerRevision, () => { clear(); clientId = undefined; }, {flush:'sync'});
      stopConnectionWatch = watch(realtime.serverReady, ready => { if (!ready && call.value) clear('unavailable'); });
      unsubscribe = realtime.subscribe(frame => {
        if (!frame.type.startsWith('call_') && !(frame.type === 'error' && frame.data?.call_id)) return;
        const owner = realtime.ownerRevision.value;
        frameChain = frameChain.then(() => owner === realtime.ownerRevision.value ? handle(frame) : undefined).catch(() => {
          if (call.value?.id === frame.data?.call_id) end('failed');
        });
      });
    }
    return () => {
      unsubscribe?.();
      stopOwnerWatch?.();
      stopConnectionWatch?.();
      unsubscribe = stopOwnerWatch = stopConnectionWatch = undefined;
      clear();
    };
  }

  return {call:readonly(call),localStream,remoteStream,problem,attach,start,accept,end};
}

const stores = new WeakMap<object,ReturnType<typeof createCalls>>();
export function useWebRtcCalls() {
  const app = useNuxtApp();
  let store = stores.get(app);
  if (!store) { store = createCalls(app); stores.set(app,store); }
  return store;
}
