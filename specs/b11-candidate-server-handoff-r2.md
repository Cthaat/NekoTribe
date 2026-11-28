# B1.1 独立服务器增量验收 · revision 2

请在独立测试服务器新建目录，用下列四个精确提交验收 B1.1 revision 2，单独出具回执。仓库为 Cthaat/NekoTribe。原轮已发给服务器的四个提交仍按原轮记录，新版运行和证据独立编号。

| 目录／原 PR | 本轮 SHA | 父提交／旧轮 SHA | 本轮差异 |
|---|---|---|---|
| nuxt [#128](https://github.com/Cthaat/NekoTribe/pull/128) | `da155665593b53aff05b3149261a8b7383f31e5a` | `a4a28398a8a796671f767e106b0ebc08d9dce868` | 共享需求、场景及 parity，+28/−14 |
| go [#129](https://github.com/Cthaat/NekoTribe/pull/129) | `36f074f21d154e35267b4a35f21bf5d1f0dddcfc` | `cf54c11d75d30d04ebe2ca1a72292a8c671b7da6` | 需求和场景副本，+19/−5 |
| rust [#130](https://github.com/Cthaat/NekoTribe/pull/130) | `26596e774a0c577d9f4da09fa059346ca7fc5ede` | `eab8951edc901eb7480d7b695198fb93ce3932c1` | 需求和场景副本，+19/−5 |
| flutter [#131](https://github.com/Cthaat/NekoTribe/pull/131) | `4b3755452ddaa25ede91ceaa80676616cf322e0b` | `d5953ee1c78e4051a0de4bf57d8547d543bb6815` | 需求和场景副本，+19/−5 |

## 现在执行

使用 Ubuntu、Git、Bash、Python 3、Node 22.x（22.6+）及 Yarn 1.22.22。以下命令在同一个 Bash 会话内执行。记录输出、退出码与工具版本。固定提交无法获取或父提交不符时，回报实际结果并停止这一组。

```bash
set -euo pipefail
root=$(mktemp -d)
cd "$root"
printf 'R2 验收目录 %s\n' "$root"
node --version
yarn --version
python3 --version
repo=https://github.com/Cthaat/NekoTribe.git
while read -r dir head parent; do
  git init -q "$dir"
  git -C "$dir" fetch -q --depth=2 "$repo" "$head"
  git -C "$dir" checkout -q --detach FETCH_HEAD
  test "$(git -C "$dir" rev-parse HEAD)" = "$head"
  test "$(git -C "$dir" rev-parse HEAD^)" = "$parent"
  git -C "$dir" diff --numstat HEAD^ HEAD
done <<'REVISIONS'
nuxt da155665593b53aff05b3149261a8b7383f31e5a a4a28398a8a796671f767e106b0ebc08d9dce868
go 36f074f21d154e35267b4a35f21bf5d1f0dddcfc cf54c11d75d30d04ebe2ca1a72292a8c671b7da6
rust 26596e774a0c577d9f4da09fa059346ca7fc5ede eab8951edc901eb7480d7b695198fb93ce3932c1
flutter 4b3755452ddaa25ede91ceaa80676616cf322e0b d5953ee1c78e4051a0de4bf57d8547d543bb6815
REVISIONS
cd nuxt
run_check() {
  local name=$1 rc=0
  shift
  "$@" >"$root/$name.log" 2>&1 || rc=$?
  printf '%s\t%s\n' "$name" "$rc" | tee -a "$root/results.tsv"
  return "$rc"
}
run_check contracts node scripts/contracts.mjs check --workspace-root .. || :
run_check parity node scripts/parity.mjs check --workspace-root .. || :
for dir in go rust flutter; do
  for item in requirements/global-search.md scenarios/global-search.json requirements/global-search-schema-catalog.json; do
    cmp "specifications/$item" "../$dir/contracts/$item"
  done
done
git diff --exit-code HEAD^ HEAD -- doc/ server/ data/ package.json yarn.lock specifications/requirements/global-search-schema-catalog.json
run_check search-catalog node scripts/global-search-schema-catalog.mjs --check || :
run_check plan node scripts/migrate-db.mjs --plan || :
```

验证原 28 个场景数据逐一保留、10 个新增场景登记、三枚公开游标按原始前段验签、两种窗口期望值与 member 重投。以下为独立参考计算。后端功能接入后的实际行为还需另测。

```bash
python3 - <<'PY'
import base64, hashlib, hmac, json, subprocess
from pathlib import Path
p = 'specifications/scenarios/global-search.json'
old = json.loads(subprocess.check_output(['git', 'show', 'HEAD^:' + p]))
new = json.loads(Path(p).read_bytes())
rows = {c['id']: c for c in new['cases']}
assert new['revision'] == 2 and new['id'] == 'GLOBAL-SEARCH-V2'
assert len(rows) == len(new['cases']) == 38 and len(old['cases']) == 28
assert all(rows[c['id']] == c for c in old['cases'])
added = set(rows) - {c['id'] for c in old['cases']}
assert added == {'cursor-golden-search','cursor-golden-history','cursor-golden-escaped',
                 'cursor-wrong-binding','cursor-server-pairs','cursor-key-config','trend-shared-retry',
                 'trend-window-ms','trend-source-recheck','history-readiness-shape'}
key = bytes(range(32))  # public fixture byte sequence
enc = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
for case in ('search','history','escaped'):
    g = rows['cursor-golden-' + case]['given']
    first, mac = g['token'].split('.')
    assert first == enc(g['payloadUtf8'].encode('utf-8'))
    assert hmac.compare_digest(mac, enc(hmac.digest(key, first.encode('ascii'), hashlib.sha256)))
assert json.loads(rows['cursor-golden-escaped']['given']['payloadUtf8']) == json.loads(rows['cursor-golden-search']['given']['payloadUtf8'])
assert rows['cursor-golden-escaped']['given']['token'] != rows['cursor-golden-search']['given']['token']
c = rows['trend-window-ms']
for duration, field in [(86400000,'includedOffsets24h'),(604800000,'includedOffsets7d')]:
    assert [v for v in c['given']['offsetMs'] if -duration < v <= 0] == c['expect'][field]
c = rows['trend-shared-retry']
a, b = c['given']['members']
assert len({a, b, a}) == 2 and json.loads(a)[1:] == json.loads(b)[1:]
print('R2 reference vectors PASS: 28 retained, 10 added, 3 signatures verified')
PY
if run_check install yarn install --frozen-lockfile; then
  run_check schema-catalog yarn schema-catalog:check || :
  run_check typecheck yarn typecheck --dotenv .env.example || :
  run_check targeted node --experimental-transform-types --test tests/contracts.test.mjs tests/schema-migrations.test.mjs || :
  run_check suite yarn test || :
fi
cat "$root/results.tsv"
```

四端 contracts、parity 应分别覆盖 230 个操作。离线计划应为 67 步（原 64 步及 B1.1 三步）。增量 diff 应仅有表列出的 3/2/2/2 个文件。记录本轮真实输出；依赖安装失败时，依赖该安装的项目记 BLOCKED，其他项目继续。

## 独立 Oracle 就绪增量

分别在 Oracle 19c、23 Free 的可丢弃测试 schema 上使用本轮 Nuxt 精确 SHA。确认目标 schema 身份后用既有显式迁移创建正确结构，执行 `node scripts/migrate-db.mjs --check`，记录正确外键指向 N_USERS.USER_ID 且 ON DELETE CASCADE、唯一索引 (USER_ID,NORMALIZED_QUERY)、第二索引 (USER_ID,UPDATED_AT DESC) 的字典证据。记录 Oracle 以 SYS_NC 隐藏列表示降序时的真实表达式。随后为 history-readiness-shape 各错误变体逐项创建隔离样本，每次只变一项，重跑只读 check，记录 incompatible、退出码和检查阶段 DDL 数 0。旧轮的升级、双快照和双 apply 回执继续单列。测试 schema 或 Oracle 版本不可用时记录具体阻塞条件。

## 后端实现提交到位后执行

- 游标。三端使用同一个测试配置 SEARCH_CURSOR_KEY_B64URL，值取上方 32 字节公开序列的无填充 base64url。分别消费三枚固定 token；错密钥、错绑定、改末键沿用原 MAC 均应为 400 且零副作用。search 和 history 各验六组跨端签发/消费。验证开启搜索时对错误配置显式报错，以及关闭搜索且无 key 的既有部署能启动。
- 热度。三端共用一份隔离 Redis，检验 v1 ZSET 键、整数 Redis 毫秒 score 和四字段 member。在可控时钟或固定事件数据下轮换三端，重投原事件仍为一条，同毫秒两次独立成功首屏共计两条。验证 cutoff、cutoff+1ms、now、now+1ms，先读 24h 再读 7d，再分别改变公开状态、来源文本、调用者可见性核对结果。
- 就绪。三端分别按有效/错误外键与索引变体验证已登录首屏搜索、本人历史 GET/DELETE。预期正确结构 200，错误结构脱敏 503/50301，请求 DDL 为 0。Flutter 验共享副本与游标原样传递。

请按「提交／端／用例／PASS、FAIL、BLOCKED 或待实现／退出码／首个实际错误／脱敏日志位置」回传，附四个实际 SHA、工具及 Oracle 版本。当前契约轮、Oracle 实库轮和后续实现运行时各自出具结果。
