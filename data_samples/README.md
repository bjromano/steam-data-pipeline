# Sample data

Small snapshots of the gold layer, exported from Snowflake so the pipeline's
output is visible without running it. GitHub renders these CSVs as searchable
tables — click any file.

| File | Grain | What to notice |
|---|---|---|
| `sample_daily_game_performance.csv` | game × day | rank + concurrent players + same-day review sentiment in one row |
| `sample_dim_game.csv` | game | `has_store_page = FALSE` rows: games that chart in the top 100 but have no public store page — the dimension keeps them so facts always resolve |
| `sample_fact_review.csv` | review | event-grain fact; review *metadata* only (length, votes, playtime), not text |

Exported with [`export_queries.sql`](export_queries.sql). The pipeline
produces this data daily; these files are a point-in-time sample, not
refreshed automatically.
