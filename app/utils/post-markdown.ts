import policy from '../../specifications/requirements/post-markdown.json';

export const maxMarkdownBytes = policy.max_markdown_bytes;

export function markdownBytes(source: string): number {
  return new TextEncoder().encode(source).length;
}

export function validMarkdownBody(source: string): boolean {
  return !!source.trim() && markdownBytes(source) <= maxMarkdownBytes;
}

export function markdownExcerpt(source: string): string {
  return Array.from(source.trim()).slice(0,policy.excerpt_codepoints).join('');
}
