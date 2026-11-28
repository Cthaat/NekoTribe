import { canonicalIp } from './client-ip';

// All backends must use the same deployment-local snapshot of canonical IPs to region IDs.
export function changedLoginRegion(previousIp: string, currentIp: string): boolean {
  const source = process.env.NEKO_LOGIN_REGION_MAP;
  if (!source) return false;
  const previous = canonicalIp(previousIp);
  const current = canonicalIp(currentIp);
  if (previous === 'unknown' || current === 'unknown' || previous === current) return false;
  try {
    const regions: unknown = JSON.parse(source);
    if (!regions || typeof regions !== 'object' || Array.isArray(regions)) return false;
    const byIp = regions as Record<string, unknown>;
    const a = byIp[previous], b = byIp[current];
    return typeof a === 'string' && typeof b === 'string' &&
      a.trim() !== '' && b.trim() !== '' && a.trim() !== b.trim();
  } catch {
    return false;
  }
}
