<!-- NavBar.vue -->
<template>
    <v-app-bar app>
        <v-btn icon="mdi-arrow-left" @click="goBack"/>
        <v-toolbar-title>{{ $t('NekoTribe') }}</v-toolbar-title>
        <v-spacer/>
        <v-btn icon="mdi-translate" @click="setLocale(locale === 'en' ? 'zh' : 'en')" />
        <v-btn icon="mdi-theme-light-dark" @click="toggleTheme()"/>
        <v-btn icon="mdi-home" :to="localePath('/')"/>
        <v-btn icon="mdi-account" :to="localePath('/login')"/>
    </v-app-bar>
</template>

<script setup>
// 路由
const router = useRouter();
const colorMode = useColorMode();
const { locale, setLocale } = useI18n();
const localePath = useLocalePath();

// TODO 切换主题
const toggleTheme = () => {
    if (colorMode.value === 'light') {
        colorMode.preference = 'dark';
    } else if (colorMode.value === 'dark') {
        colorMode.preference = 'light';
    }
};

// 返回上一页
const goBack = () => {
    router.go(-1);
};
</script>

<style scoped></style>
