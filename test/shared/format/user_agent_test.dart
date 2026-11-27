import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/format/user_agent.dart';

void main() {
  test('parseUserAgent summarizes common desktop and mobile browsers', () {
    expect(
      parseUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36',
      )?.summary,
      'Chrome · Windows',
    );
    expect(
      parseUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36 Edg/158.0.0.0',
      )?.summary,
      'Edge · Windows',
    );
    expect(
      parseUserAgent(
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/17.5 Safari/605.1.15',
      )?.summary,
      'Safari · macOS',
    );
    expect(
      parseUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
      )?.summary,
      'Safari · iOS',
    );
    expect(
      parseUserAgent(
        'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0',
      )?.summary,
      'Firefox · Linux',
    );
    expect(parseUserAgent('unknown client'), isNull);
  });

  test('formatSecurityMessage replaces embedded UA strings and keeps raw UA', () {
    const raw =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/158.0.0.0 Safari/537.36';
    final formatted = formatSecurityMessage('检测到新设备登录：$raw 的访问请求');
    expect(formatted.text, '检测到新设备登录：Chrome · Windows 的访问请求');
    expect(formatted.rawUserAgent, raw);
    expect(formatted.summary, 'Chrome · Windows');

    final plain = formatSecurityMessage('Alice 喜欢了你的帖子');
    expect(plain.text, 'Alice 喜欢了你的帖子');
    expect(plain.rawUserAgent, isNull);
  });
}
