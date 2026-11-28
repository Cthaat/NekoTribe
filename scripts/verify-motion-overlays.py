"""Exercise a running W2 preview with Chromium and synthetic accounts/media.

On a Linux server with Python Playwright (>=1.48) and its Chromium installed:
  python3 scripts/verify-motion-overlays.py all --base-url http://127.0.0.1:34762 --output /tmp/w2-evidence
The browser sends fixture API and signaling messages locally. Media flows over real WebRTC.
"""
import argparse
import asyncio
import itertools
import json
import os
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from playwright.async_api import async_playwright
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('suite', choices=['all', 'matrix', 'pip', 'sheets'], default='all', nargs='?')
parser.add_argument('--base-url', default='http://127.0.0.1:34762')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
BASE = args.base_url.rstrip('/')
ROOT = args.output or Path(tempfile.mkdtemp(prefix='nekotribe-w2-'))
ROOT.mkdir(parents=True, exist_ok=True)
print(f'Browser evidence: {ROOT.resolve()}', flush=True)

def peer(account):
    return 43 if account == 42 else 42

def user(id):
    return {'user_id': id, 'username': 'member' + str(id), 'display_name': 'Member ' + str(id), 'online_status': 'online', 'avatar_url': None}


def pref(id, theme, glass):
    return {'theme_mode': theme, 'glass_intensity': glass, 'language': 'en', 'font_size': 'normal', 'user': {'id': id, 'username': 'member' + str(id), 'name': 'Member ' + str(id), 'relationship': {}}, 'mute_keywords': [], 'blocked_users': []}


async def context(browser, id, theme='light', intensity='standard', mobile=False):
    ctx = await browser.new_context(viewport={'width': 390 if mobile else 1365, 'height': 844 if mobile else 900}, has_touch=mobile, is_mobile=mobile, locale='en-US', color_scheme=theme, permissions=['camera', 'microphone'])
    await ctx.add_cookies([{'name': 'user-preferences-and-auth', 'url': BASE, 'value': quote(json.dumps(pref(id, theme, intensity)), safe='')}])
    other = peer(id)

    async def api(route):
        path = urlparse(route.request.url).path
        data = []
        if path.endswith('/ice-servers'):
            data = {'ice_servers': []}
        elif path.endswith('/direct-conversations'):
            data = [{'conversation_id':7,'participant':user(other),'unread_count':0,'last_message':None,'created_at':'2026-11-27T12:00:00Z','updated_at':'2026-11-27T12:00:00Z'}]
        elif path.endswith('/chat/groups'):
            data = [{'group_id':11,'name':'Motion lab','membership':{'can_manage':False},'unread_count':0,'channel_count':1}]
        elif path.endswith('/groups/11/channels'):
            data = [{'group_id':11,'channel_id':22,'name':'Motion channel','type':'text','unread_count':0,'is_private':False,'is_muted_by_me':False}]
        elif path.endswith('/users/'+str(other)):
            data = user(other)
        elif path.endswith('/read-status'):
            data = {'conversation_id':7,'unread_count':0}
        query = parse_qs(urlparse(route.request.url).query)
        await route.fulfill(json={'code': 200, 'data': data, 'meta': {'page': int(query.get('page', ['1'])[0]), 'page_size': int(query.get('page_size', ['20'])[0]), 'total': len(data) if isinstance(data, list) else 1, 'has_next': False}})
    await ctx.route('**/api/**', api)
    return ctx


async def matrix(browser):
    rows = []
    for (theme, intensity, mobile) in itertools.product(['light', 'dark'], ['standard', 'subtle'], [False, True]):
        ctx = await context(browser, 42, theme, intensity, mobile)
        await ctx.route_web_socket('**/_ws', lambda ws: ws.on_message(lambda _: None))
        page = await ctx.new_page()
        page.set_default_timeout(12000)
        await page.goto(BASE + '/en/about', wait_until='domcontentloaded')
        await page.wait_for_selector('html[data-glass-intensity]')
        await page.wait_for_function("document.querySelector('html').dataset.glassEngine==='blink'")
        await page.wait_for_url(BASE + '/en/about')
        cdp = await ctx.new_cdp_session(page)
        for mode in ['normal', 'motion', 'transparency', 'both']:
            motion = mode in ['motion', 'both']
            transparency = mode in ['transparency', 'both']
            await cdp.send('Emulation.setEmulatedMedia', {'media': 'screen', 'features': [{'name': 'prefers-reduced-motion', 'value': 'reduce' if motion else 'no-preference'}, {'name': 'prefers-reduced-transparency', 'value': 'reduce' if transparency else 'no-preference'}, {'name': 'prefers-color-scheme', 'value': theme}]})
            if mobile:
                await page.locator('header button[aria-keyshortcuts]').click()
            else:
                await page.keyboard.press('Control+k')
            panel = page.locator('.glass-command[data-state=open]')
            await panel.wait_for()
            field = panel.get_by_role('combobox')
            await field.wait_for()
            await page.wait_for_function("document.activeElement?.getAttribute('role') === 'combobox'")
            await page.keyboard.press('ArrowDown')
            await page.wait_for_timeout(350)
            box = await panel.bounding_box()
            await page.mouse.move(1, 1)
            await page.mouse.move(box['x'] + 22, box['y'] + 24)
            await page.wait_for_timeout(60)
            key = '-'.join([theme, intensity, 'mobile' if mobile else 'desktop', mode])
            r = await panel.evaluate("""panel => {
              const root = document.documentElement;
              const list = panel.querySelector('[role=listbox]');
              const selected = list.querySelector('[aria-selected=true]');
              const css = getComputedStyle(panel);
              const overlay = getComputedStyle(document.querySelector('[data-slot=dialog-overlay]'));
              const rail = getComputedStyle(list, '::before');
              return {
                dark: root.classList.contains('dark'), intensity: root.dataset.glassIntensity,
                motion: matchMedia('(prefers-reduced-motion: reduce)').matches,
                transparency: matchMedia('(prefers-reduced-transparency: reduce)').matches,
                glint: panel.hasAttribute('data-glint'), blur: css.backdropFilter, overlayBlur: overlay.backdropFilter,
                animation: css.animationName, material: css.backgroundColor,
                selectedIndex: [...list.children].indexOf(selected), selectedTop: selected.offsetTop,
                railTop: new DOMMatrix(rail.transform).m42,
                railError: Math.abs(new DOMMatrix(rail.transform).m42 - selected.offsetTop),
                railHeightError: Math.abs(parseFloat(rail.height) - selected.offsetHeight),
                focus: document.activeElement?.getAttribute('role'), overflow: root.scrollWidth > innerWidth
              };
            }""")
            assert (r['dark'], r['intensity'], r['motion'], r['transparency']) == (theme == 'dark', intensity, motion, transparency), (key, r)
            assert (r['blur'] == 'none') == transparency and (r['overlayBlur'] == 'none') == transparency, (key, r)
            assert (r['animation'] == 'none') == motion and r['glint'] == (not mobile and (not motion) and (not transparency)), (key, r)
            assert r['selectedIndex'] == 1 and r['railError'] < 0.5 and r['railHeightError'] < 0.5, (key, r)
            assert not r['overflow'] and r['focus'] == 'combobox', (key, r)
            await page.screenshot(path=ROOT / (key + '.png'))
            await page.keyboard.press('Escape')
            await panel.wait_for(state='detached')
            dock = page.locator('.liquid-glass-dock').first
            card = page.locator('.bento-card').first
            r['contentFilter'] = await card.evaluate('e=>getComputedStyle(e).backdropFilter')
            assert r['contentFilter'] == 'none', (key, r)
            if not mobile:
                await page.locator('nav button').filter(has_text='More').first.click()
                menu = page.locator('[data-slot=dropdown-menu-content][data-state=open]')
                await menu.wait_for()
                r['menuAnimation'] = await menu.evaluate('e=>getComputedStyle(e).animationName')
                assert (r['menuAnimation'] == 'none') == motion, (key, r)
                await page.keyboard.press('Escape')
                await menu.wait_for(state='detached')
            await page.wait_for_timeout(200)
            r['idleDockFilter'] = await dock.evaluate('e=>getComputedStyle(e).backdropFilter')
            r['scrollDockFilter']=await dock.evaluate("""e=>{document.dispatchEvent(new Event('scroll'));return getComputedStyle(e).backdropFilter}""")
            await page.wait_for_timeout(230)
            r['restoredDockFilter'] = await dock.evaluate('e=>getComputedStyle(e).backdropFilter')
            assert 'url(' not in r['scrollDockFilter'] and r['idleDockFilter'] == r['restoredDockFilter'], (key, r)
            assert ('url(' in r['idleDockFilter']) == (intensity == 'standard' and mode == 'normal'), (key, r)
            rows.append(dict(case=key, **r))
            (ROOT / 'matrix.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
            print(key, flush=True)
        if not mobile:
            for target in ['/en/discover', '/en/groups/discover']:
                await page.locator('nav a[href="' + target + '"]').first.click()
                await page.wait_for_url('**' + target)
                rail = page.locator('.sidebar-rail:visible')
                await page.wait_for_timeout(350)
                delta=await rail.evaluate("""e=>{const item=e.querySelector('[data-current]'), css=getComputedStyle(e,'::before');return Math.abs(new DOMMatrix(css.transform).m42-item.offsetTop)+Math.abs(parseFloat(css.height)-item.offsetHeight)}""")
                assert delta < 0.5, (target, delta)
                print('sidebar', theme, intensity, target, delta, flush=True)
        await ctx.close()


async def pip(browser):
    sockets = {}
    devices = {}
    messages = []
    pages = {}
    captures = []
    ready = {account: asyncio.Event() for account in (42, 43)}
    invited = asyncio.Event()
    deny = 'camera=(), microphone=(), geolocation=()'
    allow = 'camera=(self), microphone=(self), geolocation=()'

    def wire(id, ws):
        sockets[id] = ws
        devices.pop(id, None)

        def send(msg):
            obj = json.loads(msg)
            kind = obj['type']
            if kind == 'ping':
                ws.send(json.dumps({'type': 'system_notification', 'timestamp': int(time.time() * 1000), 'data': {'code': 'realtime_status', 'user_id': id, 'server_id': 'w2-local', 'local_presence': True, 'remote_events': 'connected'}}))
                ready[id].set()
                return
            if not kind.startswith('call_'):
                return
            messages.append({'from': id, 'type': kind})
            data = obj['data']
            devices[id] = data['client_id']
            frame = {'type': kind, 'timestamp': int(time.time() * 1000), 'data': dict(data, caller_id=42, callee_id=43, caller_client_id=devices[42], callee_client_id=devices.get(43))}
            sockets[peer(id)].send(json.dumps(frame))
            if id == 42 and kind == 'call_invite':
                invited.set()
        ws.on_message(send)
    for id in [43, 42]:
        ctx = await context(browser, id)
        await ctx.add_init_script("""window.callPeers = [];
          window.RTCPeerConnection = class extends RTCPeerConnection {
            constructor(...args) { super(...args); callPeers.push(this); }
            close() { super.close(); sessionStorage.setItem('peerClosed', this.connectionState); }
          };""")
        await ctx.route_web_socket('**/_ws', lambda ws, id=id: wire(id, ws))
        p = await ctx.new_page()
        pages[id] = p
        p.set_default_timeout(15000)
        p.on('pageerror', lambda e: print('pageerror', str(e), flush=True))
        doc = await p.goto(BASE + ('/en/chat?conversation=7' if id == 42 else '/en/about'), wait_until='domcontentloaded')
        assert doc.headers.get('permissions-policy') == (allow if id == 42 else deny), doc.url
        await asyncio.wait_for(ready[id].wait(), 15)
        assert await p.evaluate("isSecureContext && typeof navigator.mediaDevices?.getUserMedia === 'function'"), p.url
        features = await p.evaluate("['camera','microphone','geolocation'].map(k => document.featurePolicy.allowsFeature(k))")
        assert features == [id == 42, id == 42, False], (p.url, features)
    (a, b) = (pages[42], pages[43])
    api = await a.context.request.get(BASE + '/api/health')
    assert api.ok and 'application/json' in api.headers['content-type'] and api.headers.get('permissions-policy') == deny
    asset = await a.context.request.get(BASE + '/robots.txt')
    assert asset.ok and 'text/plain' in asset.headers['content-type'] and asset.headers.get('permissions-policy') == deny
    chinese = await a.context.request.get(BASE + '/zh/chat', max_redirects=0)
    assert chinese.ok and chinese.headers.get('permissions-policy') == allow
    dial = a.get_by_role('button', name='Start video call', exact=True).first
    cdp = await a.context.new_cdp_session(a)
    context_id = (await cdp.send('Target.getTargetInfo'))['targetInfo']['browserContextId']
    permission = dict(permission={'name': 'camera'}, origin=BASE, browserContextId=context_id)
    await cdp.send('Browser.setPermission', dict(permission, setting='denied'))
    await dial.click()
    await a.get_by_text('Allow microphone or camera access to make a call.', exact=True).wait_for()
    assert not invited.is_set() and not messages, messages
    await cdp.send('Browser.setPermission', dict(permission, setting='granted'))
    await dial.click()
    callback = b.get_by_role('button', name='Decline and open chat to call back')
    await callback.wait_for()
    assert await b.get_by_role('button', name='Answer', exact=True).count() == 0
    ready[43].clear()
    async with b.expect_response(lambda r: r.request.is_navigation_request() and urlparse(r.url).path == '/en/chat') as entry:
        await callback.click()
    doc = await entry.value
    assert parse_qs(urlparse(doc.url).query).get('conversation') == ['7'] and doc.headers.get('permissions-policy') == allow
    await b.get_by_role('button', name='Start video call', exact=True).first.wait_for()
    assert await b.evaluate("['camera','microphone'].every(k => document.featurePolicy.allowsFeature(k))")
    await asyncio.wait_for(ready[43].wait(), 15)
    await a.locator('[data-slot=dialog-content]').wait_for(state='hidden')
    assert {'from': 43, 'type': 'call_reject'} in messages, messages
    invited.clear()
    async with a.expect_response(lambda r: urlparse(r.url).path == '/api/v2/calls/ice-servers') as ice:
        await dial.click()
    assert (await ice.value).ok, 'caller ICE configuration failed'
    try:
        await asyncio.wait_for(invited.wait(), 15)
    except TimeoutError as error:
        notice = await a.locator('[data-sonner-toast]').all_text_contents()
        raise AssertionError(('missing caller invite after ICE configuration', messages, notice)) from error
    await b.get_by_role('button', name='Answer', exact=True).click()
    for p in [a, b]:
        await p.wait_for_function("callPeers[0]?.connectionState==='connected' && document.querySelector('audio')?.srcObject?.active && document.querySelector('video')?.videoWidth>0")

    async def snapshot(stage):
        await a.wait_for_timeout(600)
        r = await a.evaluate("""async () => {
          const pc = callPeers[0];
          const audio = document.querySelector('audio');
          const video = document.querySelector('.call-pip video') || document.querySelector('video');
          const inbound = [...(await pc.getStats()).values()].filter(row => row.type === 'inbound-rtp');
          window.heldAudio ??= audio;
          return {
            path: location.pathname, peerCount: callPeers.length, connected: pc.connectionState,
            tracks: pc.getReceivers().map(receiver => [receiver.track.id, receiver.track.readyState]),
            sameAudio: audio === heldAudio, playing: !audio.paused, audioTime: audio.currentTime,
            videoWidth: video.videoWidth, packets: Object.fromEntries(inbound.map(row => [row.kind, row.packetsReceived]))
          };
        }""")
        assert r['connected'] == 'connected' and r['peerCount'] == 1 and r['sameAudio'] and r['playing'] and (r['videoWidth'] > 0) and all((x[1] == 'live' for x in r['tracks'])), r
        if captures:
            old = captures[-1]
            assert r['tracks'] == old['tracks'] and r['audioTime'] > old['audioTime'] and all((r['packets'][k] > old['packets'][k] for k in ['audio', 'video'])), (r, old)
        captures.append(dict(stage=stage, **r))
        await a.screenshot(path=ROOT / ('pip-' + stage + '.png'))
    await snapshot('connected')
    await a.get_by_role('button', name='Minimize call').click()
    await a.locator('.call-pip').wait_for()
    await snapshot('minimized')
    await a.locator('aside nav a[href$="/discover"]').first.click()
    await a.wait_for_url('**/en/discover')
    await snapshot('route-change')
    await a.get_by_role('button', name='Restore call').click()
    await a.locator('[data-slot=dialog-content] video').first.wait_for()
    await snapshot('restored')
    async with a.expect_response(lambda r: r.request.is_navigation_request() and urlparse(r.url).path == '/en/discover') as after_call:
        await a.get_by_role('button', name='Hang up', exact=True).click()
    assert (await after_call.value).headers.get('permissions-policy') == deny
    for p in [a, b]:
        await p.wait_for_function("sessionStorage.getItem('peerClosed')==='closed' && !document.querySelector('audio')")
    assert sum((x['type'] == 'call_hangup' for x in messages)) == 1, messages
    (ROOT / 'pip.json').write_text(json.dumps({'captures': captures, 'signaling': messages, 'bothClosed': True}, indent=2))
    for p in pages.values():
        await p.context.close()


async def sheets(browser):
    result = []
    for mobile in [False, True]:
        ctx = await context(browser, 42, mobile=mobile)
        await ctx.route_web_socket('**/_ws', lambda ws: ws.on_message(lambda msg: None))
        p = await ctx.new_page()
        await p.goto(BASE + '/en/chat', wait_until='domcontentloaded')
        trigger = p.get_by_role('button', name='Notification settings', exact=True)
        if mobile and (not await trigger.is_visible()):
            await p.get_by_text('Motion channel', exact=True).first.click()
        await trigger.click()
        box = p.locator('[data-slot=sheet-content]')
        await box.wait_for()
        await p.wait_for_timeout(350)
        r=await box.evaluate("""e=>({duration:getComputedStyle(e).animationDuration,bounds:e.getBoundingClientRect().toJSON(),viewport:[innerWidth,innerHeight]})""")
        assert r['duration'] == '0.3s', r
        await p.screenshot(path=ROOT / ('sheet-' + ('mobile' if mobile else 'desktop') + '.png'))
        if mobile:
            assert abs(r['bounds']['bottom'] - r['viewport'][1]) < 1, r
            h = await box.locator('[aria-hidden=true].touch-none').bounding_box()
            x = h['x'] + h['width'] / 2
            y = h['y'] + h['height'] / 2
            cdp = await ctx.new_cdp_session(p)

            async def drag(dy):
                await cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
                await cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': x, 'y': y + dy}]})
                await cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
            await drag(30)
            assert await box.get_attribute('data-state') == 'open'
            await drag(80)
        else:
            assert abs(r['bounds']['right'] - r['viewport'][0]) < 1, r
            await p.keyboard.press('Escape')
        await box.wait_for(state='detached')
        result.append(dict(mobile=mobile, dismissed=True, **r))
        await ctx.close()
    (ROOT / 'sheets.json').write_text(json.dumps(result, indent=2))


async def main():
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(executable_path=os.environ.get('CHROMIUM_EXECUTABLE'), headless=True, args=['--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required'])
        try:
            suites = {'matrix': matrix, 'pip': pip, 'sheets': sheets}
            for suite in suites if args.suite == 'all' else [args.suite]:
                await suites[suite](browser)
        except Exception:
            for (i, ctx) in enumerate(browser.contexts):
                for page in ctx.pages:
                    print('failure', page.url, (await page.locator('body').inner_text())[:1300], flush=True)
                    await page.screenshot(path=ROOT / ('debug-' + suite + '-' + str(i) + '.png'), timeout=6000)
            raise
        finally: await browser.close()
if __name__ == '__main__':
    asyncio.run(main())
