/**
 * @fileoverview 自动更新README.md版本号脚本
 * @description 支持多服务版本管理，从环境变量或配置文件读取版本号，自动更新README.md中的版本徽章
 * @version 2.0.0
 * @date 2025-07-01
 * @author Cthaat
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// 获取当前文件的目录路径（ES Module 中需要手动处理）
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * 从环境变量获取服务名和版本号（GitHub Actions调用时）
 * @returns {Object} {serviceName, version}
 */
function getVersionFromEnv() {
  const serviceName = process.env.SERVICE_NAME;
  const version = process.env.VERSION;

  if (serviceName && version) {
    return { serviceName, version };
  }

  return null;
}

/**
 * 从配置文件中获取版本信息（本地开发时的备用方案）
 * @returns {Object} {serviceName, version}
 */
function getVersionFromConfig() {
  try {
    // 尝试从 .env 文件读取
    const envPath = path.join(__dirname, '..', '.env');
    if (fs.existsSync(envPath)) {
      const envContent = fs.readFileSync(envPath, 'utf8');
      const versionMatch = envContent.match(/version:\s*['"]([^'"]+)['"]/);
      if (versionMatch && versionMatch[1]) {
        return { serviceName: 'nekotribe', version: versionMatch[1] };
      }
    }

    // 尝试从服务版本配置文件读取最新版本
    const versionsDir = path.join(__dirname, '..', 'config', 'versions');
    if (fs.existsSync(versionsDir)) {
      const files = fs.readdirSync(versionsDir)
        .filter(file => file.endsWith('.json') && file !== 'example-service.json');

      if (files.length > 0) {
        // 读取最新修改的版本文件
        const latestFile = files
          .map(file => ({
            name: file,
            path: path.join(versionsDir, file),
            mtime: fs.statSync(path.join(versionsDir, file)).mtime
          }))
          .sort((a, b) => b.mtime - a.mtime)[0];

        const versionConfig = JSON.parse(fs.readFileSync(latestFile.path, 'utf8'));
        return {
          serviceName: versionConfig.serviceName,
          version: versionConfig.version
        };
      }
    }

    // 默认版本
    return { serviceName: 'nekotribe', version: '1.0.0' };
  } catch (error) {
    console.error('读取版本配置文件失败:', error.message);
    return { serviceName: 'nekotribe', version: '1.0.0' };
  }
}

/**
 * 更新README.md文件中的版本徽章和数据库徽章
 * @param {string} serviceName 服务名称
 * @param {string} newVersion 新版本号
 */
function updateReadmeVersion(serviceName, newVersion) {
  try {
    const readmePath = path.join(__dirname, '..', 'README.md');
    let readmeContent = fs.readFileSync(readmePath, 'utf8');
    let hasChanges = false;

    console.log(`🔄 开始更新徽章 - 服务: ${serviceName}, 版本: v${newVersion}`);

    // 1. 更新或创建版本号徽章
    const versionBadgePattern = /!\[版本\]\(https:\/\/img\.shields\.io\/badge\/版本-v[^-]+-blue\.svg\)/;
    const newVersionBadge = `![版本](https://img.shields.io/badge/版本-v${newVersion}-blue.svg)`;

    if (versionBadgePattern.test(readmeContent)) {
      // 更新现有版本徽章
      const updatedContent = readmeContent.replace(versionBadgePattern, newVersionBadge);
      if (updatedContent !== readmeContent) {
        readmeContent = updatedContent;
        hasChanges = true;
        console.log(`✅ 更新版本徽章: v${newVersion}`);
      }
    } else {
      // 创建新的版本徽章 - 在README开头添加
      const titleMatch = readmeContent.match(/^(# NekoTribe[^\n]*\n)/);
      if (titleMatch) {
        const insertPosition = titleMatch[0].length;
        readmeContent = readmeContent.slice(0, insertPosition) +
          `\n${newVersionBadge}\n` +
          readmeContent.slice(insertPosition);
        hasChanges = true;
        console.log(`✅ 创建版本徽章: v${newVersion}`);
      }
    }

    // 2. 更新或创建数据库徽章
    // 2. 更新或创建数据库徽章
    const databaseBadgePattern = /!\[数据库\]\(https:\/\/img\.shields\.io\/badge\/数据库-[^-]+-green\.svg\)/;
    const newDatabaseBadge = `![数据库](https://img.shields.io/badge/数据库-${serviceName}-green.svg)`;

    if (databaseBadgePattern.test(readmeContent)) {
      // 更新现有数据库徽章
      const updatedContent = readmeContent.replace(databaseBadgePattern, newDatabaseBadge);
      if (updatedContent !== readmeContent) {
        readmeContent = updatedContent;
        hasChanges = true;
        console.log(`✅ 更新数据库徽章: ${serviceName}`);
      }
    } else {
      // 创建新的数据库徽章 - 在版本徽章后添加
      if (readmeContent.includes(newVersionBadge)) {
        // 在版本徽章后添加数据库徽章
        readmeContent = readmeContent.replace(newVersionBadge, `${newVersionBadge}\n${newDatabaseBadge}`);
        hasChanges = true;
        console.log(`✅ 创建数据库徽章: ${serviceName}`);
      } else {
        // 如果没有版本徽章，在标题后添加
        const titleMatch = readmeContent.match(/^(# NekoTribe[^\n]*\n)/);
        if (titleMatch) {
          const insertPosition = titleMatch[0].length;
          readmeContent = readmeContent.slice(0, insertPosition) +
            `\n${newDatabaseBadge}\n` +
            readmeContent.slice(insertPosition);
          hasChanges = true;
          console.log(`✅ 创建数据库徽章: ${serviceName}`);
        }
      }
    }

    // 检查是否有更改需要保存
    if (!hasChanges) {
      console.warn('⚠️  未找到需要更新的徽章或信息未发生变化');
      return false;
    }

    // 写入更新后的内容
    fs.writeFileSync(readmePath, readmeContent, 'utf8');
    console.log(`🎉 README.md徽章更新完成！`);
    console.log(`📌 版本徽章: v${newVersion}`);
    console.log(`🗄️ 数据库徽章: ${serviceName}`);
    return true;

  } catch (error) {
    console.error('❌ 更新README.md失败:', error.message);
    process.exit(1);
  }
}

/**
 * 主函数：获取版本信息并更新README.md
 */
function main() {
  try {
    console.log('🚀 开始更新README.md版本信息...');

    // 首先尝试从环境变量获取版本信息（GitHub Actions优先）
    let versionInfo = getVersionFromEnv();

    // 如果环境变量不存在，从配置文件读取
    if (!versionInfo) {
      console.log('📁 从配置文件读取版本信息...');
      versionInfo = getVersionFromConfig();
    }

    if (!versionInfo) {
      console.error('❌ 无法获取版本信息');
      process.exit(1);
    }

    console.log(`📋 获取到版本信息: 服务=${versionInfo.serviceName}, 版本=${versionInfo.version}`);

    // 更新README.md
    const success = updateReadmeVersion(versionInfo.serviceName, versionInfo.version);

    if (success) {
      console.log('🎉 README.md更新完成！');
    } else {
      console.log('⚠️ README.md未发生变化');
    }

  } catch (error) {
    console.error('❌ 更新过程中发生错误:', error.message);
    process.exit(1);
  }
}

// 如果直接运行此脚本
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export {
  getVersionFromEnv,
  getVersionFromConfig,
  updateReadmeVersion,
  main
};