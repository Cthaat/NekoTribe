<script setup lang="ts">
import { computed } from 'vue';
import { MessageCircle, MessagesSquare } from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
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
  <div class="flex h-full min-h-0 flex-col bg-muted/30">
    <div class="shrink-0 border-b bg-background/50 px-3 py-3">
      <div class="flex items-center gap-2 text-sm font-semibold">
        <MessagesSquare class="h-4 w-4 text-muted-foreground" />
        {{ t('chat.directConversations.title') }}
      </div>
      <p class="mt-1 text-xs text-muted-foreground">
        {{ t('chat.directConversations.description') }}
      </p>
    </div>

    <ScrollArea class="min-h-0 flex-1">
      <div class="space-y-1 p-2">
        <template v-if="isLoading && !hasConversations">
          <div
            v-for="item in 4"
            :key="item"
            class="flex items-center gap-3 rounded-md p-2"
          >
            <Skeleton class="h-9 w-9 rounded-full" />
            <div class="min-w-0 flex-1 space-y-2">
              <Skeleton class="h-4 w-24" />
              <Skeleton class="h-3 w-32" />
            </div>
          </div>
        </template>

        <div
          v-else-if="!hasConversations"
          class="flex min-h-28 flex-col items-center justify-center rounded-md border border-dashed px-3 py-6 text-center text-xs text-muted-foreground"
        >
          <MessageCircle class="mb-2 h-5 w-5" />
          {{ t('chat.directConversations.empty') }}
        </div>

        <template v-else>
          <div
            v-for="conversation in conversations"
            :key="conversation.conversation_id"
            class="flex items-center gap-2 rounded-md p-1 transition-colors hover:bg-muted/50"
            :class="{
              'bg-muted text-foreground':
                conversation.conversation_id === activeConversationId
            }"
          >
            <Button
              type="button"
              variant="ghost"
              size="icon"
              class="h-10 w-10 shrink-0 rounded-full p-0"
              @click="
                emit(
                  'view-profile',
                  participantUserId(conversation)
                )
              "
            >
              <Avatar class="h-9 w-9">
                <AvatarImage
                  :src="participantAvatar(conversation)"
                  :alt="participantName(conversation)"
                />
                <AvatarFallback>
                  {{ initials(conversation) }}
                </AvatarFallback>
              </Avatar>
            </Button>

            <Button
              type="button"
              variant="ghost"
              class="h-auto min-w-0 flex-1 justify-start rounded-md p-1.5 text-left hover:bg-transparent"
              @click="emit('select', conversation)"
            >
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="min-w-0 flex-1 truncate text-sm font-medium">
                    {{ participantName(conversation) }}
                  </span>
                  <span
                    class="shrink-0 text-[11px] text-muted-foreground"
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
                  <span class="min-w-0 flex-1 truncate text-xs text-muted-foreground">
                    {{
                      conversation.last_message?.content ||
                        t('chat.directConversations.noMessages')
                    }}
                  </span>
                  <Badge
                    v-if="conversation.unread_count > 0"
                    variant="destructive"
                    class="h-5 min-w-5 px-1.5 text-xs"
                  >
                    {{
                      conversation.unread_count > 99
                        ? '99+'
                        : conversation.unread_count
                    }}
                  </Badge>
                </div>
              </div>
            </Button>
          </div>
        </template>
      </div>
    </ScrollArea>
  </div>
</template>
