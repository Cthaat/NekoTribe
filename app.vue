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
/*
 * Vuetify 暗色模式滚动条样式
 * --------------------------
 * 我们使用 Vuetify 自己的暗色主题类 .v-theme--dark 来定位，
 * 而不是 @nuxtjs/color-mode 的 html.dark。
 * 这是在 Vuetify 项目中处理主题样式的正确方法。
*/

/* 适用于 Firefox */
.v-theme--dark {
  scrollbar-color: #424242 #1E1E1E !important;
}

/* 适用于 Chrome, Safari, Edge 等 Webkit 内核的浏览器 */
.v-theme--dark::-webkit-scrollbar,
.v-theme--dark *::-webkit-scrollbar {
  width: 12px !important;
  height: 12px !important;
}

.v-theme--dark::-webkit-scrollbar-track,
.v-theme--dark *::-webkit-scrollbar-track {
  background: #1E1E1E !important;
}

.v-theme--dark::-webkit-scrollbar-thumb,
.v-theme--dark *::-webkit-scrollbar-thumb {
  background-color: #424242 !important;
  border-radius: 6px !important;
  border: 3px solid #1E1E1E !important;
}
</style>
