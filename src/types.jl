"""Core enumerations used by Graphiti."""

@enum EpisodeType MESSAGE TEXT JSON_DATA
@enum SearchMethod COSINE_SIMILARITY BM25_SEARCH BFS_SEARCH
@enum RerankerMethod RRF MMR NODE_DISTANCE EPISODE_MENTIONS CROSS_ENCODER
