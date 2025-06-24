<template>
  <div>
    <NuxtLayout>
      <NuxtPage />
    </NuxtLayout>
  </div>
</template>

<script setup>
useSeoMeta({
  title: '推特山寨版',
  description: 'Web应用开发大作业🥵🥵🥵',
  ogTitle: '推特山寨版',
  ogDescription: 'Web应用开发大作业🥵🥵🥵',
  ogImage: '/icon.png',
  ogUrl: 'https://twitter-clone-kohl-rho.vercel.app/',
  twitterTitle: '推特山寨版',
  twitterDescription: 'Web应用开发大作业🥵🥵🥵',
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

<style>
/* 暗色模式下的滚动条样式 */

/* 适用于 Firefox */
html.dark * {
  scrollbar-color: #424242 #1E1E1E;
}

/* 适用于 Chrome, Safari, Edge 等 Webkit 内核的浏览器 */
html.dark ::-webkit-scrollbar {
  width: 12px;
  height: 12px;
}

html.dark ::-webkit-scrollbar-track {
  background: #1E1E1E;
}

html.dark ::-webkit-scrollbar-thumb {
  background-color: #424242;
  border-radius: 6px;
  border: 3px solid #1E1E1E;
}
</style>
