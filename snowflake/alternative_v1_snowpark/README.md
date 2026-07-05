# Alternative architecture (not deployed): all-in-Snowflake orchestration

These scripts implement the same pipeline with zero AWS compute: a Snowpark
Python stored procedure extracts from the Steam API (via an external access
integration), writes to S3 through the stage, and a Snowflake Task DAG
schedules extract → COPY → transform.

Built and tested, then retired in favor of the Lambda + Snowpipe design for a
structural cost reason: extraction is ~80% rate-limit sleeps, and a warehouse
bills for every second it sits awake waiting on the network (~$20/month here vs
~$0 on Lambda's free tier). Warehouse compute is priced for data processing,
not for waiting on external systems.

Run order if deploying this instead: 04 → 05 → 06 → 07 (after the base
setup in ../01-03). Do NOT run alongside the v2 design — in particular,
06's COPY proc and Snowpipe keep separate load histories, so mixing them
can double-load files.
