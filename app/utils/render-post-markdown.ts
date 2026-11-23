import MarkdownIt from 'markdown-it';
import sanitizeHtml from 'sanitize-html';
import hljs from 'highlight.js/lib/core';
import bash from 'highlight.js/lib/languages/bash';
import go from 'highlight.js/lib/languages/go';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import python from 'highlight.js/lib/languages/python';
import rust from 'highlight.js/lib/languages/rust';
import sql from 'highlight.js/lib/languages/sql';
import typescript from 'highlight.js/lib/languages/typescript';
import { firstPreviewUrl, previewUrl } from './link-preview.ts';

for (const [language, grammar] of Object.entries({bash,go,javascript,json,python,rust,sql,typescript})) {
  hljs.registerLanguage(language,grammar);
}

function safeLink(raw: string): boolean {
  try {
    const url = new URL(raw);
    return (url.protocol === 'https:' || url.protocol === 'http:') && !!url.hostname && !url.username && !url.password;
  } catch { return false; }
}

const parser = new MarkdownIt({
  html: false,
  highlight(code, name) {
    const language = name.toLowerCase();
    return hljs.getLanguage(language) ? hljs.highlight(code,{language,ignoreIllegals:true}).value : '';
  },
});
parser.validateLink = safeLink;
parser.renderer.rules.image = (tokens,index) => parser.utils.escapeHtml(tokens[index]?.content ?? '');

export function renderPostMarkdown(source: string): string {
  return sanitizeHtml(parser.render(source),{
    allowedTags:['p','h1','h2','h3','h4','h5','h6','em','strong','s','code','pre','span','blockquote',
      'ul','ol','li','hr','br','a','table','thead','tbody','tr','th','td'],
    allowedAttributes:{a:['href','title','target','rel'],ol:['start'],code:['class'],span:['class']},
    allowedClasses:{code:['language-*'],span:['hljs-*']},
    allowedSchemes:['http','https'],
    allowProtocolRelative:false,
    parseStyleAttributes:false,
    transformTags:{a:(_tag,attributes) => safeLink(attributes.href ?? '')
      ? {tagName:'a',attribs:{...attributes,target:'_blank',rel:'noopener noreferrer'}}
      : {tagName:'span',attribs:{}}},
  });
}

export function firstMarkdownPreviewUrl(source: string): string | null {
  for (const block of parser.parse(source, {})) {
    for (const token of block.children ?? []) {
      const url = token.type === 'link_open' ? previewUrl(String(token.attrGet('href') ?? '')) :
        token.type === 'text' ? firstPreviewUrl(token.content) : null;
      if (url) return url;
    }
  }
  return null;
}
