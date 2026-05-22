<script setup lang="ts">
import { computed } from 'vue';
import { MessageCircle, MessagesSquare } from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import type { V2DirectConversation } from '@/types/v2';
import { normalizeAvatarUrl } from '@/utils/assets';

const props = defineProps<{
  conversations: V2DirectConversation[];
  activeConversationId?: number | null;
  isLoading?: boolean;
}>();

const emit = defineEmits<{
  (e: 'select', conversation: V2DirectConversation): void;
  (e: 'view-profile', userId: number): void;
}>();

const { t, locale } = useAppLocale();

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
  <div class="flex h-full min-h-0 flex-col overflow-hidden bg-muted/20">
    <div class="shrink-0 border-b border-border/60 bg-background/60 p-3 backdrop-blur">
      <div class="flex items-center gap-2 text-sm font-semibold">
        <MessagesSquare class="h-4 w-4 text-muted-foreground" />
        <span class="truncate">
          {{ t('chat.directConversations.title') }}
        </span>
      </div>
      <p class="mt-1 text-xs text-muted-foreground">
        {{ t('chat.directConversations.description') }}
      </p>
    </div>

    <ScrollArea class="min-h-0 flex-1">
      <div class="space-y-px p-2">
        <template v-if="isLoading && !hasConversations">
          <div
            v-for="item in 4"
            :key="item"
            class="flex items-center gap-3 rounded-md p-2"
          >
            <Skeleton class="h-9 w-9 rounded-full" />
            <div class="min-w-0 flex-1 space-y-2">
              <Skeleton class="h-3.5 w-24" />
              <Skeleton class="h-3 w-32" />
            </div>
          </div>
        </template>

        <div
          v-else-if="!hasConversations"
          class="mx-auto my-6 flex max-w-[14rem] flex-col items-center justify-center rounded-xl border border-dashed border-border/60 bg-muted/10 px-4 py-8 text-center"
        >
          <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
            <MessageCircle class="h-4 w-4 text-muted-foreground" />
          </div>
          <p class="text-xs leading-relaxed text-muted-foreground">
            {{ t('chat.directConversations.empty') }}
          </p>
        </div>

        <template v-else>
          <div
            v-for="conversation in conversations"
            :key="conversation.conversation_id"
            role="button"
            tabindex="0"
            class="group/conv relative flex w-full items-start gap-2.5 rounded-md px-2 py-2 text-left transition-colors"
            :class="[
              conversation.conversation_id === activeConversationId
                ? 'bg-accent text-accent-foreground'
                : 'text-foreground hover:bg-accent/50'
            ]"
            @click="emit('select', conversation)"
            @keydown.enter.prevent="emit('select', conversation)"
            @keydown.space.prevent="emit('select', conversation)"
          >
            <span
              v-if="conversation.conversation_id === activeConversationId"
              class="absolute inset-y-1.5 left-0 w-0.5 rounded-full bg-primary"
              aria-hidden="true"
            />
            <button
              type="button"
              class="shrink-0 rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              :aria-label="participantName(conversation)"
              @click.stop="
                emit(
                  'view-profile',
                  participantUserId(conversation)
                )
              "
            >
              <Avatar class="h-9 w-9 ring-1 ring-border">
                <AvatarImage
                  :src="participantAvatar(conversation)"
                  :alt="participantName(conversation)"
                />
                <AvatarFallback class="text-xs">
                  {{ initials(conversation) }}
                </AvatarFallback>
              </Avatar>
            </button>

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span
                  class="min-w-0 flex-1 truncate text-sm"
                  :class="{
                    'font-semibold': conversation.unread_count > 0,
                    'font-medium': conversation.unread_count === 0
                  }"
                >
                  {{ participantName(conversation) }}
                </span>
                <span
                  class="shrink-0 text-[10px] tabular-nums text-muted-foreground"
                >
                  {{
                    formatConversationTime(
                      conversation.last_message?.created_at ||
                        conversation.updated_at
                    )
                  }}
                </span>
              </div>
              <div class="mt-0.5 flex items-center gap-2">
                <span
                  class="min-w-0 flex-1 truncate text-xs"
                  :class="
                    conversation.unread_count > 0
                      ? 'text-foreground/80'
                      : 'text-muted-foreground'
                  "
                >
                  {{
                    conversation.last_message?.content ||
                      t('chat.directConversations.noMessages')
                  }}
                </span>
                <span
                  v-if="conversation.unread_count > 0"
                  class="inline-flex h-4 min-w-[16px] shrink-0 items-center justify-center rounded-full bg-primary px-1 text-[10px] font-medium tabular-nums text-primary-foreground"
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
        </template>
      </div>
    </ScrollArea>
  </div>
</template>
