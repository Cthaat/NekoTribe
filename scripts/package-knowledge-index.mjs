import { copyFile, cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildTermsMaintenanceBundle } from './lib/ai-public-terms-build.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const runtimeFiles = [
  'scripts/ai-public-terms-maintenance.mjs',
  'scripts/ai-skill-config-maintenance.mjs',
  'scripts/migrate-db.mjs',
  'server/database/schema.mjs',
  'server/database/schema-definition.mjs',
  'specifications/requirements/ai-public-terms-catalog.json',
];
const usage = 'Usage: node scripts/package-knowledge-index.mjs --out NEW_DIRECTORY';
const readme = `# NekoTribe 公开知识索引

在 Windows 或 Linux 上使用 Node.js 22.12 或更高的 Node.js 22 版本。
先准备 Oracle、Qdrant 和向量端点，并按包内索引规范创建 profiles/initial.json。
复制两个环境文件示例，分别为更新和检索填入实际配置。两份私有配置的
AI_INDEX_ACTIVE_PROFILE 指向同一个 profiles/active.json。

    node --env-file=.env.updater index.mjs check-sources
    node --env-file=.env.updater index.mjs bootstrap profiles/initial.json
    node --env-file=.env.updater index.mjs watch
    node --env-file=.env.retrieval index.mjs serve
    node --env-file=.env.retrieval index.mjs health
    node --env-file=.env.updater index.mjs watch-status

检索进程可先运行 serve。将 bootstrap 和 watch 放在更新进程或另一个终端中运行。
首次激活前 health 返回未就绪，激活成功后检索进程无需重启。

check-sources 使用 Oracle 只读事务检查普通帖、评论、公开群帖、群评论和规则目录。
返回各类来源的检查结果，任一来源不可读或已发布的规则目录不匹配时返回非零退出码。

向量模型变更时，准备指向新集合的配置，使用更新环境构建并切换：

    node --env-file=.env.updater index.mjs switch profiles/next.json

完整候选通过校验后才切换。也可以分开执行 build 和 activate。
只读校验候选用 node --env-file=.env.retrieval index.mjs verify profiles/next.json。
省略配置路径会校验当前激活索引。
运行中，标准错误流的 index-progress 记录显示当前阶段及可用计数。
保留的自动集合可用 rollback 恢复，人工集合使用原配置 activate。
配置中的地址应能从各自进程访问。
Oracle 凭据与 Qdrant 写权限只配置到更新进程。
三个业务后端共用 AI_KNOWLEDGE_INDEX_URL 和对应的 AI_INDEX_SERVICE_TOKEN。

升级已有集合时，先部署新版检索服务，再用新版更新进程执行一次 sync 或等待 watch。
更新完成后，新版后端可检索公开群帖和群评论。旧后端只会收到其支持的来源。
索引同步会沿用之前的发布校验，失败时仍可继续使用原激活集合。
watch 在失败后从 60 秒开始重试，连续失败时逐步增至正常同步间隔。
下一次尝试时间可通过 watch-status 查看。

更新环境文件中的 NEKO_TERMS_PACKAGED 也供公开规则维护命令使用。
可运行 node --env-file=.env.updater scripts/ai-public-terms-maintenance.mjs --plan 离线查看规则目录摘要。

本包还可以维护三套后端共用的 Skill 启用配置。离线检查四个内置 ID：

    node --env-file=.env.maintenance.example scripts/ai-skill-config-maintenance.mjs --plan --enabled-json '["knowledge-answer","writing-draft","group-brief","moderation-advice"]'

连接 Oracle 时复制 .env.maintenance.example 为私有 .env.maintenance，并填写业务 schema 的连接配置。
先迁移 ai-skills 表，再查询当前代数。首次发布使用 0，后续使用查询到的代数。

    node --env-file=.env.maintenance scripts/ai-skill-config-maintenance.mjs --status --dotenv .env.maintenance
    node --env-file=.env.maintenance scripts/ai-skill-config-maintenance.mjs --publish --expected 0 --enabled-json '["knowledge-answer","writing-draft","group-brief","moderation-advice"]' --dotenv .env.maintenance

Skill 维护无需启动业务后端、Redis、Qdrant 或模型服务。索引更新账号的只读凭据不能用于发布。
`;

export async function packageKnowledgeIndex(output) {
  const oracle = dirname(createRequire(join(root, 'package.json')).resolve('oracledb'));
  await mkdir(output);
  for (const path of runtimeFiles) {
    const destination = join(output, path);
    await mkdir(dirname(destination), {recursive:true});
    await copyFile(join(root, path), destination);
  }
  await writeFile(join(output, '.env.maintenance.example'), [
    'NEKO_TERMS_PACKAGED=1',
    'ORACLE_HOST=127.0.0.1',
    'ORACLE_PORT=1521',
    'ORACLE_SERVICE_NAME=',
    'ORACLE_USER=',
    'ORACLE_PASSWORD=',
    '',
  ].join('\n'), {flag:'wx'});
  await cp(join(root, 'scripts/knowledge-index'), join(output, 'scripts/knowledge-index'), {recursive:true});
  await cp(oracle, join(output, 'node_modules/oracledb'), {recursive:true});
  await buildTermsMaintenanceBundle({outfile:join(output, '.output/server/ai-terms-maintenance.cjs')});
  for (const [name, source] of [
    ['retrieval', '.env.knowledge-index.example'],
    ['updater', '.env.knowledge-index-updater.example'],
  ]) {
    const sample = await readFile(join(root, source), 'utf8');
    const packaged = sample.replace(/^#.*\r?\n/, '').replace('host.docker.internal:6333', '127.0.0.1:6333');
    await writeFile(join(output, `.env.${name}.example`),
      `AI_INDEX_ACTIVE_PROFILE=profiles/active.json\nNEKO_TERMS_PACKAGED=1\n${packaged}`, {flag:'wx'});
  }
  await copyFile(join(root, 'specifications/requirements/ai-knowledge-index.md'), join(output, 'index-requirements.md'));
  await writeFile(join(output, 'index.mjs'), "process.env.NEKO_TERMS_PACKAGED = '1';\nawait import('./scripts/knowledge-index/cli.mjs');\n", {flag:'wx'});
  await writeFile(join(output, 'README.md'), readme, {flag:'wx'});
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [flag, output, ...rest] = process.argv.slice(2);
    if (flag !== '--out' || !output || output.startsWith('--') || rest.length) throw Error(usage);
    await packageKnowledgeIndex(resolve(output));
    console.info('Knowledge index tools packaged.');
  } catch (error) {
    console.error(error.code === 'EEXIST' ? 'Output directory already exists.' :
      error.message === usage ? usage : 'Could not package the knowledge index. Check the local build dependencies and paths.');
    process.exitCode = 1;
  }
}
