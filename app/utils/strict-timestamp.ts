/** Calendar-checked zoned timestamp; match Dart's microsecond precision. */
export function parseStrictTimestamp(value: unknown): bigint {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(typeof value === 'string' ? value : '');
  if (!match) throw new Error('Invalid timestamp');
  const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
  const hour = Number(match[4]), minute = Number(match[5]), second = Number(match[6]);
  const offsetHour = Number(match[9] ?? 0), offsetMinute = Number(match[10] ?? 0);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > days[month - 1]!
    || hour > 23 || minute > 59 || second > 59 || offsetHour > 23 || offsetMinute > 59) throw new Error('Invalid timestamp');
  // setUTCFullYear avoids Date.UTC's special interpretation of years 00..99.
  const instant = new Date(0);
  instant.setUTCFullYear(year, month - 1, day);
  instant.setUTCHours(hour, minute, second, 0);
  const offset = (offsetHour * 60 + offsetMinute) * (match[8] === '-' ? -1 : 1);
  const micros = (match[7] ?? '').padEnd(6, '0').slice(0, 6);
  return BigInt(instant.getTime() - offset * 60_000) * 1000n + BigInt(micros);
}
