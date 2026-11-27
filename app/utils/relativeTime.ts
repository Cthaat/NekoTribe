import { formatDistanceToNowStrict } from 'date-fns';
import { enUS, zhCN } from 'date-fns/locale';

export function formatRelativeTime(iso: string, locale: 'zh' | 'en' | string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const isZh = locale.toLowerCase().startsWith('zh');

  if (diffMs < 60_000) {
    return isZh ? '刚刚' : 'now';
  }
  if (diffMs < 24 * 60 * 60 * 1000) {
    return formatDistanceToNowStrict(date, {
      locale: isZh ? zhCN : enUS,
      addSuffix: false
    }).replace(/\s+/g, isZh ? '' : ' ');
  }
  if (diffMs < 7 * 24 * 60 * 60 * 1000) {
    const days = Math.max(1, Math.floor(diffMs / (24 * 60 * 60 * 1000)));
    return isZh ? `${days}天` : `${days}d`;
  }
  if (date.getFullYear() === now.getFullYear()) {
    return isZh
      ? `${date.getMonth() + 1}月${date.getDate()}日`
      : date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  return isZh
    ? `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`
    : date.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

export function formatFullTime(iso: string, locale: 'zh' | 'en' | string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const isZh = locale.toLowerCase().startsWith('zh');
  return date.toLocaleString(isZh ? 'zh-CN' : 'en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  });
}
