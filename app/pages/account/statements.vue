<script setup lang="ts">
// 账户状态（通知/警告/违规）页面
// - 支持筛选（类型/状态）、分页
// - 支持操作：标记已读/未读、解决、忽略、提交申诉
// 引入 Vue 响应式与计算属性
import { ref, onMounted, computed } from 'vue';
import {
  v2CreateStatementAppeal,
  v2ListAccountStatements,
  v2PatchAccountStatement,
  type AccountStatementVM
} from '@/services';
// UI 组件：分隔线、卡片、按钮、徽章
import { Separator } from '@/components/ui/separator';
import { Card, CardContent } from '@/components/ui/card';
import AppButton from '@/components/app/AppButton.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import { Textarea } from '@/components/ui/textarea';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
// 提示组件
import { toast } from 'vue-sonner';

// 类型与状态枚举
type StatementType =
  | 'info'
  | 'warning'
  | 'strike'
  | 'suspension';
type StatementStatus =
  | 'unread'
  | 'read'
  | 'resolved'
  | 'dismissed'
  | 'appealed';

// i18n 工具
const { t } = useAppLocale();

// 列表与分页状态
const loading = ref(false);
const page = ref(1);
const pageSize = ref(10);
const total = ref(0);
const statusFilter = ref<'all' | StatementStatus>('all');
const typeFilter = ref<'all' | StatementType>('all');
const items = ref<AccountStatementVM[]>([]);

const statementTypeLabelKeys: Record<StatementType, string> = {
  info: 'account.statements.types.info',
  warning: 'account.statements.types.warning',
  strike: 'account.statements.types.strike',
  suspension: 'account.statements.types.suspension'
};

function getStatementTypeLabel(type: StatementType): string {
  return t(statementTypeLabelKeys[type]);
}

function isStatementType(type: string): type is StatementType {
  return type in statementTypeLabelKeys;
}

function getStatementLabel(type: string): string {
  return isStatementType(type)
    ? getStatementTypeLabel(type)
    : type;
}

function getStatementBadgeVariant(
  type: string
): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (type === 'info') return 'secondary';
  if (type === 'warning') return 'default';
  if (type === 'strike') return 'destructive';
  return 'outline';
}

// 总页数计算
const totalPages = computed(() =>
  Math.max(1, Math.ceil(total.value / pageSize.value))
);

// 拉取列表
async function load(): Promise<void> {
  loading.value = true;
  try {
    const result = await v2ListAccountStatements({
      page: page.value,
      pageSize: pageSize.value,
      status:
        statusFilter.value === 'all'
          ? undefined
          : statusFilter.value,
      type:
        typeFilter.value === 'all'
          ? undefined
          : typeFilter.value
    });
    items.value = result.items;
    total.value = result.total;
  } catch {
    // 网络错误提示
    toast.error(t('common.networkError'));
  } finally {
    loading.value = false;
  }
}

// 标记/处理动作
async function actMark(
  id: string,
  action:
    | 'mark_read'
    | 'mark_unread'
    | 'resolve'
    | 'dismiss'
): Promise<void> {
  try {
    await v2PatchAccountStatement(Number(id), {
      action
    });
    toast.success(t('account.statements.actionSuccess'));
    await load();
  } catch (e) {
    toast.error(t('account.statements.actionFailed'));
  }
}

// 申诉对话框状态
const showAppeal = ref<null | string>(null);
const appealMsg = ref('');

const appealDialogOpen = computed({
  get: () => showAppeal.value !== null,
  set: (open: boolean) => {
    if (!open) {
      closeAppealDialog();
    }
  }
});

function reloadFromFirstPage(): void {
  page.value = 1;
  load();
}

function closeAppealDialog(): void {
  showAppeal.value = null;
  appealMsg.value = '';
}

// 提交申诉
async function submitAppeal(id: string): Promise<void> {
  // 校验字数
  if (
    !appealMsg.value ||
    appealMsg.value.trim().length < 10
  ) {
    toast.error(t('account.statements.appealTooShort'));
    return;
  }
  try {
    await v2CreateStatementAppeal(Number(id), {
      appealMessage: appealMsg.value.trim()
    });
    // 成功后重置输入并刷新
    toast.success(t('account.statements.appealSubmitted'));
    closeAppealDialog();
    await load();
  } catch (e) {
    toast.error(t('account.statements.appealFailed'));
  }
}

async function submitCurrentAppeal(): Promise<void> {
  if (!showAppeal.value) return;
  await submitAppeal(showAppeal.value);
}

// 挂载时拉取一次
onMounted(load);
</script>

<template>
  <!-- 外层卡片容器 -->
  <Card>
    <!-- 卡片内容区域 -->
    <CardContent class="p-0">
      <!-- 页面主体：桌面端内边距更大 -->
      <div class="space-y-6 p-4 pb-8 sm:p-6 lg:p-10 lg:pb-16">
        <!-- 标题与描述 -->
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ t('account.statements.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ t('account.statements.description') }}
          </p>
        </div>
        <Separator class="my-6" />

        <!-- 筛选条 -->
        <div class="flex flex-wrap items-center gap-3">
          <!-- 类型筛选 -->
          <div class="flex items-center gap-2">
            <span class="text-sm text-muted-foreground">{{
              t('account.statements.filters.type')
            }}</span>
            <Select
              v-model="typeFilter"
              @update:model-value="reloadFromFirstPage"
            >
              <SelectTrigger class="w-[150px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">
                  {{ t('account.statements.types.all') }}
                </SelectItem>
                <SelectItem value="info">
                  {{ t('account.statements.types.info') }}
                </SelectItem>
                <SelectItem value="warning">
                  {{ t('account.statements.types.warning') }}
                </SelectItem>
                <SelectItem value="strike">
                  {{ t('account.statements.types.strike') }}
                </SelectItem>
                <SelectItem value="suspension">
                  {{
                    t('account.statements.types.suspension')
                  }}
                </SelectItem>
              </SelectContent>
            </Select>
          </div>
          <!-- 状态筛选 -->
          <div class="flex items-center gap-2">
            <span class="text-sm text-muted-foreground">{{
              t('account.statements.filters.status')
            }}</span>
            <Select
              v-model="statusFilter"
              @update:model-value="reloadFromFirstPage"
            >
              <SelectTrigger class="w-[150px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">
                  {{ t('account.statements.status.all') }}
                </SelectItem>
                <SelectItem value="unread">
                  {{ t('account.statements.status.unread') }}
                </SelectItem>
                <SelectItem value="read">
                  {{ t('account.statements.status.read') }}
                </SelectItem>
                <SelectItem value="appealed">
                  {{
                    t('account.statements.status.appealed')
                  }}
                </SelectItem>
                <SelectItem value="resolved">
                  {{
                    t('account.statements.status.resolved')
                  }}
                </SelectItem>
                <SelectItem value="dismissed">
                  {{
                    t('account.statements.status.dismissed')
                  }}
                </SelectItem>
              </SelectContent>
            </Select>
          </div>
          <!-- 刷新按钮 -->
          <div class="ml-auto flex items-center gap-2">
            <AppButton
              variant="outline"
              :disabled="loading"
              :loading="loading"
              @click="load()"
              >{{ t('common.refresh') }}</AppButton
            >
          </div>
        </div>

        <!-- 列表 -->
        <div class="mt-4 divide-y rounded-md border">
          <template v-if="loading && !items.length">
            <div
              v-for="index in 3"
              :key="index"
              class="space-y-3 p-4"
            >
              <Skeleton class="h-5 w-32" />
              <Skeleton class="h-4 w-2/3" />
              <Skeleton class="h-4 w-full" />
            </div>
          </template>
          <template v-else-if="items.length">
            <!-- 列表项 -->
            <div
              v-for="it in items"
              :key="it.id"
              class="flex flex-col gap-2 p-4 md:flex-row md:items-start md:justify-between"
            >
              <!-- 左侧信息 -->
              <div class="flex-1 space-y-1">
                <div class="flex items-center gap-2">
                  <!-- 类型徽章，颜色按类型切换 -->
                  <Badge
                    :variant="getStatementBadgeVariant(it.type)"
                  >
                    {{
                      getStatementLabel(it.type)
                    }}
                  </Badge>
                  <!-- 创建时间 -->
                  <span
                    class="text-xs text-muted-foreground"
                    >{{
                      new Date(
                        it.createdAt
                      ).toLocaleString()
                    }}</span
                  >
                  <!-- 对应策略编号（可选） -->
                  <span
                    v-if="it.policy"
                    class="text-xs text-muted-foreground"
                    >· {{ it.policy }}</span
                  >
                </div>
                <!-- 标题与内容 -->
                <div class="font-medium">
                  {{ it.title }}
                </div>
                <p class="text-sm text-muted-foreground">
                  {{ it.message }}
                </p>
                <!-- 申诉状态提示（存在申诉时） -->
                <div
                  v-if="it.appeal"
                  class="text-xs text-amber-600 dark:text-amber-400"
                >
                  {{
                    t('account.statements.appealStatus')
                  }}: {{ it.appeal.status }}
                </div>
              </div>
              <!-- 右侧操作按钮组 -->
              <div
                class="flex shrink-0 flex-wrap items-center gap-2 pt-2 md:pt-0"
              >
                <AppButton
                  size="sm"
                  variant="ghost"
                  :disabled="loading"
                  @click="
                    actMark(
                      it.id,
                      it.status === 'unread'
                        ? 'mark_read'
                        : 'mark_unread'
                    )
                  "
                >
                  {{
                    it.status === 'unread'
                      ? t(
                          'account.statements.actions.markRead'
                        )
                      : t(
                          'account.statements.actions.markUnread'
                        )
                  }}
                </AppButton>
                <AppButton
                  size="sm"
                  variant="outline"
                  :disabled="loading"
                  @click="actMark(it.id, 'resolve')"
                  >{{
                    t('account.statements.actions.resolve')
                  }}</AppButton
                >
                <AppButton
                  size="sm"
                  variant="outline"
                  :disabled="loading"
                  @click="actMark(it.id, 'dismiss')"
                  >{{
                    t('account.statements.actions.dismiss')
                  }}</AppButton
                >
                <AppButton
                  size="sm"
                  :disabled="loading"
                  @click="showAppeal = it.id"
                  >{{
                    t('account.statements.actions.appeal')
                  }}</AppButton
                >
              </div>
            </div>
          </template>
          <!-- 空状态 -->
          <AppEmptyState
            v-else
            class="m-4"
            :title="t('common.empty')"
            :description="t('account.statements.description')"
          />
        </div>

        <!-- 分页 -->
        <div class="mt-4 flex items-center justify-between">
          <div class="text-sm text-muted-foreground">
            {{
              t('common.pagination', {
                page,
                totalPages,
                total
              })
            }}
          </div>
          <div class="flex items-center gap-2">
            <AppButton
              size="sm"
              variant="outline"
              :disabled="loading || page <= 1"
              @click="
                page = Math.max(1, page - 1);
                load();
              "
              >{{ t('common.prev') }}</AppButton
            >
            <AppButton
              size="sm"
              variant="outline"
              :disabled="loading || page >= totalPages"
              @click="
                page = Math.min(totalPages, page + 1);
                load();
              "
              >{{ t('common.next') }}</AppButton
            >
          </div>
        </div>

        <Dialog
          v-if="showAppeal !== null"
          v-model:open="appealDialogOpen"
        >
          <DialogContent>
            <DialogHeader>
              <DialogTitle>
                {{ t('account.statements.appealTitle') }}
              </DialogTitle>
              <DialogDescription>
                {{
                  t(
                    'account.statements.appealPlaceholder'
                  )
                }}
              </DialogDescription>
            </DialogHeader>
            <Textarea
              v-model="appealMsg"
              rows="5"
              class="resize-none"
              :placeholder="
                t(
                  'account.statements.appealPlaceholder'
                )
              "
            />
            <DialogFooter>
              <AppButton
                variant="ghost"
                @click="closeAppealDialog"
                >{{ t('common.cancel') }}</AppButton
              >
              <AppButton
                :disabled="loading"
                :loading="loading"
                @click="submitCurrentAppeal"
                >{{ t('common.submit') }}</AppButton
              >
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>
    </CardContent>
  </Card>
</template>

