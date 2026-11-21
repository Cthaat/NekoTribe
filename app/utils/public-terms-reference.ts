export interface PublicTermsReference {
  readonly id: number;
  readonly version: string;
  readonly locale: string;
  readonly href: string;
  readonly title: string;
  readonly blocks: readonly string[];
}

export function resolvePublicTermsReference(
  catalog: readonly PublicTermsReference[],
  query: unknown,
  locale: string
): PublicTermsReference | null {
  if (typeof query !== 'string') return null;
  const match = /^([1-8])\.([0-9a-f]{64})$/.exec(query);
  if (!match || match[0] !== query) return null;
  return catalog.find(reference =>
    reference.id === Number(match[1]) && reference.version === match[2] && reference.locale === locale
  ) ?? null;
}
