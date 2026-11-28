<script setup lang="ts">
import { computed } from 'vue';
import { MessageCircle } from 'lucide-vue-next';
import UserAvatar from '@/components/UserAvatar.vue';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import { Button } from '@/components/ui/button';
import type { V2DirectConversation } from '@/types/v2';
import { normalizeAvatarUrl } from '@/utils/assets';

const props = defineProps<{
  conversations: V2DirectConversation[];
  activeConversationId?: number | null;
  isLoading?: boolean;
  page?: number;
  hasNext?: boolean;
}>();

const emit = defineEmits<{
  (e: 'select', conversation: V2DirectConversation): void;
  (e: 'view-profile', userId: number): void;
  (e: 'change-page', page: number): void;
}>();

const { t, locale } = useAppLocale();
const localePath = useLocalePath();

const hasConversations = computed(
  () => props.conversations.length > 0
);

function participantName(
  conversation: V2DirectConversation
): string {
  const participant = conversation.participant;
  return participant.display_name || participant.username;
}

function initials(conversation: V2DirectConversation): string {
  return participantName(conversation).trim().slice(0, 2) || '?';
}

function participantAvatar(
  conversation: V2DirectConversation
): string {
  return normalizeAvatarUrl(conversation.participant.avatar_url);
}

function participantUserId(
  conversation: V2DirectConversation
): number {
  return conversation.participant.user_id;
}

function formatConversationTime(value: string | undefined): string {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString(
    locale.value === 'en' ? 'en-US' : 'zh-CN',
    {
      hour: '2-digit',
      minute: '2-digit'
    }
  );
}
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-hidden bg-transparent">
    <ScrollArea class="min-h-0 flex-1">
      <MotionSkeletonSwap class="p-2">
        <div v-if="isLoading && !hasConversations" aria-busy="true" class="space-y-1">
          <div
            v-for="item in 4"
            :key="item"
            class="flex items-center gap-3 px-4 py-3"
          >
            <Skeleton class="h-[52px] w-[52px] rounded-full" />
            <div class="min-w-0 flex-1 space-y-2">
              <Skeleton class="h-3.5 w-28" />
              <Skeleton class="h-3 w-40" />
            </div>
          </div>
        </div>

        <div
          v-else-if="!hasConversations"
          class="mx-auto my-8 flex max-w-[15rem] flex-col items-center justify-center rounded-2xl bg-[var(--hover)] px-4 py-8 text-center"
        >
          <div class="mb-3 flex h-11 w-11 items-center justify-center rounded-full bg-primary/10 text-primary">
            <MessageCircle class="h-5 w-5" />
          </div>
          <p class="text-xs leading-relaxed text-muted-foreground">
            {{ t('chat.directConversations.empty') }}
          </p>
          <NuxtLink
            :to="localePath('/?feed=trending')"
            class="mt-4 inline-flex h-8 items-center rounded-full bg-primary px-4 text-xs font-medium text-primary-foreground transition-opacity hover:opacity-90"
          >
            {{ t('nav.main.discover') }}
          </NuxtLink>
        </div>

        <div v-else class="space-y-1">
          <div
            v-for="conversation in conversations"
            :key="conversation.conversation_id"
            role="button"
            tabindex="0"
            class="group/conv relative flex w-full items-center gap-3 rounded-2xl px-3 py-2.5 text-left transition-colors"
            :class="[
              conversation.conversation_id === activeConversationId
                ? 'bg-secondary text-foreground'
                : 'text-foreground hover:bg-[var(--hover)]'
            ]"
            @click="emit('select', conversation)"
            @keydown.enter.prevent="emit('select', conversation)"
            @keydown.space.prevent="emit('select', conversation)"
          >
            <button
              type="button"
              class="relative shrink-0 rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              :aria-label="participantName(conversation)"
              @click.stop="
                emit(
                  'view-profile',
                  participantUserId(conversation)
                )
              "
            >
              <UserAvatar
                :src="participantAvatar(conversation)"
                :name="participantName(conversation)"
                :username="conversation.participant.username"
                :seed="participantUserId(conversation)"
                class="!h-[52px] !w-[52px] text-base"
              />
              <span
                v-if="conversation.participant.online_status === 'online'"
                class="absolute right-0 bottom-0 size-3.5 rounded-full bg-emerald-500 ring-2 ring-background"
              />
            </button>

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span
                  class="min-w-0 flex-1 truncate text-sm"
                  :class="conversation.unread_count > 0 ? 'font-bold text-foreground' : 'font-semibold'"
                >
                  {{ participantName(conversation) }}
                </span>
                <span
                  class="shrink-0 text-[11px] tabular-nums"
                  :class="conversation.unread_count > 0 ? 'font-semibold text-primary' : 'text-muted-foreground'"
                >
                  {{
                    formatConversationTime(
                      conversation.last_message?.created_at ||
                        conversation.updated_at
                    )
                  }}
                </span>
              </div>
              <div class="mt-1 flex items-center gap-2">
                <span
                  class="min-w-0 flex-1 truncate text-xs"
                  :class="
                    conversation.unread_count > 0
                      ? 'font-medium text-foreground'
                      : 'text-muted-foreground'
                  "
                >
                  {{
                    conversation.last_message
                      ? conversation.last_message.content.trim() || t('chat.directConversations.attachment')
                      : t('chat.directConversations.noMessages')
                  }}
                </span>
                <span
                  v-if="conversation.unread_count > 0"
                  class="inline-flex h-5 min-w-[20px] shrink-0 items-center justify-center rounded-full bg-primary/14 px-1.5 text-[11px] font-semibold tabular-nums text-primary"
                >
                  {{
                    conversation.unread_count > 99
                      ? '99+'
                      : conversation.unread_count
                  }}
                </span>
              </div>
            </div>
          </div>
        </div>
      </MotionSkeletonSwap>
    </ScrollArea>
    <div v-if="(page ?? 1) > 1 || hasNext" class="flex shrink-0 flex-wrap justify-center gap-1 px-2 py-1.5">
      <Button v-if="(page ?? 1) > 1" size="sm" variant="ghost" :disabled="isLoading" @click="emit('change-page', (page ?? 1) - 1)">{{ t('chat.directConversations.previousPage') }}</Button>
      <Button v-if="hasNext" size="sm" variant="ghost" :disabled="isLoading" @click="emit('change-page', (page ?? 1) + 1)">{{ t('chat.directConversations.nextPage') }}</Button>
    </div>
  </div>
</template>
