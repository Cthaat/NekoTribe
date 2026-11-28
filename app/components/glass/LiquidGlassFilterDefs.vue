<script setup lang="ts">
import { onBeforeUnmount, onMounted } from 'vue';

const BEZEL_MAP_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100"><defs><linearGradient id="gx" x1="0%" y1="0%" x2="100%" y2="0%"><stop offset="0%" stop-color="rgb(232,128,128)" stop-opacity="0.72"/><stop offset="7%" stop-color="rgb(176,128,128)" stop-opacity="0.42"/><stop offset="16%" stop-color="rgb(128,128,128)" stop-opacity="0"/><stop offset="84%" stop-color="rgb(128,128,128)" stop-opacity="0"/><stop offset="93%" stop-color="rgb(80,128,128)" stop-opacity="0.42"/><stop offset="100%" stop-color="rgb(24,128,128)" stop-opacity="0.72"/></linearGradient><linearGradient id="gy" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="rgb(128,232,128)" stop-opacity="0.72"/><stop offset="7%" stop-color="rgb(128,176,128)" stop-opacity="0.42"/><stop offset="16%" stop-color="rgb(128,128,128)" stop-opacity="0"/><stop offset="84%" stop-color="rgb(128,128,128)" stop-opacity="0"/><stop offset="93%" stop-color="rgb(128,80,128)" stop-opacity="0.42"/><stop offset="100%" stop-color="rgb(128,24,128)" stop-opacity="0.72"/></linearGradient></defs><rect width="100" height="100" fill="rgb(128,128,128)"/><rect width="100" height="100" rx="22" ry="22" fill="url(#gx)"/><rect width="100" height="100" rx="22" ry="22" fill="url(#gy)"/></svg>`;
const displacementMapUri = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(BEZEL_MAP_SVG)}`;

let stopTrackingScroll: (() => void) | undefined;

onMounted(() => {
  if (typeof window === 'undefined' || typeof CSS === 'undefined' || typeof CSS.supports !== 'function') {
    return;
  }

  const ua = navigator.userAgent;
  const isBlink =
    /Chrome|Chromium|Edg|OPR|Brave/i.test(ua) &&
    !/Firefox|FxiOS/i.test(ua) &&
    (Boolean((window as unknown as { chrome?: unknown }).chrome) || /AppleWebKit\/537\.36/i.test(ua));

  const root = document.documentElement;
  if (!isBlink || !CSS.supports('backdrop-filter', 'url(#nekotribe-liquid-refract)')) {
    delete root.dataset.glassEngine;
    return;
  }
  root.dataset.glassEngine = 'blink';
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce), (prefers-reduced-transparency: reduce)');
  let idleTimer: number | undefined;
  function onScroll() {
    if (root.dataset.glassIntensity === 'subtle' || reduced.matches) return;
    if (idleTimer === undefined) root.dataset.glassScrolling = '';
    window.clearTimeout(idleTimer);
    idleTimer = window.setTimeout(() => {
      delete root.dataset.glassScrolling;
      idleTimer = undefined;
    }, 150);
  }

  // Capture includes independently scrolling panes such as the mailbox.
  document.addEventListener('scroll', onScroll, { capture: true, passive: true });
  stopTrackingScroll = () => {
    document.removeEventListener('scroll', onScroll, true);
    window.clearTimeout(idleTimer);
    delete root.dataset.glassScrolling;
    delete root.dataset.glassEngine;
  };
});

onBeforeUnmount(() => stopTrackingScroll?.());
</script>

<template>
  <svg
    aria-hidden="true"
    width="0"
    height="0"
    class="pointer-events-none fixed -z-10 h-0 w-0 overflow-hidden"
  >
    <defs>
      <filter
        id="nekotribe-liquid-refract"
        x="-10%"
        y="-10%"
        width="120%"
        height="120%"
        color-interpolation-filters="sRGB"
      >
        <feImage
          :href="displacementMapUri"
          result="bezel"
          preserveAspectRatio="none"
          x="0"
          y="0"
          width="100%"
          height="100%"
        />
        <feDisplacementMap
          in="SourceGraphic"
          in2="bezel"
          scale="7"
          xChannelSelector="R"
          yChannelSelector="G"
        />
      </filter>
    </defs>
  </svg>
</template>
