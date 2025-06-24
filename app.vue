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
/* 暗色模式下的滚动条样式 (终极版) */
/* 这一条规则会给暗色模式下、任何元素的滚动条都应用样式 */

/* 适用于 Firefox */
html.dark * {
  scrollbar-color: #424242 #1E1E1E !important;
}

/* 适用于 Chrome, Safari, Edge 等 Webkit 内核的浏览器 */
html.dark ::-webkit-scrollbar,
html.dark *::-webkit-scrollbar {
  width: 12px !important;
  height: 12px !important;
}

html.dark ::-webkit-scrollbar-track,
html.dark *::-webkit-scrollbar-track {
  background: #1E1E1E !important;
}

html.dark ::-webkit-scrollbar-thumb,
html.dark *::-webkit-scrollbar-thumb {
  background-color: #424242 !important;
  border-radius: 6px !important;
  border: 3px solid #1E1E1E !important;
}
</style>
