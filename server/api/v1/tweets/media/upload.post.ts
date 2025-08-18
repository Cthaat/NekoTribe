import formidable from 'formidable';
import fs from 'fs';
import path from 'path';
import { checkMediaFile } from '~/server/utils/media/upload-media-check';

// 处理媒体文件上传的接口
export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  // 获取 Oracle 数据库连接
  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  // 确保临时目录存在
  const tempDir = path.join(process.cwd(), 'temp');
  await fs.promises.mkdir(tempDir, { recursive: true });

  // 创建 formidable 实例，配置上传参数
  const form = formidable({
    multiples: true, // 允许多文件上传
    uploadDir: tempDir, // 临时上传目录
    keepExtensions: true, // 保留原始扩展名
    maxFileSize: 500 * 1024 * 1024, // 500MB 最大文件大小
    createDirsFromUploads: true, // 自动创建目录
    hashAlgorithm: false, // 禁用哈希算法，避免文件名变化
    filename: (name, ext, part) => {
      // 自定义文件名生成，避免特殊字符
      const timestamp = Date.now();
      const random = Math.floor(Math.random() * 10000);
      return `upload_${timestamp}_${random}${ext}`;
    }
  });

  // 返回 Promise 处理异步上传
  return new Promise((resolve, reject) => {
    form.parse(event.req, async (err, fields, files) => {
      let uploadedFiles = [];

      try {
        // 解析出错
        if (err) {
          console.error('Formidable 解析错误:', err);
          return reject(
            createError({
              statusCode: 400,
              statusMessage: 'Bad Request',
              data: {
                success: false,
                message: '上传文件解析失败: ' + err.message,
                code: 400,
                timestamp: new Date().toISOString()
              } as ErrorResponse
            })
          );
        }

        // 获取参数
        const tweetId = Array.isArray(fields.tweetId)
          ? fields.tweetId[0]
          : fields.tweetId;
        const altText = Array.isArray(fields.altText)
          ? fields.altText[0]
          : fields.altText;
        const description = Array.isArray(
          fields.description
        )
          ? fields.description[0]
          : fields.description;

        console.log('接收到的参数:', {
          tweetId,
          altText,
          description
        });
        console.log('接收到的文件:', files);

        // 检查必需参数
        if (!tweetId) {
          return reject(
            createError({
              statusCode: 400,
              statusMessage: 'Bad Request',
              data: {
                success: false,
                message: 'tweetId 参数是必需的',
                code: 400,
                timestamp: new Date().toISOString()
              } as ErrorResponse
            })
          );
        }

        const checkSql = `
          SELECT COUNT(*) AS count
          FROM n_tweets
          WHERE tweet_id = :tweetId AND author_id = :userId
        `;

        const checkCount = await connection.execute(
          checkSql,
          {
            userId: user.userId,
            tweetId: tweetId
          }
        );

        // 提取总数
        const totalCount: number = checkCount
          .rows[0][0] as number;

        if (totalCount === 0) {
          throw createError({
            statusCode: 400,
            message: '无权上传媒体',
            data: {
              success: false,
              message: '无权上传媒体',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          });
        }

        // 检查文件数量
        const mediaFiles = files.file;
        if (
          !mediaFiles ||
          (Array.isArray(mediaFiles) &&
            mediaFiles.length === 0)
        ) {
          return reject(
            createError({
              statusCode: 400,
              statusMessage: 'Bad Request',
              data: {
                success: false,
                message: '上传文件为空',
                code: 400,
                timestamp: new Date().toISOString()
              } as ErrorResponse
            })
          );
        }

        // 确保上传目录存在
        const uploadDir = path.join(
          process.cwd(),
          'upload',
          'media',
          tweetId.toString()
        );
        await fs.promises.mkdir(uploadDir, {
          recursive: true
        });

        // 确保缩略图目录存在
        const thumbnailDir = path.join(
          uploadDir,
          'thumbnails'
        );
        await fs.promises.mkdir(thumbnailDir, {
          recursive: true
        });

        // 处理单个文件或多个文件
        const filesToProcess = Array.isArray(mediaFiles)
          ? mediaFiles
          : [mediaFiles];

        console.log(
          '待处理文件数量:',
          filesToProcess.length
        );

        // 逐个处理文件
        for (let i = 0; i < filesToProcess.length; i++) {
          const file = filesToProcess[i];
          console.log(`处理文件 ${i + 1}:`, {
            originalFilename: file.originalFilename,
            filepath: file.filepath,
            size: file.size,
            mimetype: file.mimetype
          });

          // 检查文件是否存在
          try {
            await fs.promises.access(
              file.filepath,
              fs.constants.F_OK
            );
          } catch (accessError) {
            console.error(
              `文件不存在: ${file.filepath}`,
              accessError
            );
            // 清理已上传的文件
            for (const uploadedFile of uploadedFiles) {
              try {
                await fs.promises.unlink(
                  uploadedFile.fullPath
                );
              } catch (e) {
                console.error('清理文件失败:', e);
              }
            }
            return reject(
              createError({
                statusCode: 400,
                statusMessage: 'Bad Request',
                data: {
                  success: false,
                  message: `临时文件不存在: ${file.originalFilename}`,
                  code: 400,
                  timestamp: new Date().toISOString()
                } as ErrorResponse
              })
            );
          }

          // 调用工具函数进行校验并获取媒体信息
          const check = await checkMediaFile(file, {
            generateThumbnail: true,
            thumbnailDir: thumbnailDir,
            tweetId: tweetId
          });

          if (!check.valid) {
            console.log('文件校验失败:', check.message);
            // 不合规，删除临时文件
            try {
              await fs.promises.unlink(file.filepath);
            } catch (e) {
              console.error('删除临时文件失败:', e);
            }
            // 清理已上传的文件
            for (const uploadedFile of uploadedFiles) {
              try {
                await fs.promises.unlink(
                  uploadedFile.fullPath
                );
              } catch (e) {
                console.error('清理文件失败:', e);
              }
            }
            return reject(
              createError({
                statusCode: 400,
                statusMessage: 'Bad Request',
                data: {
                  success: false,
                  message:
                    '上传文件不符合要求: ' + check.message,
                  code: 400,
                  timestamp: new Date().toISOString()
                } as ErrorResponse
              })
            );
          }

          // 获取原始扩展名
          const ext = path.extname(
            file.originalFilename || file.filepath
          );
          // 生成唯一文件名
          const uniqueName = `${tweetId}_${Date.now()}_${Math.floor(Math.random() * 10000)}${ext}`;
          // 新文件完整路径
          const newFilePath = path.join(
            uploadDir,
            uniqueName
          );

          try {
            // 移动文件到目标目录
            await fs.promises.rename(
              file.filepath,
              newFilePath
            );
            console.log(
              `文件移动成功: ${file.filepath} -> ${newFilePath}`
            );

            // 记录上传成功的文件信息
            uploadedFiles.push({
              originalName: file.originalFilename,
              uniqueName: uniqueName,
              fullPath: newFilePath,
              relativePath: `/upload/media/${tweetId}/${uniqueName}`,
              size: file.size,
              mimeType: file.mimetype,
              mediaType: check.fileType, // 从工具函数获取媒体类型
              width: check.width, // 从工具函数获取宽度
              height: check.height, // 从工具函数获取高度
              duration: check.duration, // 从工具函数获取时长
              thumbnailPath: check.thumbnailPath // 从工具函数获取缩略图路径
            });
          } catch (moveError: any) {
            console.error('文件移动失败:', moveError);
            // 清理已上传的文件
            for (const uploadedFile of uploadedFiles) {
              try {
                await fs.promises.unlink(
                  uploadedFile.fullPath
                );
              } catch (e) {
                console.error('清理文件失败:', e);
              }
            }
            return reject(
              createError({
                statusCode: 500,
                statusMessage: 'Internal Server Error',
                data: {
                  success: false,
                  message:
                    '媒体文件保存失败: ' +
                    moveError.message,
                  code: 500,
                  timestamp: new Date().toISOString()
                } as ErrorResponse
              })
            );
          }
        }

        // 将文件信息存储到数据库
        try {
          for (const fileInfo of uploadedFiles) {
            const insertSql = `
              INSERT INTO n_media (
                tweet_id, user_id, media_type, file_name, file_path, file_size, 
                mime_type, width, height, duration, thumbnail_path, alt_text, is_processed, created_at
              ) VALUES (
                :tweetId, :userId, :mediaType, :fileName, :filePath, :fileSize,
                :mimeType, :width, :height, :duration, :thumbnailPath, :altText, :isProcessed, CURRENT_TIMESTAMP
              )
            `;

            await connection.execute(
              insertSql,
              {
                tweetId: tweetId,
                userId: user.userId,
                mediaType: fileInfo.mediaType,
                fileName: fileInfo.originalName,
                filePath: fileInfo.relativePath,
                fileSize: fileInfo.size,
                mimeType: fileInfo.mimeType,
                width: fileInfo.width || null,
                height: fileInfo.height || null,
                duration: fileInfo.duration || null,
                thumbnailPath:
                  fileInfo.thumbnailPath || null,
                altText: altText || null,
                isProcessed:
                  fileInfo.width ||
                  fileInfo.height ||
                  fileInfo.duration ||
                  fileInfo.thumbnailPath
                    ? 1
                    : 0
              },
              { autoCommit: false }
            );
          }

          // 提交事务
          await connection.commit();
          console.log('数据库操作成功，文件上传完成');

          // 返回成功响应
          resolve({
            code: 200,
            success: true,
            message: `成功上传 ${uploadedFiles.length} 个媒体文件`,
            data: {
              tweetId: tweetId,
              uploadedFiles: uploadedFiles.map(file => ({
                fileName: file.uniqueName,
                originalName: file.originalName,
                url: file.relativePath,
                size: file.size,
                mimeType: file.mimeType,
                mediaType: file.mediaType,
                width: file.width,
                height: file.height,
                duration: file.duration,
                thumbnailPath: file.thumbnailPath
              })),
              altText: altText,
              description: description
            },
            timestamp: new Date().toISOString()
          } as SuccessUploadResponse);
        } catch (dbError: any) {
          console.error('数据库操作失败:', dbError);
          // 回滚事务
          await connection.rollback();

          // 数据库操作失败，清理已上传的文件和缩略图
          for (const uploadedFile of uploadedFiles) {
            try {
              await fs.promises.unlink(
                uploadedFile.fullPath
              );
              // 如果有缩略图，也要删除
              if (uploadedFile.thumbnailPath) {
                const thumbnailFullPath = path.join(
                  process.cwd(),
                  'upload',
                  uploadedFile.thumbnailPath
                );
                await fs.promises.unlink(thumbnailFullPath);
              }
            } catch (e) {
              console.error('清理文件失败:', e);
            }
          }

          return reject(
            createError({
              statusCode: 500,
              statusMessage: 'Internal Server Error',
              data: {
                success: false,
                message:
                  '数据库操作失败: ' + dbError.message,
                code: 500,
                timestamp: new Date().toISOString()
              } as ErrorResponse
            })
          );
        }
      } catch (error: any) {
        console.error('文件上传处理失败:', error);
        // 处理其他错误，清理已上传的文件
        for (const uploadedFile of uploadedFiles) {
          try {
            await fs.promises.unlink(uploadedFile.fullPath);
            // 如果有缩略图，也要删除
            if (uploadedFile.thumbnailPath) {
              const thumbnailFullPath = path.join(
                process.cwd(),
                'upload',
                uploadedFile.thumbnailPath
              );
              await fs.promises.unlink(thumbnailFullPath);
            }
          } catch (e) {
            console.error('清理文件失败:', e);
          }
        }

        return reject(
          createError({
            statusCode: 500,
            statusMessage: 'Internal Server Error',
            data: {
              success: false,
              message: '文件上传处理失败: ' + error.message,
              code: 500,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      } finally {
        // 关闭数据库连接
        if (connection) {
          await connection.close();
        }
      }
    });
  });
});
