import { copyFileSync, mkdirSync, existsSync } from 'fs';
import { resolve } from 'path';

// 定义源路径和目标路径
const sourcePath = resolve(process.cwd(), '.data/db.sqlite3');
const targetDir = resolve(process.cwd(), '.output/.data');
const targetPath = resolve(targetDir, 'db.sqlite3');

console.log('Build process finished. Running build:after hook.');

// 输出路径
console.log('Source Path:', sourcePath);
console.log('Target Directory:', targetDir);
console.log('Target Path:', targetPath);

// 检查源文件是否存在
if (!existsSync(sourcePath)) {
  console.error('Source file does not exist:', sourcePath);
  process.exit(1);
}

// 如果目标目录不存在，则创建它
if (!existsSync(targetDir)) {
  mkdirSync(targetDir, { recursive: true });
}

// 复制文件
try {
  copyFileSync(sourcePath, targetPath);
  console.log('Database file copied successfully.');
} catch (error) {
  console.error('Error copying file:', error);
  process.exit(1);
}
