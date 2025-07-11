// ========================== trending.get ======================================

// 热门话题数据类型
interface TrendingHashtag {
  hashtag_id: number;
  tag_name: string;
  usage_count: number;
  trending_score: number;
}

type TrendingHashtagsDataRow = [
  number, // hashtag_id
  string, // tag_name
  number, // usage_count
  number // trending_score
];

// 热门话题响应数据类型
interface TrendingHashtagsData {
  trending_hashtags: TrendingHashtag[];
  updated_at: string;
}

// 热门话题成功响应类型
interface TrendingHashtagsSuccessResponse {
  success: true;
  message: string;
  data: TrendingHashtagsData;
  code: 200;
}

// 热门话题错误响应类型
interface TrendingHashtagsErrorResponse {
  success: false;
  message: string;
  code: number;
}

// 热门话题API响应联合类型
type TrendingHashtagsResponse =
  | TrendingHashtagsSuccessResponse
  | TrendingHashtagsErrorResponse;
