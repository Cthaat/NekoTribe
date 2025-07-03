<template>
  <div>
    <NuxtLayout>
      <NuxtPage />
    </NuxtLayout>
  </div>
</template>

<script setup>
useSeoMeta({
  title: 'NekoTribe',
  description: '社交媒体平台',
  ogTitle: 'NekoTribe',
  ogDescription: '社交媒体平台',
  ogImage: '/icon.png',
  ogUrl: 'https://neko-tribe.vercel.app/',
  twitterTitle: 'NekoTribe',
  twitterDescription: '社交媒体平台',
  twitterImage: '/icon.png',
  twitterCard: '呕心沥血之作🥵'
});

useHead({
  htmlAttrs: {
    lang: 'zh-cn'
  },
  link: [
    {
      rel: 'icon',
      type: 'image/png',
      href: '/icon.png'
    }
  ]
});
</script>