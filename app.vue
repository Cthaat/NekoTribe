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

<style>
/*
 * 暗色模式滚动条样式
 * --------------------------
 * 使用 @nuxtjs/color-mode 的类名来正确应用到 html 根元素
 * 这样可以确保浏览器滚动条正确响应主题变化
*/

/* 适用于 Firefox - 暗色模式 */
html.dark {
  scrollbar-color: #424242 #1E1E1E !important;
}

/* 适用于 Firefox - 亮色模式 */
html.light {
  scrollbar-color: #C1C1C1 #F5F5F5 !important;
}

/* 适用于 Chrome, Safari, Edge 等 Webkit 内核的浏览器 - 暗色模式 */
html.dark::-webkit-scrollbar {
  width: 12px !important;
  height: 12px !important;
}

html.dark::-webkit-scrollbar-track {
  background: #1E1E1E !important;
}

html.dark::-webkit-scrollbar-thumb {
  background-color: #424242 !important;
  border-radius: 6px !important;
  border: 3px solid #1E1E1E !important;
}

html.dark::-webkit-scrollbar-thumb:hover {
  background-color: #525252 !important;
}

/* 适用于 Chrome, Safari, Edge 等 Webkit 内核的浏览器 - 亮色模式 */
html.light::-webkit-scrollbar {
  width: 12px !important;
  height: 12px !important;
}

html.light::-webkit-scrollbar-track {
  background: #F5F5F5 !important;
}

html.light::-webkit-scrollbar-thumb {
  background-color: #C1C1C1 !important;
  border-radius: 6px !important;
  border: 3px solid #F5F5F5 !important;
}

html.light::-webkit-scrollbar-thumb:hover {
  background-color: #A1A1A1 !important;
}

/* 内部元素的滚动条样式 - 暗色模式 */
.v-theme--dark ::-webkit-scrollbar {
  width: 8px !important;
  height: 8px !important;
}

.v-theme--dark ::-webkit-scrollbar-track {
  background: #1E1E1E !important;
}

.v-theme--dark ::-webkit-scrollbar-thumb {
  background-color: #424242 !important;
  border-radius: 4px !important;
}

.v-theme--dark ::-webkit-scrollbar-thumb:hover {
  background-color: #525252 !important;
}

/* 内部元素的滚动条样式 - 亮色模式 */
.v-theme--light ::-webkit-scrollbar {
  width: 8px !important;
  height: 8px !important;
}

.v-theme--light ::-webkit-scrollbar-track {
  background: #F5F5F5 !important;
}

.v-theme--light ::-webkit-scrollbar-thumb {
  background-color: #C1C1C1 !important;
  border-radius: 4px !important;
}

.v-theme--light ::-webkit-scrollbar-thumb:hover {
  background-color: #A1A1A1 !important;
}
</style>
