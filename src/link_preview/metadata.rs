use super::{policy, Preview};
use html5ever::{
    tendril::StrTendril,
    tokenizer::{
        states::RawKind, BufferQueue, Tag, TagKind, Token, TokenSink, TokenSinkResult, Tokenizer,
    },
};
use std::cell::RefCell;
use url::Url;

#[derive(Default)]
struct PageText {
    title: String,
    description: String,
    og_title: String,
    og_description: String,
    site_name: String,
    in_title: bool,
    template_depth: usize,
}

pub(super) fn preview(target: &Url, body: &[u8]) -> Option<Preview> {
    let input = BufferQueue::default();
    input.push_back(StrTendril::from_slice(&String::from_utf8_lossy(body)));
    let tokenizer = Tokenizer::new(MetadataSink(RefCell::default()), Default::default());
    let _ = tokenizer.feed(&input);
    tokenizer.end();
    let page = tokenizer.sink.0.into_inner();

    let title = prefer(page.og_title, clean_text(&page.title, policy().title_chars));
    let description = prefer(page.og_description, page.description);
    if title.is_empty() && description.is_empty() {
        return None;
    }
    let host = target.host_str()?;
    let title = prefer(title, clean_text(host, policy().title_chars));
    let site_name = prefer(page.site_name, clean_text(host, policy().site_name_chars));
    Some(Preview {
        url: target.as_str().to_owned(),
        title,
        description,
        site_name,
    })
}

fn prefer(first: String, fallback: String) -> String {
    if first.is_empty() {
        fallback
    } else {
        first
    }
}

struct MetadataSink(RefCell<PageText>);

impl TokenSink for MetadataSink {
    type Handle = ();

    fn process_token(&self, token: Token, _: u64) -> TokenSinkResult<()> {
        let mut page = self.0.borrow_mut();
        match token {
            Token::TagToken(tag) => page.tag(&tag),
            Token::CharacterTokens(text) if page.in_title => {
                page.title.push_str(&text);
                TokenSinkResult::Continue
            }
            _ => TokenSinkResult::Continue,
        }
    }
}

impl PageText {
    fn tag(&mut self, tag: &Tag) -> TokenSinkResult<()> {
        let name: &str = tag.name.as_ref();
        if tag.kind == TagKind::EndTag {
            match name {
                "title" => self.in_title = false,
                "template" => self.template_depth = self.template_depth.saturating_sub(1),
                _ => {}
            }
            return TokenSinkResult::Continue;
        }
        match name {
            "template" => self.template_depth += 1,
            "meta" if self.template_depth == 0 => self.meta(tag),
            "title" => self.in_title = self.template_depth == 0 && self.title.is_empty(),
            _ => {}
        }

        match name {
            "title" | "textarea" => TokenSinkResult::RawData(RawKind::Rcdata),
            "script" => TokenSinkResult::RawData(RawKind::ScriptData),
            "style" | "xmp" | "iframe" | "noembed" | "noframes" | "noscript" => {
                TokenSinkResult::RawData(RawKind::Rawtext)
            }
            "plaintext" => TokenSinkResult::Plaintext,
            _ => TokenSinkResult::Continue,
        }
    }

    fn meta(&mut self, tag: &Tag) {
        let attribute = |name: &str| {
            tag.attrs
                .iter()
                .find(|attr| attr.name.local.as_ref() == name)
                .map(|attr| attr.value.as_ref())
        };
        let key = attribute("property")
            .filter(|value| !value.is_empty())
            .or_else(|| attribute("name"))
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        let Some(content) = attribute("content") else {
            return;
        };
        let (text, limit) = match key.as_str() {
            "og:title" => (&mut self.og_title, policy().title_chars),
            "og:description" => (&mut self.og_description, policy().description_chars),
            "og:site_name" => (&mut self.site_name, policy().site_name_chars),
            "description" => (&mut self.description, policy().description_chars),
            _ => return,
        };
        if text.is_empty() {
            *text = clean_text(content, limit);
        }
    }
}

fn clean_text(raw: &str, max_chars: usize) -> String {
    let mut out = String::new();
    let mut characters = 0;
    let mut space = false;
    for ch in raw.chars() {
        if ch.is_whitespace() || ch.is_control() {
            space = !out.is_empty();
            continue;
        }
        if characters + usize::from(space) >= max_chars {
            break;
        }
        if space {
            out.push(' ');
            characters += 1;
            space = false;
        }
        out.push(ch);
        characters += 1;
    }
    out
}
