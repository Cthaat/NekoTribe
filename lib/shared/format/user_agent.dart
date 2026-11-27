class ParsedUserAgent {
  const ParsedUserAgent({
    required this.browser,
    required this.os,
    required this.summary,
  });

  final String browser;
  final String os;
  final String summary;
}

class FormattedSecurityMessage {
  const FormattedSecurityMessage({
    required this.text,
    this.rawUserAgent,
    this.summary,
  });

  final String text;
  final String? rawUserAgent;
  final String? summary;
}

final RegExp _uaTokenPattern = RegExp(
  r'Mozilla\/[0-9.]+\s*\([^)]+\)(?:\s+(?:\([^)]+\)|[A-Za-z0-9_.+-]+\/[A-Za-z0-9_.+-]+))*',
  caseSensitive: false,
);

/// Parses a raw User-Agent string into human-readable browser and OS names.
ParsedUserAgent? parseUserAgent(String raw) {
  final source = raw.trim();
  if (source.isEmpty) return null;

  var browser = '';
  if (source.contains('Edg/') || source.contains('EdgA/') || source.contains('EdgiOS/')) {
    browser = 'Edge';
  } else if (source.contains('OPR/') || source.contains('Opera')) {
    browser = 'Opera';
  } else if (source.contains('Firefox/') || source.contains('FxiOS/')) {
    browser = 'Firefox';
  } else if (source.contains('Chrome/') || source.contains('CriOS/')) {
    browser = 'Chrome';
  } else if (source.contains('Safari/')) {
    browser = 'Safari';
  }

  var os = '';
  if (RegExp(r'iPhone|iPad|iPod', caseSensitive: false).hasMatch(source)) {
    os = 'iOS';
  } else if (source.contains('Android')) {
    os = 'Android';
  } else if (source.contains('Windows')) {
    os = 'Windows';
  } else if (source.contains('Mac OS X') || source.contains('Macintosh')) {
    os = 'macOS';
  } else if (source.contains('Linux') || source.contains('X11')) {
    os = 'Linux';
  }

  if (browser.isEmpty && os.isEmpty) return null;
  final summary = (browser.isNotEmpty && os.isNotEmpty)
      ? '$browser · $os'
      : (browser.isNotEmpty ? browser : os);
  return ParsedUserAgent(browser: browser, os: os, summary: summary);
}

/// Replaces embedded raw Mozilla/5.0 User-Agent strings inside a security/login
/// notification message with a compact summary while preserving the raw string
/// for optional expandable inspection.
FormattedSecurityMessage formatSecurityMessage(String message) {
  final match = _uaTokenPattern.firstMatch(message);
  if (match == null) {
    final direct = parseUserAgent(message);
    if (direct != null && message.contains('Mozilla/')) {
      return FormattedSecurityMessage(
        text: direct.summary,
        rawUserAgent: message.trim(),
        summary: direct.summary,
      );
    }
    return FormattedSecurityMessage(text: message);
  }
  final rawUa = match.group(0)!.trim();
  final parsed = parseUserAgent(rawUa);
  if (parsed == null) {
    return FormattedSecurityMessage(text: message, rawUserAgent: rawUa);
  }
  final replaced = message.replaceRange(match.start, match.end, parsed.summary);
  return FormattedSecurityMessage(
    text: replaced,
    rawUserAgent: rawUa,
    summary: parsed.summary,
  );
}
