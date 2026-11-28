# B1.1 独立服务器验收

请在独立测试服务器验收 Cthaat/NekoTribe 的 B1.1 搜索契约候选。目标是验证四个候选能否配套使用，以及 Oracle 迁移能否重复执行。本轮只测契约与迁移。使用 Ubuntu、Git、Bash、Node 22.6+（22.x）和 Yarn 1.22.22。使用全新临时目录，保留日志供回传。

先在同一个 Bash 会话运行以下命令。任一 PR 的实际 SHA 与清单不同，立即停止，回报 PR 号、期望和实际 SHA。不要改用最新分支继续。
```bash
set -eu
root=$(mktemp -d)
cd "$root"
printf '测试目录 %s\n' "$root"
node --version
yarn --version
repo=https://github.com/Cthaat/NekoTribe.git
while read -r dir pr expected; do
  git init -q "$dir"
  git -C "$dir" fetch -q --depth=1 "$repo" "refs/pull/$pr/head"
  actual=$(git -C "$dir" rev-parse FETCH_HEAD)
  printf '%s PR #%s 期望=%s 实际=%s\n' "$dir" "$pr" "$expected" "$actual"
  test "$actual" = "$expected"
  git -C "$dir" checkout -q --detach "$actual"
done <<'CANDIDATES'
nuxt 128 a4a28398a8a796671f767e106b0ebc08d9dce868
go 129 cf54c11d75d30d04ebe2ca1a72292a8c671b7da6
rust 130 eab8951edc901eb7480d7b695198fb93ce3932c1
flutter 131 d5953ee1c78e4051a0de4bf57d8547d543bb6815
CANDIDATES
cd nuxt
run_check() {
  local name=$1 rc=0
  shift
  "$@" >"$root/$name.log" 2>&1 || rc=$?
  printf '%s\t%s\n' "$name" "$rc" | tee -a "$root/results.tsv"
  return "$rc"
}
run_check install yarn install --frozen-lockfile
run_check contracts node scripts/contracts.mjs check --workspace-root .. || :
run_check parity node scripts/parity.mjs check --workspace-root .. || :
run_check schema-catalog yarn schema-catalog:check || :
run_check search-catalog node scripts/global-search-schema-catalog.mjs --check || :
run_check migration-plan node scripts/migrate-db.mjs --plan || :
run_check ai-terms yarn ai-terms:check || :
run_check typecheck yarn typecheck --dotenv .env.example || :
run_check targeted node --experimental-transform-types --test tests/contracts.test.mjs tests/schema-migrations.test.mjs || :
run_check suite yarn test || :
run_check lockfile git diff --exit-code HEAD -- package.json yarn.lock || :
cat "$root/results.tsv"
```
安装失败则报告首错，并将依赖该步骤的项目标为 BLOCKED。其余检查逐项取日志判断，四端 contracts/parity 应对应 230 个操作。migration-plan.log 中核对 64 项历史步骤的校验和与基线一致、3 项新增步骤。

在 Oracle 19c 和 23 Free 上分别使用隔离的一次性测试 schema，覆盖旧库升级，以及分别用 data/neko_tribe-oracle-v2.sql、data/nekotribe-schema-only.sql 初始化的两种快照路径。每条路径用独立 schema，通过服务器已有的测试连接配置选择目标，确认库版本、schema 身份后，在上述 nuxt 目录依次运行以下四条命令，每次单独记录退出码和脱敏日志。第一次 check 如有预期缺项，请记录后继续。apply 出现意外失败则停止该路径。
```bash
node scripts/migrate-db.mjs --check
node scripts/migrate-db.mjs --apply
node scripts/migrate-db.mjs --apply
node scripts/migrate-db.mjs --check
```
以迁移账本及数据字典验证 n_user_search_history、唯一索引 uk_search_history_term (user_id, normalized_query)、索引 idx_search_history_recent (user_id, updated_at DESC)。第二次 apply 应新增 0 条 DDL，最终 check 应通过。另用一个可丢弃的 schema 构造列序错误的同名索引，验证检查能识别 incompatible，记录实际诊断。缺 Oracle 版本、旧库样本或快照初始化条件时逐项标 BLOCKED，并继续其余可独立执行的项。连接信息留在服务器，回传前脱敏。

请回传四个实际 SHA、Node/Yarn/Oracle 版本，以及表格「检查或 schema 路径 | PASS/FAIL/BLOCKED | 退出码 | 首个实际错误或阻塞原因 | 证据」。附两种 Oracle 各路径的第二次 apply DDL 数、最终 check、索引列序和幂等性证据。分开列出通过、失败和未执行项。五个业务操作和 28 个跨端运行时场景留待实现提交再验收。
