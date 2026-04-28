<script lang="ts" setup>
import {
  addDays,
  addHours,
  format,
  nextSaturday
} from 'date-fns';
import {
  Archive,
  ArchiveX,
  Clock,
  Forward,
  MoreVertical,
  Reply,
  ReplyAll,
  Trash2,
  RotateCcw
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Calendar } from '@/components/ui/calendar';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';
import { Separator } from '@/components/ui/separator';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger
} from '@/components/ui/tooltip';
import type { MailItem } from './mail/types';

interface MailDisplayProps {
  mail?: MailItem;
  isTrashView?: boolean;
}

const props = defineProps<MailDisplayProps>();
const { t } = useAppLocale();

const today = new Date();

const emit = defineEmits(['delete-mail', 'restore-mail']);
</script>

<template>
  <div class="flex h-full flex-col">
    <div class="flex items-center p-2">
      <div class="flex items-center gap-2" v-if="mail">
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
            >
              <Archive class="size-4" />
              <span class="sr-only">{{
                t('mail.display.archive')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.archive')
          }}</TooltipContent>
        </Tooltip>
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
            >
              <ArchiveX class="size-4" />
              <span class="sr-only">{{
                t('mail.display.moveToJunk')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.moveToJunk')
          }}</TooltipContent>
        </Tooltip>
        <Tooltip v-if="!isTrashView">
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
              @click.stop="emit('delete-mail', mail.id)"
            >
              <Trash2 class="size-4" />
              <span class="sr-only">{{
                t('mail.display.moveToTrash')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.moveToTrash')
          }}</TooltipContent>
        </Tooltip>
        <Tooltip v-else>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
              @click.stop="emit('restore-mail', mail.id)"
            >
              <RotateCcw class="size-4" />
              <span class="sr-only">{{
                t('mail.display.restore')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent
            >{{ t('mail.display.restoreFromTrash') }}</TooltipContent
          >
        </Tooltip>
        <Separator
          orientation="vertical"
          class="mx-1 h-6"
        />
        <Tooltip>
          <Popover>
            <PopoverTrigger as-child>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  :disabled="!mail"
                >
                  <Clock class="size-4" />
                  <span class="sr-only">{{
                    t('mail.display.snooze')
                  }}</span>
                </Button>
              </TooltipTrigger>
            </PopoverTrigger>
            <PopoverContent class="flex w-[535px] p-0">
              <div
                class="flex flex-col gap-2 border-r px-2 py-4"
              >
                <div class="px-4 text-sm font-medium">
                  {{ t('mail.display.snoozeUntil') }}
                </div>
                <div class="grid min-w-[250px] gap-1">
                  <Button
                    variant="ghost"
                    class="justify-start font-normal"
                  >
                    {{ t('mail.display.laterToday') }}
                    <span
                      class="ml-auto text-muted-foreground"
                    >
                      {{
                        format(
                          addHours(today, 4),
                          'E, h:m b'
                        )
                      }}
                    </span>
                  </Button>
                  <Button
                    variant="ghost"
                    class="justify-start font-normal"
                  >
                    {{ t('mail.display.tomorrow') }}
                    <span
                      class="ml-auto text-muted-foreground"
                    >
                      {{
                        format(
                          addDays(today, 1),
                          'E, h:m b'
                        )
                      }}
                    </span>
                  </Button>
                  <Button
                    variant="ghost"
                    class="justify-start font-normal"
                  >
                    {{ t('mail.display.thisWeekend') }}
                    <span
                      class="ml-auto text-muted-foreground"
                    >
                      {{
                        format(
                          nextSaturday(today),
                          'E, h:m b'
                        )
                      }}
                    </span>
                  </Button>
                  <Button
                    variant="ghost"
                    class="justify-start font-normal"
                  >
                    {{ t('mail.display.nextWeek') }}
                    <span
                      class="ml-auto text-muted-foreground"
                    >
                      {{
                        format(
                          addDays(today, 7),
                          'E, h:m b'
                        )
                      }}
                    </span>
                  </Button>
                </div>
              </div>
              <div class="p-2">
                <Calendar />
              </div>
            </PopoverContent>
          </Popover>
          <TooltipContent>{{
            t('mail.display.snooze')
          }}</TooltipContent>
        </Tooltip>
      </div>
      <div
        class="ml-auto flex items-center gap-2"
        v-if="mail"
      >
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
            >
              <Reply class="size-4" />
              <span class="sr-only">{{
                t('mail.display.reply')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.reply')
          }}</TooltipContent>
        </Tooltip>
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
            >
              <ReplyAll class="size-4" />
              <span class="sr-only">{{
                t('mail.display.replyAll')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.replyAll')
          }}</TooltipContent>
        </Tooltip>
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              :disabled="!mail"
            >
              <Forward class="size-4" />
              <span class="sr-only">{{
                t('mail.display.forward')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.forward')
          }}</TooltipContent>
        </Tooltip>
      </div>
      <Separator orientation="vertical" class="mx-2 h-6" />
      <DropdownMenu v-if="mail">
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            :disabled="!mail"
          >
            <MoreVertical class="size-4" />
            <span class="sr-only">{{
              t('mail.display.more')
            }}</span>
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem
            >{{ t('mail.display.markAsUnread') }}</DropdownMenuItem
          >
          <DropdownMenuItem>{{
            t('mail.display.starThread')
          }}</DropdownMenuItem>
          <DropdownMenuItem>{{
            t('mail.display.addLabel')
          }}</DropdownMenuItem>
          <DropdownMenuItem>{{
            t('mail.display.muteThread')
          }}</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
    <Separator />
    <div v-if="mail" class="flex flex-1 flex-col">
      <div class="flex items-start p-4">
        <div class="flex items-start gap-4 text-sm">
          <Avatar>
            <AvatarImage
              :src="mail.avatar"
              :alt="mail.name"
            />
            <AvatarFallback>
              {{ mail.name }}
            </AvatarFallback>
          </Avatar>
          <div class="grid gap-1">
            <div class="font-semibold">
              {{ mail.name }}
            </div>
            <div class="line-clamp-1 text-xs">
              {{ mail.subject }}
            </div>
            <div class="line-clamp-1 text-xs">
              <span class="font-medium">{{
                t('mail.display.replyTo')
              }}</span>
              {{ mail.email }}
            </div>
          </div>
        </div>
        <div
          v-if="mail.date"
          class="ml-auto text-xs text-muted-foreground"
        >
          {{ format(new Date(mail.date), 'PPpp') }}
        </div>
      </div>
      <Separator />
      <div class="flex-1 whitespace-pre-wrap p-4 text-sm">
        {{ mail.text }}
      </div>
    </div>
    <div
      v-else
      class="p-8 text-center text-muted-foreground"
    >
      {{ t('mail.display.noSelection') }}
    </div>
  </div>
</template>
