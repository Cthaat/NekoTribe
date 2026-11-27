import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import {
  computeScrollMetrics,
  updateScrollDirection
} from '../app/composables/useScrollDirection.ts';

const repoRoot = path.resolve(import.meta.dirname, '..');

function readText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function flattenKeys(obj, prefix = '') {
  return Object.keys(obj).flatMap(key => {
    const next = prefix ? `${prefix}.${key}` : key;
    const value = obj[key];
    return value && typeof value === 'object' && !Array.isArray(value)
      ? flattenKeys(value, next)
      : [next];
  });
}

test('computeScrollMetrics clamps progress between 0 and 1 cleanly', () => {
  assert.deepEqual(computeScrollMetrics(0, 800, 800), {
    scrollY: 0,
    maxScroll: 0,
    progress: 0
  });
  assert.deepEqual(computeScrollMetrics(-50, 2000, 1000), {
    scrollY: 0,
    maxScroll: 1000,
    progress: 0
  });
  assert.deepEqual(computeScrollMetrics(500, 2000, 1000), {
    scrollY: 500,
    maxScroll: 1000,
    progress: 0.5
  });
  assert.deepEqual(computeScrollMetrics(1500, 2000, 1000), {
    scrollY: 1000,
    maxScroll: 1000,
    progress: 1
  });
});

test('mobile dock scroll condensation keeps all links available', () => {
  const dock = readText('app/components/MobileTabBar.vue');
  const nav = dock.match(/<nav\s[\s\S]*?\n\s*>/)?.[0];
  assert.ok(nav);
  assert.match(nav, /data-condensed/);
  assert.match(nav, /focus-within:scale-100/);
  assert.doesNotMatch(nav, /opacity-0|pointer-events-none|aria-hidden/);
  assert.match(dock, /isHidden\.value && !prefersReducedMotion\.value/);
});

test('updateScrollDirection applies threshold, hysteresis, and reveals near top or bottom', () => {
  let state = { lastY: 0, direction: 'idle', hidden: false };

  // Within top reveal offset -> always visible
  state = updateScrollDirection(state, 20, 1200, { threshold: 48, hysteresis: 16 });
  assert.equal(state.hidden, false);

  // Small delta below hysteresis -> retains previous state
  state = updateScrollDirection({ lastY: 120, direction: 'down', hidden: true }, 128, 1200, {
    threshold: 48,
    hysteresis: 16
  });
  assert.equal(state.hidden, true);
  assert.equal(state.lastY, 120);

  // Scroll down past threshold + hysteresis -> hides dock
  state = updateScrollDirection({ lastY: 40, direction: 'up', hidden: false }, 90, 1200, {
    threshold: 48,
    hysteresis: 16
  });
  assert.equal(state.direction, 'down');
  assert.equal(state.hidden, true);

  // Scroll up beyond hysteresis -> reveals dock immediately
  state = updateScrollDirection(state, 64, 1200, { threshold: 48, hysteresis: 16 });
  assert.equal(state.direction, 'up');
  assert.equal(state.hidden, false);

  // Near bottom -> reveals dock so pagination/footer actions stay reachable
  state = updateScrollDirection(
    { lastY: 600, direction: 'down', hidden: true },
    1185,
    1200,
    { threshold: 48, hysteresis: 16 }
  );
  assert.equal(state.hidden, false);
});

test('radix-vue is completely removed and Lightbox uses reka-ui', () => {
  const pkg = JSON.parse(readText('package.json'));
  assert.equal(pkg.dependencies['radix-vue'], undefined);
  assert.equal(pkg.devDependencies?.['radix-vue'], undefined);

  const lightbox = readText('app/components/Lightbox.vue');
  assert.match(lightbox, /from 'reka-ui'/);
  assert.doesNotMatch(lightbox, /radix-vue/);
});

test('about.vue uses Quiet Tonal Bento surfaces and valid master docs URL', () => {
  const about = readText('app/pages/about.vue');
  assert.match(about, /\/tree\/master\/docs/);
  assert.doesNotMatch(about, /\/tree\/main\/doc\b/);
  assert.match(about, /bento-card/);
  assert.match(about, /bento-tile/);
});

test('Wave 1 Track A new pages exist and sidebar/hashtags point to them', () => {
  const expectedFiles = [
    'app/pages/discover.vue',
    'app/pages/tags/[tag].vue',
    'app/pages/groups/[slug]/index.vue',
    'app/pages/groups/[slug]/posts/[postId].vue',
    'app/components/motion/ReadingProgressBar.vue',
    'app/components/motion/NewPostsPill.vue',
    'app/components/motion/StaggeredList.vue'
  ];
  for (const file of expectedFiles) {
    assert.equal(fs.existsSync(path.join(repoRoot, file)), true, `Missing ${file}`);
  }

  const sidebar = readText('app/components/AppSidebar.vue');
  assert.match(sidebar, /localePath\('\/discover'\)/);

  const tweetContent = readText('app/components/TweetContent.vue');
  assert.match(tweetContent, /\/tags\/\$\{encodeURIComponent\(tag\)\}/);
});

test('zh and en i18n locale catalogs remain 100% symmetric', () => {
  const zh = JSON.parse(readText('i18n/locales/zh.json'));
  const en = JSON.parse(readText('i18n/locales/en.json'));
  const zhKeys = new Set(flattenKeys(zh));
  const enKeys = new Set(flattenKeys(en));
  const missingInEn = [...zhKeys].filter(key => !enKeys.has(key));
  const missingInZh = [...enKeys].filter(key => !zhKeys.has(key));
  assert.deepEqual(missingInEn, []);
  assert.deepEqual(missingInZh, []);
});
