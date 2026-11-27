export interface ParsedUserAgent {
  browser: string;
  os: string;
  summary: string;
}

export interface FormattedSecurityMessage {
  text: string;
  rawUserAgent: string | null;
  summary: string | null;
}

const UA_PATTERN =
  /Mozilla\/[0-9.]+\s*\([^)]+\)(?:\s+(?:\([^)]+\)|[A-Za-z0-9_.+-]+\/[A-Za-z0-9_.+-]+))*/i;

export function parseUserAgent(raw: string): ParsedUserAgent | null {
  const source = raw.trim();
  if (!source) return null;

  let browser = '';
  if (source.includes('Edg/') || source.includes('EdgA/') || source.includes('EdgiOS/')) {
    browser = 'Edge';
  } else if (source.includes('OPR/') || source.includes('Opera')) {
    browser = 'Opera';
  } else if (source.includes('Firefox/') || source.includes('FxiOS/')) {
    browser = 'Firefox';
  } else if (source.includes('Chrome/') || source.includes('CriOS/')) {
    browser = 'Chrome';
  } else if (source.includes('Safari/')) {
    browser = 'Safari';
  }

  let os = '';
  if (/iPhone|iPad|iPod/i.test(source)) {
    os = 'iOS';
  } else if (source.includes('Android')) {
    os = 'Android';
  } else if (source.includes('Windows')) {
    os = 'Windows';
  } else if (source.includes('Mac OS X') || source.includes('Macintosh')) {
    os = 'macOS';
  } else if (source.includes('Linux') || source.includes('X11')) {
    os = 'Linux';
  }

  if (!browser && !os) return null;
  const summary = browser && os ? `${browser} · ${os}` : browser || os;
  return { browser, os, summary };
}

export function formatSecurityMessage(message: string): FormattedSecurityMessage {
  const match = UA_PATTERN.exec(message);
  if (!match) {
    const direct = parseUserAgent(message);
    if (direct && message.includes('Mozilla/')) {
      return {
        text: direct.summary,
        rawUserAgent: message.trim(),
        summary: direct.summary
      };
    }
    return { text: message, rawUserAgent: null, summary: null };
  }
  const rawUa = match[0].trim();
  const parsed = parseUserAgent(rawUa);
  if (!parsed) {
    return { text: message, rawUserAgent: rawUa, summary: null };
  }
  const replaced = `${message.slice(0, match.index)}${parsed.summary}${message.slice(match.index + match[0].length)}`;
  return {
    text: replaced,
    rawUserAgent: rawUa,
    summary: parsed.summary
  };
}
