import { createHmac } from 'node:crypto';
import { setResponseHeader, type H3Event } from 'h3';
import settings from '../../../specifications/requirements/webrtc-calls.json';
import { v2Auth, v2Ok, v2Throw } from '~/server/utils/v2';

function configuredUrls(raw: string | undefined, kind: 'stun' | 'turn') {
  const urls = [...new Set((raw ?? '').split(',').map(item => item.trim()).filter(Boolean))];
  const scheme = kind === 'stun' ? /^stuns?:([^?]+)$/ : /^turns?:([^?]+)(?:\?transport=(?:udp|tcp))?$/;
  const host = /^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?|\[[0-9A-Fa-f:.]+\])(?::(\d+))?$/;
  const valid = (url: string) => {
    const authority = scheme.exec(url)?.[1];
    const parts = authority && host.exec(authority);
    if (!parts || parts[1] && (Number(parts[1]) < 1 || Number(parts[1]) > 65_535)) return false;
    try { return !!new URL(`http://${authority}`).hostname; }
    catch { return false; }
  };
  if (urls.length > 8 || !urls.every(valid)) v2Throw(503, '通话配置暂不可用');
  return urls;
}

export function callIceConfiguration(userId: number, env: NodeJS.ProcessEnv = process.env, now = Date.now()) {
  const stun = configuredUrls(env[settings.environment.stun_urls], 'stun');
  const turn = configuredUrls(env[settings.environment.turn_urls], 'turn');
  const secret = env[settings.environment.turn_shared_secret];
  const iceServers: { urls: string[]; username?: string; credential?: string }[] = stun.length ? [{urls:stun}] : [];
  if (!turn.length) return {ice_servers:iceServers,expires_at:null};
  if (!secret?.trim()) v2Throw(503, '通话配置暂不可用');
  const expires = Math.floor(now / 1000) + settings.turn_ttl_seconds;
  const username = `${expires}:${userId}`;
  const credential = createHmac('sha1', secret).update(username, 'utf8').digest('base64');
  iceServers.push({urls:turn,username,credential});
  return {ice_servers:iceServers,expires_at:new Date(expires * 1000).toISOString().replace('.000Z','Z')};
}

export function v2CallIceServers(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return v2Ok(callIceConfiguration(v2Auth(event).userId));
}
