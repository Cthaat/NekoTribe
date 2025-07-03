<!-- default.vue -->
<template>
  <v-app v-if="!$colorMode.unknown">
    <NavBar />
    <v-main>
      <slot />
    </v-main>
  </v-app>
</template>