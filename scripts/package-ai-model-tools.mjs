import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  'scripts/ai-model-config.mjs',
  'scripts/knowledge-index/http.mjs',
  'server/services/ai/inference-transport.ts',
  'server/services/ai/knowledge-citations.ts',
  'server/services/ai/model-configuration.ts',
  'server/services/ai/model-source.ts',
  'specifications/requirements/ai-group-draft.json',
  'specifications/requirements/ai-vision.json',
];
const usage = 'Usage: node scripts/package-ai-model-tools.mjs --out NEW_DIRECTORY';
const readme = `# NekoTribe AI 模型维护工具

在 Windows 或 Linux 上使用 Node.js 22.12 或更高的 Node.js 22 版本。
复制 model.example.json 为 candidate.json，填写实际模型名、端点及能力。
需要凭据的服务在提供方配置中填写 apiKeyEnv，再由环境变量注入凭据。
配置中的同名字段和无效 Unicode 转义会被拒绝。

从本目录运行下列命令。示例中的 model.json 为三个后端通过 AI_MODEL_CONFIG_FILE 读取的配置文件。

    node --experimental-strip-types scripts/ai-model-config.mjs check candidate.json
    node --experimental-strip-types scripts/ai-model-config.mjs probe candidate.json
    node --experimental-strip-types scripts/ai-model-config.mjs probe candidate.json --roles knowledge,writing
    node --experimental-strip-types scripts/ai-model-config.mjs publish-checked candidate.json model.json 0
    node --experimental-strip-types scripts/ai-model-config.mjs list model.json
    node --experimental-strip-types scripts/ai-model-config.mjs diff model.json candidate.json
    node --experimental-strip-types scripts/ai-model-config.mjs bind-checked model.json 1 knowledge second-profile writing second-profile
    node --experimental-strip-types scripts/ai-model-config.mjs rollback-last-checked model.json 2
    node --experimental-strip-types scripts/ai-model-config.mjs rollback-checked model.json.history/1.json model.json 3

首次发布的预期版本为 0。后续操作使用 list 显示的当前版本。
可用角色为 knowledge、writing、agent 和 moderation。切换前先在配置里登记目标模型。一次传入多组角色和模型配置 ID 时，工具会探测有变更的角色，并在全部通过后一次发布。
diff 离线比较四个用途实际选中的配置，只报告配置版本、模型配置 ID 和变化字段名。
容器通过只读目录挂载读取同一配置。模型重新绑定后可用 verify-active 核对各实例的版本。在目标地址之后加 --wait-ms 5000，可等待所有实例加载同一版本。
加 --require-ready knowledge,writing,agent,moderation 可同时要求指定用途的推理配置已就绪。使用 NEKO_AI_STATUS_TOKEN 环境变量提供各实例接受的登录令牌。状态检查不调用模型，真实推理由 probe 验证。
probe 使用固定合成资料检查知识引用、群运营带检索词的工具调用与续写、写作和审核输出。
单独执行 probe 时可用 --roles 指定用途。publish-checked 对候选配置执行全部四项探测。
带探测的回退在四个用途均通过验证后发布。rollback-last-checked 恢复最近的归档，rollback-checked 可指定任意一份较旧的配置文件。离线回退使用 rollback-last 或 rollback。
`;

export async function packageAiModelTools(output) {
  await mkdir(output);
  for (const path of files) {
    const destination = join(output, path);
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(join(root, path), destination);
  }
  await copyFile(join(root, 'scripts/ai-model-config.example.json'), join(output, 'model.example.json'));
  await writeFile(join(output, 'README.md'), readme, { flag: 'wx' });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [flag, output, ...rest] = process.argv.slice(2);
    if (flag !== '--out' || !output || output.startsWith('--') || rest.length) throw Error(usage);
    await packageAiModelTools(resolve(output));
    console.info('AI model maintenance tools packaged.');
  } catch (error) {
    console.error(error.code === 'EEXIST' ? 'Output directory already exists.' :
      error.code ? 'Could not create the AI model maintenance bundle.' : error.message);
    process.exitCode = 1;
  }
}
