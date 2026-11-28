<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch, watchEffect } from 'vue';
import { Maximize2, Minimize2, Phone, PhoneOff } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useWebRtcCalls } from '@/composables/useWebRtcCalls';

const { t } = useAppLocale();
const { call, localStream, remoteStream, problem, attach, accept, end } = useWebRtcCalls();
const localVideo = ref<HTMLVideoElement | null>(null);
const minimized = ref(false);
const restoreButton = ref<HTMLButtonElement>();
const fullVideo = ref<HTMLVideoElement>();
const pipVideo = ref<HTMLVideoElement>();
const remoteMedia = ref<HTMLMediaElement | null>(null);
const needsPlayback = ref(false);
watch(() => call.value?.id, () => { minimized.value = false; });
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

watchEffect(() => {
  for (const video of [fullVideo.value, pipVideo.value]) {
    if (video) video.srcObject = remoteStream.value;
  }
});
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
  <audio v-if="call" ref="remoteMedia" autoplay />
  <Dialog :open="call !== null && !minimized" @update:open="open => { if (!open) end() }">
    <DialogContent v-if="call" class="sm:max-w-xl"
      @close-auto-focus="event => { if (minimized) { event.preventDefault(); restoreButton?.focus() } }">
      <DialogHeader>
        <DialogTitle class="pr-8">{{ t(call.mode === 'voice' ? 'chat.calls.voiceTitle' : 'chat.calls.videoTitle') }}</DialogTitle>
        <DialogDescription>
          {{ call.name || t('chat.calls.account', { id: call.peerId }) }} · {{ t(`chat.calls.phase.${call.phase}`) }}
        </DialogDescription>
      </DialogHeader>
      <div v-if="call.mode === 'video' && (localStream || remoteStream)" class="relative aspect-video overflow-hidden rounded-lg bg-neutral-950">
        <video ref="fullVideo" autoplay muted playsinline class="h-full w-full object-contain" :aria-label="t('chat.calls.peerVideo')" />
        <video v-if="localStream" ref="localVideo" autoplay muted playsinline
          class="absolute bottom-2 right-2 w-1/4 rounded border border-white/20 object-cover" :aria-label="t('chat.calls.localVideo')" />
      </div>
      <Button v-if="call.phase === 'active' || call.phase === 'connecting'" variant="outline" @click="minimized = true">
        <Minimize2 class="size-4" />{{ t('chat.calls.minimize') }}
      </Button>
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
  <aside v-if="call && minimized" class="call-pip liquid-glass-popover fixed right-3 bottom-[calc(5.5rem+env(safe-area-inset-bottom))] z-50 w-52 max-w-[calc(100vw-1.5rem)] rounded-2xl p-2 md:bottom-5 md:right-5"
    :aria-label="t('chat.calls.restore')">
    <video v-if="call.mode === 'video'" ref="pipVideo" autoplay muted playsinline
      class="mb-1 aspect-video w-full rounded-lg bg-neutral-950 object-contain" :aria-label="t('chat.calls.peerVideo')" />
    <div class="flex items-center gap-1">
      <button ref="restoreButton" type="button" class="flex min-h-10 min-w-0 flex-1 items-center gap-2 rounded-lg px-2 text-start text-sm" :aria-label="t('chat.calls.restore')" @click="minimized = false">
        <Maximize2 class="size-4 shrink-0" /><span class="truncate">{{ call.name || t('chat.calls.account', { id: call.peerId }) }}</span>
      </button>
      <Button type="button" size="icon" variant="destructive" :aria-label="t('chat.calls.hangup')" @click="end()"><PhoneOff class="size-4" /></Button>
    </div>
    <Button v-if="needsPlayback" type="button" variant="outline" @click="playRemote">{{ t('chat.calls.playAudio') }}</Button>
  </aside>
</template>
