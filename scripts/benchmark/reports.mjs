import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const backends = ['nuxt', 'go', 'rust'];
const workloads = {
  feed: 'Feed read',
  profile: 'Public profile read',
  createPost: 'Post creation',
  likePost: 'Post like',
  refresh: 'Session refresh',
  websocketBroadcast: 'WebSocket channel message receipt',
  aiWriting: 'AI writing generation',
};
const unavailable = 'Unavailable';
const numberFormat = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 });

function table(headers, rows) {
  const row = (values) => `| ${values.map(cell).join(' | ')} |`;
  return [row(headers), row(headers.map(() => '---')), ...rows.map(row)].join('\n');
}

function cell(value) {
  return String(value ?? unavailable)
    .replace(/[\r\n\t]/g, ' ')
    .replace(/[\\|`*_[\]<>]/g, '\\$&');
}

function verdict(passed) {
  if (passed === true) return 'Passed';
  if (passed === false) return 'Failed';
  return unavailable;
}

function measurement(value) {
  return Number.isFinite(value) ? numberFormat.format(value) : unavailable;
}

function differenceDetails(difference) {
  return [
    difference.reason,
    difference.action,
    difference.probe,
    difference.reference && `Reference ${difference.reference}`,
    difference.path && `Path ${difference.path}`,
    'expected' in difference && `Expected ${JSON.stringify(difference.expected) ?? 'missing'}`,
    'actual' in difference && `Observed ${JSON.stringify(difference.actual) ?? 'missing'}`,
  ].filter(Boolean).join(' · ') || unavailable;
}

function parityMarkdown(result) {
  const differences = result.differences ?? [];
  const targetRows = [];
  const stepRows = [];
  const cleanupRows = [];
  for (const backend of backends) {
    const target = result.targets?.[backend];
    const cases = target?.cases;
    targetRows.push([backend, verdict(target?.passed), cases?.length]);
    for (const testCase of cases ?? []) {
      for (const step of testCase.steps ?? []) {
        const probe = step.probe;
        stepRows.push([
          backend,
          testCase.id,
          step.id,
          step.status,
          probe ? `${probe.name} · ${verdict(probe.passed)}` : '—',
          step.error ?? '—',
        ]);
      }
    }
    for (const action of target?.cleanup ?? []) {
      cleanupRows.push([backend, action.action, verdict(action.passed), action.reason ?? '—']);
    }
  }

  return [
    '# NekoTribe backend parity',
    table(['Result', 'Differences'], [[verdict(result.passed), differences.length]]),
    '## Backend results',
    table(['Backend', 'Result', 'Recorded cases'], targetRows),
    '## Differences',
    differences.length
      ? table(
          ['Backend', 'Case', 'Step', 'Kind', 'Details'],
          differences.map((difference) => [
            difference.target,
            difference.caseId ?? '—',
            difference.stepId ?? '—',
            difference.kind,
            differenceDetails(difference),
          ]),
        )
      : 'No differences recorded.',
    '## Step evidence',
    stepRows.length
      ? table(['Backend', 'Case', 'Step', 'HTTP status', 'Oracle assertion', 'Error'], stepRows)
      : 'Step observations are unavailable.',
    ...(cleanupRows.length
      ? ['## Cleanup', table(['Backend', 'Action', 'Result', 'Reason'], cleanupRows)]
      : []),
    'The [JSON report](parity.json) contains the normalized response bodies and assertion results.',
  ].join('\n\n') + '\n';
}

function benchmarkMarkdown(result) {
  const settings = result.settings ?? {};
  const targetRows = [];
  const workloadRows = [];
  for (const backend of backends) {
    const target = result.targets?.[backend];
    targetRows.push([
      backend,
      measurement(target?.startupMs),
      measurement(target?.peakRssMiB),
      target?.error ?? (target ? '—' : unavailable),
    ]);
    for (const [key, label] of Object.entries(workloads)) {
      const workload = target?.workloads?.[key];
      workloadRows.push([
        backend,
        label,
        ...[
          'samples', 'successful', 'errors', 'cleanupErrors', 'qps', 'p50Ms', 'p95Ms', 'p99Ms',
        ].map((field) => measurement(workload?.[field])),
      ]);
    }
  }

  return [
    '# NekoTribe backend benchmark',
    table(
      ['Result', 'Requests per workload', 'Concurrency', 'Operation timeout (ms)', 'Startup timeout (ms)'],
      [[
        verdict(result.passed),
        measurement(settings.requests),
        measurement(settings.concurrency),
        measurement(settings.timeoutMs),
        measurement(settings.startupTimeoutMs),
      ]],
    ),
    '## Readiness and resident memory',
    table(['Backend', 'Startup to readiness (ms)', 'Peak sampled RSS (MiB)', 'Error'], targetRows),
    'Startup is measured from process launch until `/api/ready` returns success. RSS is the largest sampled resident memory value for the managed process.',
    '## Workload measurements',
    table(
      ['Backend', 'Workload', 'Samples', 'Successful', 'Errors', 'Cleanup errors', 'Successful ops/s', 'P50 (ms)', 'P95 (ms)', 'P99 (ms)'],
      workloadRows,
    ),
    'Throughput uses successful operations over wall-clock workload time. Latency percentiles use successful samples. WebSocket latency uses the matching frame receipt. Setup and cleanup are outside the measured workload.',
    'The [JSON report](benchmark.json) contains the full precision results.',
  ].join('\n\n') + '\n';
}

export async function writeReports(outDir, kind, result) {
  const render = kind === 'parity' ? parityMarkdown : kind === 'benchmark' ? benchmarkMarkdown : null;
  if (!render) throw new Error('Unknown comparison report kind.');
  // The runners supply normalized observations and redacted errors.
  const json = `${JSON.stringify(result, null, 2)}\n`;
  const markdown = render(result);
  const directory = resolve(outDir);
  await mkdir(directory, { recursive: true });
  const jsonPath = join(directory, `${kind}.json`);
  const markdownPath = join(directory, `${kind}.md`);
  await Promise.all([
    writeFile(jsonPath, json, { encoding: 'utf8', mode: 0o600 }),
    writeFile(markdownPath, markdown, { encoding: 'utf8', mode: 0o600 }),
  ]);
  return { jsonPath, markdownPath };
}
