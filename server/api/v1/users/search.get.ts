export default defineEventHandler(async event => {
  // 获取 query 参数
  const query = getQuery(event);

  // 提取参数
  const q = (query.q as string) || '';
  const page = parseInt(query.page as string, 10) || 1;
  const pageSize = parseInt(query.pageSize as string, 10) || 10;

  console.log('Search Parameters:', { q, page, pageSize });
});
