// ========================== like.post ======================================

interface LikePayload {
  tweetId: string;
  likeType: 'like' | 'unlike';
}

// ========================== bookmark.post ======================================

interface BookmarkPayload {
  tweetId: string;
  bookmarkType: 'mark' | 'unmark';
}
