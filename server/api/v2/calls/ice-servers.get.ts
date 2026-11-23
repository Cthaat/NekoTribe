import { defineEventHandler } from 'h3';
import { v2CallIceServers } from '~/server/services/v2/webrtc-calls';

export default defineEventHandler(v2CallIceServers);
