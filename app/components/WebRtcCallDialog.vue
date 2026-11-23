<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch, watchEffect } from 'vue';
import { Phone, PhoneOff } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useWebRtcCalls } from '@/composables/useWebRtcCalls';

const { t } = useAppLocale();
const { call, localStream, remoteStream, problem, attach, accept, end } = useWebRtcCalls();
const localVideo = ref<HTMLVideoElement | null>(null);
const remoteMedia = ref<HTMLMediaElement | null>(null);
const needsPlayback = ref(false);
let release: (() => void) | undefined;

onMounted(() => { release = attach(); });
onBeforeUnmount(() => { end(); release?.(); });
watch(problem, value => {
  if (!value) return;
  toast.error(t(`chat.calls.problem.${value}`));
  problem.value = null;
});

function playRemote() {
  const media = remoteMedia.value;
  if (!media) return;
  void media.play().then(() => { needsPlayback.value = false; }).catch(() => {
    if (remoteMedia.value === media) needsPlayback.value = true;
  });
}

watchEffect(() => { if (localVideo.value) localVideo.value.srcObject = localStream.value; });
watchEffect(() => {
  if (!remoteMedia.value) return;
  const stream = remoteStream.value;
  remoteMedia.value.srcObject = stream;
  needsPlayback.value = false;
  if (stream) playRemote();
});
</script>

<template>
  <Dialog :open="call !== null" @update:open="open => { if (!open) end() }">
    <DialogContent v-if="call" class="sm:max-w-xl">
      <DialogHeader>
        <DialogTitle class="pr-8">{{ t(call.mode === 'voice' ? 'chat.calls.voiceTitle' : 'chat.calls.videoTitle') }}</DialogTitle>
        <DialogDescription>
          {{ call.name || t('chat.calls.account', { id: call.peerId }) }} · {{ t(`chat.calls.phase.${call.phase}`) }}
        </DialogDescription>
      </DialogHeader>
      <div v-if="call.mode === 'video' && (localStream || remoteStream)" class="relative aspect-video overflow-hidden rounded-lg bg-neutral-950">
        <video ref="remoteMedia" autoplay playsinline class="h-full w-full object-contain" :aria-label="t('chat.calls.peerVideo')" />
        <video v-if="localStream" ref="localVideo" autoplay muted playsinline
          class="absolute bottom-2 right-2 w-1/4 rounded border border-white/20 object-cover" :aria-label="t('chat.calls.localVideo')" />
      </div>
      <audio v-else-if="call.mode === 'voice'" ref="remoteMedia" autoplay />
      <Button v-if="needsPlayback" type="button" variant="outline" @click="playRemote">{{ t('chat.calls.playAudio') }}</Button>
      <DialogFooter>
        <template v-if="call.phase === 'incoming'">
          <Button type="button" variant="outline" @click="end()"><PhoneOff class="h-4 w-4" />{{ t('chat.calls.reject') }}</Button>
          <Button type="button" @click="accept"><Phone class="h-4 w-4" />{{ t('chat.calls.accept') }}</Button>
        </template>
        <Button v-else type="button" variant="destructive" @click="end()">
          <PhoneOff class="h-4 w-4" />
          {{ t(call.phase === 'active' || call.phase === 'connecting' ? 'chat.calls.hangup' : 'common.cancel') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
