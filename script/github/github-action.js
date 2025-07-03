#!/usr/bin/env node

import { execSync } from 'child_process';
import readline from 'readline';

// 创建命令行接口
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

/**
 * 执行 shell 命令
 * @param {string} command 要执行的命令
 * @param {boolean} silent 是否静默执行
 * @returns {string} 命令输出
 */
function execCommand(command, silent = false) {
  try {
    const result = execSync(command, {
      encoding: 'utf8',
      stdio: silent ? 'pipe' : 'inherit'
    });
    return result;
  } catch (error) {
    console.error(`❌ 执行命令失败: ${command}`);
    console.error(error.message);
    process.exit(1);
  }
}

/**
 * 询问用户输入
 * @param {string} question 问题
 * @returns {Promise<string>} 用户输入
 */
function askQuestion(question) {
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      resolve(answer.trim());
    });
  });
}

/**
 * 验证标签格式
 * @param {string} tag 标签名
 * @returns {boolean} 是否有效
 */
function isValidTag(tag) {
  // 支持格式: service-name/v1.0.0 或 service-name/v1.0.0-beta.1
  const pattern = /^[a-zA-Z0-9\-_]+\/v\d+\.\d+\.\d+(-[a-zA-Z0-9\-_.]+)?$/;
  return pattern.test(tag);
}

/**
 * 检查标签是否已存在
 * @param {string} tag 标签名
 * @returns {boolean} 标签是否存在
 */
function tagExists(tag) {
  try {
    execCommand(`git tag -l "${tag}"`, true);
    const result = execSync(`git tag -l "${tag}"`, { encoding: 'utf8' });
    return result.trim() !== '';
  } catch (error) {
    return false;
  }
}

/**
 * 获取当前分支名
 * @returns {string} 分支名
 */
function getCurrentBranch() {
  try {
    const result = execSync('git branch --show-current', { encoding: 'utf8' });
    return result.trim();
  } catch (error) {
    console.error('❌ 无法获取当前分支名');
    process.exit(1);
  }
}

/**
 * 检查工作区是否干净
 * @returns {boolean} 工作区是否干净
 */
function isWorkingDirectoryClean() {
  try {
    const result = execSync('git status --porcelain', { encoding: 'utf8' });
    return result.trim() === '';
  } catch (error) {
    return false;
  }
}

/**
 * 主函数
 */
async function main() {
  console.log('🚀 GitHub Action 标签自动化脚本');
  console.log('========================================');

  // 检查是否在 git 仓库中
  try {
    execCommand('git rev-parse --git-dir', true);
  } catch (error) {
    console.error('❌ 当前目录不是 Git 仓库');
    process.exit(1);
  }

  // 检查工作区状态
  if (!isWorkingDirectoryClean()) {
    console.log('⚠️  工作区有未提交的更改');
    const answer = await askQuestion('是否继续? (y/N): ');
    if (answer.toLowerCase() !== 'y') {
      console.log('操作已取消');
      process.exit(0);
    }
  }

  // 获取当前分支
  const currentBranch = getCurrentBranch();
  console.log(`📌 当前分支: ${currentBranch}`);

  // 询问标签名
  console.log('\n📝 请输入标签名');
  console.log('格式示例: service-name/v1.0.0 或 service-name/v1.0.0-beta.1');

  let tagName;
  while (true) {
    tagName = await askQuestion('标签名: ');

    if (!tagName) {
      console.log('❌ 标签名不能为空');
      continue;
    }

    if (!isValidTag(tagName)) {
      console.log('❌ 标签格式无效，请使用格式: service-name/v1.0.0');
      continue;
    }

    if (tagExists(tagName)) {
      console.log('❌ 标签已存在');
      const overwrite = await askQuestion('是否覆盖现有标签? (y/N): ');
      if (overwrite.toLowerCase() === 'y') {
        console.log('🗑️  删除现有标签...');
        execCommand(`git tag -d "${tagName}"`);
        execCommand(`git push origin --delete "${tagName}" || true`);
        break;
      }
      continue;
    }

    break;
  }

  // 询问标签描述
  const tagMessage = await askQuestion('标签描述 (可选): ');

  console.log('\n📋 标签信息确认:');
  console.log(`   标签名: ${tagName}`);
  console.log(`   当前分支: ${currentBranch}`);
  console.log(`   描述: ${tagMessage || '无'}`);

  const confirm = await askQuestion('\n确认创建并推送标签? (y/N): ');
  if (confirm.toLowerCase() !== 'y') {
    console.log('操作已取消');
    rl.close();
    process.exit(0);
  }

  try {
    console.log('\n🏷️  创建标签...');

    // 创建标签
    if (tagMessage) {
      execCommand(`git tag -a "${tagName}" -m "${tagMessage}"`);
    } else {
      execCommand(`git tag "${tagName}"`);
    }

    console.log('✅ 标签创建成功');

    // 推送标签
    console.log('📤 推送标签到远程仓库...');
    execCommand(`git push origin "${tagName}"`);

    console.log('✅ 标签推送成功');

    // 提取服务名
    const serviceName = tagName.split('/')[0];
    console.log(`\n🎉 成功创建并推送标签: ${tagName}`);
    console.log(`📌 服务名: ${serviceName}`);
    console.log(`🔄 GitHub Action 工作流将自动触发`);
    console.log(`📝 版本更新将提交到当前分支: ${currentBranch}`);

    // 显示后续操作
    console.log('\n📊 后续自动化操作:');
    console.log('1. ✅ GitHub Action 工作流触发');
    console.log('2. ✅ 更新服务版本配置文件');
    console.log('3. ✅ 更新 README.md 版本徽章');
    console.log(`4. ✅ 提交更改到 ${currentBranch} 分支`);
    console.log('5. ✅ 创建 GitHub Release');

  } catch (error) {
    console.error('❌ 操作失败:', error.message);
    process.exit(1);
  }

  rl.close();
}

// 处理程序退出
process.on('SIGINT', () => {
  console.log('\n\n操作已取消');
  rl.close();
  process.exit(0);
});

// 运行主函数
main().catch((error) => {
  console.error('❌ 程序执行失败:', error);
  rl.close();
  process.exit(1);
});