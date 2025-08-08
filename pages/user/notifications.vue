<script setup lang="ts">
import Mail from '@/components/Mail.vue';
import { accounts, mails } from '@/data/mails';
</script>

<template>
  <div class="hidden flex-col md:flex">
    <Mail
      :accounts="accounts"
      :mails="mails"
      :nav-collapsed-size="4"
    />
  </div>
</template>
