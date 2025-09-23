import { ofetch } from 'ofetch';

declare module '#app' {
  interface NuxtApp {
    $api: typeof ofetch;
  }
}

export {};
