import { v2RequestData } from './client';

export type CallMode = 'voice' | 'video';

export async function v2GetCallIceServers(): Promise<RTCIceServer[]> {
  const data = await v2RequestData<{ice_servers: RTCIceServer[]; expires_at: string | null}>('/api/v2/calls/ice-servers');
  if (!Array.isArray(data?.ice_servers) || !data.ice_servers.every(server =>
    Array.isArray(server?.urls) && server.urls.length > 0 && server.urls.every(url => typeof url === 'string' && url.length > 0))) {
    throw new Error('Invalid ICE server configuration');
  }
  return data.ice_servers;
}
