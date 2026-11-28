"""Check the Nuxt preview with synthetic local media and Playwright Chromium."""
from pathlib import Path
from urllib.parse import urlsplit, quote, parse_qs
from itertools import product
from playwright.sync_api import sync_playwright,expect
import json, sys, re, os

from tempfile import mkdtemp

root = Path(os.environ.get('W1_ARTIFACTS') or mkdtemp(prefix='nuxt-w1-'))
root.mkdir(parents=True, exist_ok=True)
base = os.getenv('W1_PREVIEW_URL', 'http://127.0.0.1:43191')
stamp = '2026-01-02T09:00:00Z'
user = dict(user_id=8, username='aoi',display_name='Aoi',avatar_url='/avatars/avatar1.png',relationship={'relation':'none'})
media = [dict(media_id=i,public_url=f'/w1-image-{i}.png',media_type='image',mime_type='image/png',file_name=f'study-{i}.png',file_size=1200,alt_text=f'Sample {i}') for i in [1,2]]
post = dict(post_id=181,author=user,location='',language='zh',content='清晨的色彩练习',post_type='original',visibility='public',media=media,tags=[],mentions=[],viewer_state={},stats=dict.fromkeys(['likes_count','comments_count','replies_count','retweets_count','views_count'],0),created_at=stamp,updated_at=stamp)
group = dict(post_id=182,group_id=9,group_name='Studio',author=user,content='色彩练习',media_urls=[x['public_url'] for x in media],created_at=stamp)
def fixture(route):
    path = urlsplit(route.request.url).path
    data = [post] if path in ['/api/v2/posts','/api/v2/posts/trending'] else [group] if path=='/api/v2/feed/groups' else post if path=='/api/v2/posts/181' else []
    if path=='/api/v2/chat/groups':
        data=[dict(group_id=9,name='Studio',membership={'can_manage':False},unread_count=0,channel_count=1)]
    elif path=='/api/v2/chat/groups/9/channels':
        data=[dict(group_id=9,channel_id=17,name='sketch',type='text',is_private=False,unread_count=0,is_muted_by_me=False)]
    elif path=='/api/v2/chat/channels/17/messages':
        data=[dict(message_id=197,is_deleted=False,group_id=9,channel_id=17,message_type='text',content='关于晨光',author=user,media=media,reactions=[],created_at=stamp)]
    route.fulfill(json=dict(code=200,success=True,message='ok',data=data,meta={'total':len(data),'page':1,'page_size':int(parse_qs(urlsplit(route.request.url).query).get('page_size',[20])[0]),'has_next':False}))
def setup(browser,mobile,theme,glass,motion,trans,fallback=False):
    size={'width':390,'height':844} if mobile else {'width':1280,'height':850}
    ctx=browser.new_context(viewport=size,is_mobile=mobile,has_touch=mobile,locale='zh-CN',color_scheme=theme)
    pref=dict(theme_mode=theme,glass_intensity=glass,language='zh',font_size='normal',user={'id':7,'username':'w1','name':'W1','avatarUrl':''},authSession=None)
    ctx.add_cookies([dict(name='user-preferences-and-auth',value=quote(json.dumps(pref,separators=(',',':'))),url=base)])
    ctx.route('**/api/v2/**', fixture)
    ctx.route_web_socket('**/_ws',lambda ws: None)
    def img(route):
        color='#417e85' if '1.png' in route.request.url else '#e7a564'
        route.fulfill(content_type='image/svg+xml',body=f'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="440"><rect width="800" height="440" fill="{color}"/><circle cx="420" cy="200" r="142" fill="#f6dfba"/><path d="M0 440 L240 270 L440 400 L650 290 L800 380 V440Z" fill="#314b60"/></svg>')
    ctx.route('**/w1-image-*.png',img)
    ctx.route('**/storage/default-avatar.png',img)
    ctx.route('**/avatars/avatar1.png',img)
    page=ctx.new_page()
    cdp=ctx.new_cdp_session(page)
    cdp.send('Emulation.setEmulatedMedia',{'features':[{'name':'prefers-reduced-motion','value':'reduce' if motion else 'no-preference'},{'name':'prefers-reduced-transparency','value':'reduce' if trans else 'no-preference'},{'name':'prefers-color-scheme','value':theme}]})
    if fallback: page.add_init_script("Object.defineProperty(document,'startViewTransition',{value:undefined})")
    else: page.add_init_script("""window.vt=[];const native=document.startViewTransition?.bind(document); if(native) document.startViewTransition=(args)=>{const t=native(args);t.ready.then(()=>window.vt.push('ready')).catch(e=>window.vt.push(e.name));return t}""")
    errors=[]
    page.on('console',lambda m: errors.append(m.text[:220]) if m.type=='error' and re.search(r'(?:TypeError|ReferenceError|SyntaxError)',m.text) else None)
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.set_default_timeout(20000)
    page.goto(base+'/zh',wait_until='domcontentloaded')
    page.locator('html[data-glass-intensity]').wait_for(state='attached')
    return ctx,page,errors

def center(el):
    r=el.bounding_box()
    return r['x']+r['width']/2,r['y']+r['height']/2
def run(browser,mobile,theme,glass,motion,trans):
    label='w1-{}-{}-{}-m{}t{}'.format('mobile' if mobile else 'desktop',theme,glass,int(motion),int(trans))
    ctx,p,errors=setup(browser,mobile,theme,glass,motion,trans)
    try:
        seg=p.locator('[role=tablist].liquid-scrub')
        seg.wait_for()
        thumbs=p.locator('button[data-media-url]')
        thumbs.first.wait_for()
        seg.locator('[role=tab]').nth(0).focus()
        p.keyboard.press('ArrowRight')
        expect(seg.locator('[role=tab]').nth(1)).to_have_attribute('aria-selected','true')
        p.keyboard.press('Home')
        thumbs.first.wait_for()
        p.wait_for_timeout(380)
        state=p.evaluate("""() => {const sel=s=>document.querySelector(s), cs=e=>getComputedStyle(e), pill=sel('[role=tablist] .scrub-pill'), btn=sel('[role=tab][aria-selected=true]'), r=pill.getBoundingClientRect(), b=btn.getBoundingClientRect();return {dark:document.documentElement.classList.contains('dark'),glass:document.documentElement.dataset.glassIntensity,reducedMotion:matchMedia('(prefers-reduced-motion:reduce)').matches,reducedTransparency:matchMedia('(prefers-reduced-transparency:reduce)').matches,alignment:Math.abs(r.x+r.width/2-b.x-b.width/2),dockFilter:cs(sel('nav.liquid-glass-dock')).backdropFilter,cardFilter:cs(sel('article.bento-card')).backdropFilter,glint:cs(pill).backgroundImage,transition:cs(pill).transitionDuration}}""")
        assert state['dark']==(theme=='dark') and state['glass']==glass and state['reducedMotion']==motion and state['reducedTransparency']==trans,state
        assert state['alignment']<.5 and state['cardFilter']=='none',state
        assert (state['glint']=='none')==trans and (not trans or state['dockFilter']=='none'),state
        p.screenshot(path=root/(label+'.png'),timeout=12000)
        x,y=center(seg.locator('button').nth(0))
        end,_=center(seg.locator('button').nth(1))
        p.mouse.move(x,y); p.mouse.down(); p.mouse.move(end,y,steps=6)
        p.wait_for_timeout(75)
        pressed=seg.locator('.scrub-pill').evaluate("""e=>{const m=new DOMMatrix(getComputedStyle(e).transform);return {sx:m.a,sy:m.d,glint:getComputedStyle(e).backgroundImage}}""")
        assert abs(pressed['sx']*pressed['sy']-(1 if motion else 1.08**2))<.02,pressed
        p.mouse.up()
        p.wait_for_timeout(100)
        expect(seg.locator('button').nth(1)).to_have_attribute('aria-selected','true')
        seg.locator('button').nth(0).click()
        thumbs.first.click()
        dialog=p.locator('[role=dialog].lightbox-content')
        dialog.wait_for()
        image=dialog.locator('img').first
        image.wait_for()
        p.wait_for_timeout(320)
        image.dblclick()
        p.wait_for_timeout(350 if not motion else 30)
        scale=image.evaluate('e=>new DOMMatrix(getComputedStyle(e.closest("[class*=will-change]")).transform).a')
        assert abs(scale-2)<.01,scale
        p.keyboard.press('ArrowRight')
        p.wait_for_timeout(350)
        assert image.get_attribute('src').endswith('2.png')
        p.keyboard.press('Escape')
        dialog.wait_for(state='hidden')
        assert not errors,errors
        return dict(case=label,**state,pressed=pressed,zoom=scale,pageErrors=errors)
    except Exception:
        p.screenshot(path=root/'w1-diagnostic.png')
        print(p.url,p.locator('body').inner_text()[:1200],errors,flush=True)
        raise
    finally: ctx.close()

def route_case(browser,fallback):
    ctx,p,errors=setup(browser,True,'light','standard',False,False,fallback)
    p.locator('nav.liquid-glass-dock:visible [data-scrub-item]').first.wait_for()
    p.evaluate("""() => {window.framesSeen=[];function record(){if(document.querySelector('.page-leave-active')&&document.querySelector('.page-enter-active'))framesSeen.push({direction:document.documentElement.dataset.tabDirection,layout:document.querySelectorAll('[data-page-content]').length});requestAnimationFrame(record)}record()}""")
    dock=p.locator('nav.liquid-glass-dock')
    cdp=ctx.new_cdp_session(p)
    seg=p.locator('[role=tablist].liquid-scrub')
    a,b=seg.locator('button').nth(0),seg.locator('button').nth(1)
    x,y=center(a); xx,_=center(b)
    for kind,px in [('touchStart',x),('touchMove',xx),('touchCancel',None)]:
        points=[] if px is None else [dict(x=px,y=y)]
        cdp.send('Input.dispatchTouchEvent',dict(type=kind,touchPoints=points))
    assert a.get_attribute('aria-selected')=='true'
    assert seg.get_attribute('data-pressed')=='false'
    p.locator('button[data-media-url]').first.click()
    dialog=p.locator('.lightbox-content')
    image=dialog.locator('img')
    image.wait_for()
    p.wait_for_timeout(350)
    for ending in ['touchCancel','touchEnd']:
        x,y=center(image)
        for kind,py in [('touchStart',y),('touchMove',y+70),('touchMove',y+160),(ending,None)]:
            cdp.send('Input.dispatchTouchEvent',dict(type=kind,touchPoints=[] if py is None else [dict(x=x,y=py)]))
        if ending=='touchCancel':
            p.wait_for_timeout(375)
            assert dialog.is_visible()
        else:
            dialog.wait_for(state='hidden')
    dirs=[]
    for idx,path,direction in [(1,'/groups/discover','forward'),(3,'/chat','forward'),(1,'/groups/discover','back'),(0,'/','back')]:
        item=dock.locator('a').nth(idx)
        if idx==3:
            old=dock.locator('a[aria-current="page"]').first
            x,y=center(old); xx,_=center(item)
            for kind,px in [('touchStart',x),('touchMove',(x+xx)/2),('touchMove',xx)]:
                cdp.send('Input.dispatchTouchEvent',dict(type=kind,touchPoints=[dict(x=px,y=y)]))
            p.wait_for_timeout(120)
            cdp.send('Input.dispatchTouchEvent',dict(type='touchEnd',touchPoints=[]))
        else: item.click()
        p.wait_for_function(r"s=>location.pathname.replace(/^\/(en|zh)(?=\/|$)/,'').replace(/\/$/,'') === s.replace(/\/$/,'')",arg=path)
        p.wait_for_timeout(500)
        assert p.locator('html').get_attribute('data-tab-direction')==direction
        assert p.locator('[data-page-content]').count()==1
        if path=='/groups/discover':
            pill=p.locator('.tabs-pill').first
            pill.wait_for()
            selected=p.locator('[data-slot=tabs-trigger][data-state=active]').first
            for n in [0,1]:
                assert abs(center(pill)[n]-center(selected)[n])<.5
        dirs.append(direction)
    frames=p.evaluate('window.framesSeen')
    native=p.evaluate('window.vt || []')
    if fallback: assert frames,('no concurrent frames',frames)
    else: assert native.count('ready')>=4,native
    assert not errors,errors
    ctx.close()
    return {'fallback':fallback,'directions':dirs,'overlapFrames':frames,'native':native}

def gallery(page,origin):
    thumb=page.locator('button[data-media-url]:visible')
    thumb.first.wait_for()
    thumb.nth(0).click()
    dlg=page.locator('[role=dialog].lightbox-content')
    img=dlg.locator('img')
    img.wait_for()
    page.wait_for_timeout(320)
    point=img.evaluate("e=>{const r=e.getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]}")
    x,y=point
    page.mouse.move(x,y);page.mouse.down();page.mouse.move(x,y+55,steps=5);page.mouse.up()
    page.wait_for_timeout(360)
    assert dlg.is_visible()
    stage=img.locator('xpath=ancestor::*[contains(@class,"will-change")][1]')
    assert abs(stage.evaluate("e=>new DOMMatrix(getComputedStyle(e).transform).m42"))<.5
    page.keyboard.press('ArrowRight')
    page.wait_for_timeout(360)
    # The thumbnail can move between opening and closing (viewport, reflow, or scroll).
    page.evaluate("document.querySelectorAll('button[data-media-url]')[1].style.translate='18px 0px'")
    r=thumb.nth(1).bounding_box()
    dst=stage.locator('..').bounding_box()
    page.keyboard.press('Escape')
    result=stage.evaluate("e=>e.style.transform")
    assert 'scale(' in result,result
    vals=[float(n) for n in re.findall(r'-?\d+(?:\.\d+)?',result.replace('translate3d','translate'))]
    assert abs(vals[0]-(r['x']+r['width']/2-dst['x']-dst['width']/2))<1,(result,r,dst)
    assert abs(vals[3]-(r['width']/dst['width']))<.02,(vals,r,dst)
    dlg.wait_for(state='hidden')
    return dict(surface=origin,closeTransform=result,liveThumb=r,layoutRect=dst)
def check_galleries(b):
    ctx,p,errors=setup(b,False,'dark','subtle',False,False)
    results=[gallery(p,'feed')]
    p.locator('[role=tablist].liquid-scrub button').last.click()
    p.locator('[class~="group/post"] button[data-media-url]').first.wait_for()
    results.append(gallery(p,'group post'))
    p.goto(base+'/zh/tweet/181',wait_until='domcontentloaded')
    results.append(gallery(p,'post detail'))
    p.goto(base+'/zh/chat',wait_until='domcontentloaded')
    results.append(gallery(p,'chat'))
    assert not errors,errors
    (root/'w1-galleries.json').write_text(json.dumps(results,indent=2))
    ctx.close()


if __name__=='__main__':
    with sync_playwright() as pw:
        browser=pw.chromium.launch(channel=os.getenv('W1_CHROME_CHANNEL'),headless=True,args=['--disable-background-networking'])
        print('Artifacts:',root,flush=True)
        cases=list(product([True,False],['light','dark'],['standard','subtle'],[False,True],[False,True]))
        results=[]
        for case in cases[:1] if '--probe' in sys.argv else cases:
            row=run(browser,*case)
            print(row['case'],row['alignment'],flush=True)
            results.append(row)
            (root/'w1-matrix.json').write_text(json.dumps(results,indent=2))
        (root/'w1-routes.json').write_text(json.dumps([route_case(browser,f) for f in [False,True]],indent=2))
        check_galleries(browser)
        browser.close()
