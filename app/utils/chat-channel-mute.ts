export function confirmedChannelMute(channelId: number, value: unknown): boolean {
  if (value && typeof value === 'object' && 'channel_id' in value && value.channel_id === channelId &&
      'is_muted' in value && typeof value.is_muted === 'boolean') return value.is_muted;
  throw new Error('INVALID_CHAT_MUTE_RECEIPT');
}
