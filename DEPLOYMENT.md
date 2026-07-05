# Deployment runbook — Lambda → S3 → Snowpipe → Snowflake → dbt

The master walkthrough for the event-driven (v2) path. Each step ends with a
**Gate**: verify it before moving on. Commands are PowerShell-friendly
(AWS CLI multi-line `\` doesn't work in PowerShell — commands here are single-line
or use PowerShell backticks).

Throughout, replace `<ACCOUNT_ID>` with your 12-digit AWS account ID
(find it: AWS console, top-right dropdown).

---

## 0. Prerequisites

- [ ] S3 bucket `portfolio-steam-data-raw` exists
- [ ] IAM user group policy fixed (ListBucket on bucket ARN, Get/PutObject on `/*`)
- [ ] `.env` has `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET=portfolio-steam-data-raw`
- [ ] AWS console (browser) access — no AWS CLI needed; all AWS steps below are console-based
- [ ] Snowflake account with ACCOUNTADMIN access
- [ ] Dry run passed (`python extract_steam.py --dry-run`)

---

## 1. Real extraction run to S3 (~15 min)

```powershell
python extract_steam.py
```

**Gate:** S3 console → `portfolio-steam-data-raw/raw/` shows four folders
(`most_played`, `player_counts`, `reviews`, `app_details`), each with an
`ingest_date=.../*.ndjson` file. This validates your IAM user permissions and
gives Snowflake something to load in step 3.

---

## 2. IAM role for Snowflake (~10 min)

Snowflake authenticates by *assuming a role* — separate from your IAM user.

Save `snowflake-s3-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::portfolio-steam-data-raw/raw/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::portfolio-steam-data-raw",
      "Condition": {"StringLike": {"s3:prefix": ["raw/*"]}}
    }
  ]
}
```

Save `trust-policy.json` (placeholder — replaced in step 3):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::<ACCOUNT_ID>:root"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "0000"}}
    }
  ]
}
```

Console steps (find your `<ACCOUNT_ID>`: top-right account menu, 12 digits, strip dashes):

1. **Policy**: IAM → Policies → Create policy → JSON tab → paste the first
   block above → Next → name `snowflake-steam-s3` → Create policy.
2. **Role**: IAM → Roles → Create role → trusted entity type **Custom trust
   policy** → paste the second block (with your account ID filled in) →
   Next → search and tick `snowflake-steam-s3` → Next → name
   `snowflake-steam-role` → Create role.

**Gate:** IAM → Roles → `snowflake-steam-role` exists with the policy attached.
Copy its ARN: `arn:aws:iam::<ACCOUNT_ID>:role/snowflake-steam-role`.

---

## 3. Snowflake base + the trust handshake (~20 min)

In a Snowflake worksheet:

1. Run all of **`snowflake/01_database_setup.sql`** (role SYSADMIN).
2. Open **`snowflake/02_storage_integration.sql`**, paste your `<ACCOUNT_ID>`
   into the `STORAGE_AWS_ROLE_ARN`, run it (role ACCOUNTADMIN).
3. From the `DESC STORAGE INTEGRATION steam_s3_int;` output, copy:
   - `STORAGE_AWS_IAM_USER_ARN` (looks like `arn:aws:iam::9876...:user/abc1-s-...`)
   - `STORAGE_AWS_EXTERNAL_ID` (looks like `AB12345_SFCRole=...`)
4. Back in AWS: IAM → Roles → `snowflake-steam-role` → Trust relationships →
   Edit — replace Principal AWS with the IAM_USER_ARN and the ExternalId with
   the EXTERNAL_ID. (Or update `trust-policy.json` and run
   `aws iam update-assume-role-policy --role-name snowflake-steam-role --policy-document file://trust-policy.json`.)
5. Run all of **`snowflake/03_stage_and_raw_tables.sql`** (SYSADMIN).

**Gate:**
```sql
LIST @OPS.STEAM_RAW_STAGE;
```
must show your step-1 files.

> **If it fails** ("Access Denied" / "not authorized"): 99% a handshake typo.
> Check, in order: (a) trust policy Principal exactly equals the IAM_USER_ARN,
> (b) ExternalId exactly equals STORAGE_AWS_EXTERNAL_ID, (c) role ARN in the
> integration has no typos, (d) wait ~30s — IAM changes aren't instant.

---

## 4. Lambda + EventBridge (~30 min)

### 4a. Package the code (local terminal — the only non-browser part)

From the `lambda/` folder in VS Code's terminal:
```powershell
pip install -r requirements.txt -t package/ --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all:
Copy-Item handler.py package/
Copy-Item ..\steam_api.py package/
Compress-Archive -Path package/* -DestinationPath steam-extract.zip -Force
```
This bundles the code + the `requests` library into `steam-extract.zip`
(boto3 is preinstalled in Lambda, so it's not packaged).

The `--platform/--python-version/--only-binary` flags matter: Lambda runs
**Linux / Python 3.12**, and without them pip packages wheels for YOUR machine
(e.g. Windows binaries), which can fail to import in Lambda. If you rebuild,
delete the old artifacts first: `Remove-Item -Recurse -Force package, steam-extract.zip`

### 4b. Create the function (console)

1. Search **Lambda** in the console → **Create function** → "Author from scratch".
2. Name `steam-extract`, runtime **Python 3.12**, architecture x86_64 → Create.
   (Letting Lambda create its default execution role is fine — we extend it next.)
3. **Upload the code**: Code tab → "Upload from" → ".zip file" → `steam-extract.zip`.
4. **Handler**: Code tab → Runtime settings → Edit → `handler.lambda_handler`.
5. **Timeout/memory**: Configuration tab → General configuration → Edit →
   timeout `15 min 0 sec`, memory 256 MB.
6. **Env vars**: Configuration → Environment variables → Edit → add three:
   `S3_BUCKET` = `portfolio-steam-data-raw`, `TOP_N` = `100`, `CHUNK_SIZE` = `50`.
7. **Permissions**: Configuration → Permissions → click the role name (opens IAM)
   → Add permissions → Create inline policy → JSON → paste (fill `<ACCOUNT_ID>`,
   and set the REGION in the lambda ARN to the region your function is actually
   in — top-right region picker; e.g. `us-east-2`. An ARN region mismatch causes
   AccessDenied on the fan-out invoke):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::portfolio-steam-data-raw/raw/*"},
    {"Effect": "Allow", "Action": "lambda:InvokeFunction", "Resource": "arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:steam-extract"}
  ]
}
```
   Name it `steam-extract-s3-and-fanout` → Create. (CloudWatch logging is
   already in the default role.)

### 4c. Test it (console)

Lambda → `steam-extract` → **Test** tab → create new event, name `chart`,
Event JSON: `{"task": "chart"}` → **Test** button.

**Gate:** response shows `{"status": "ok", "games": 100, "workers": 6}`
(~30-60s). Then Monitor tab → View CloudWatch logs — expect 7 log streams
appearing (1 chart + 6 workers, ~3-6 min). Then S3 shows new
`_part00`/`_part01` files in each dataset folder.

### 4d. Daily schedule (console)

EventBridge → Rules → **Create rule**: name `steam-daily-extract`, rule type
"Schedule" → cron expression `0 6 * * ? *` → target: Lambda function
`steam-extract` → Additional settings → "Configure target input" →
**Constant (JSON text)**: `{"task": "chart"}` → Create.
(The console adds the invoke permission to the Lambda automatically.)

**Gate:** the rule's Targets tab shows `steam-extract` with the constant input.

---

## 5. Snowpipe (~15 min)

1. Run all of **`snowflake/04_snowpipe.sql`** (SYSADMIN).
2. From `SHOW PIPES IN SCHEMA OPS;`, copy any `notification_channel` value
   (all four pipes share one SQS ARN).
3. Wire the bucket: S3 console → `portfolio-steam-data-raw` → Properties →
   Event notifications → Create: name `snowpipe-raw`, prefix `raw/`,
   event type "All object create events", destination SQS queue → "Enter SQS
   queue ARN" → paste it.
4. Backfill the files that landed before the notification existed:
```sql
ALTER PIPE OPS.PIPE_MOST_PLAYED REFRESH;
ALTER PIPE OPS.PIPE_PLAYER_COUNTS REFRESH;
ALTER PIPE OPS.PIPE_REVIEWS REFRESH;
ALTER PIPE OPS.PIPE_APP_DETAILS REFRESH;
```

**Gate** (wait 1-2 min after REFRESH):
```sql
SELECT 'most_played' t, COUNT(*) FROM RAW.MOST_PLAYED
UNION ALL SELECT 'player_counts', COUNT(*) FROM RAW.PLAYER_COUNTS
UNION ALL SELECT 'reviews', COUNT(*) FROM RAW.REVIEWS
UNION ALL SELECT 'app_details', COUNT(*) FROM RAW.APP_DETAILS;
```
All four counts > 0.

> **If zero rows:** `SELECT SYSTEM$PIPE_STATUS('OPS.PIPE_REVIEWS');` —
> `executionState: RUNNING` is good; check `COPY_HISTORY` for errors:
> `SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME=>'RAW.REVIEWS', START_TIME=>DATEADD(hour,-2,CURRENT_TIMESTAMP())));`

---

## 6. dbt — runs natively in Snowflake (~30 min)

(dbt Projects on Snowflake: the project executes inside Snowflake using session
auth — no local Python, no credentials file.)

1. In Snowsight → Projects → Workspaces, create a `steam_dbt` folder and
   recreate the `dbt/` contents with the folder structure intact
   (`dbt_project.yml` + `profiles.yml` at the root; `macros/`, `models/silver/`,
   `models/gold/`, `tests/` beneath). Skip `profiles.yml.example`.
2. The workspace detects the project (dbt toolbar appears). Select profile
   target `prod`, operation **Build** → Execute. Expect `PASS=23 ERROR=0`.
3. **Deploy** (dropdown next to Build): location `STEAM`/`OPS`, name
   `STEAM_DBT`, default target `prod`, "Run dbt deps" off.
4. One-time grants (ACCOUNTADMIN):
   ```sql
   GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
   GRANT USAGE ON DBT PROJECT STEAM.OPS.STEAM_DBT TO ROLE SYSADMIN;
   ```
5. Run `snowflake/05_streams_triggered_dbt.sql` (uncomment the
   `EXECUTE DBT PROJECT` line first), then
   `ALTER TASK OPS.T_DBT_ON_ARRIVAL RESUME;`

**Gate:** `CALL OPS.RUN_DBT();` succeeds (blocks ~2 min), a row lands in
`OPS.DBT_TRIGGER_LOG`, and `TASK_HISTORY()` shows the task SUCCEEDED (or
SKIPPED with "conditional false" — that's healthy: streams are empty until
new data arrives). Then:
```sql
SELECT g.game_name, f.chart_rank, f.peak_in_game, f.reviews_total, f.positive_review_ratio
FROM STEAM.GOLD.FACT_DAILY_GAME_PERFORMANCE f
JOIN STEAM.GOLD.DIM_GAME g ON g.game_key = f.game_key
WHERE f.activity_date = CURRENT_DATE()
ORDER BY f.chart_rank
LIMIT 10;
```
Today's top 10 with names and review stats. **This is the pipeline working end to end.**

> Known edge case: if the `relationships` test on fact_review fails, it's a
> game with reviews but no store page (e.g. Deadlock) — see INTERVIEW_PREP.md.

---

## 7. GitHub (~15 min)

1. Create a **public** repo, push the project (`.gitignore` already excludes
   `.env`, `out/`, build artifacts).
2. Optional — only if you want the `manual-extract` backfill workflow to work:
   add repo secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET`.
   No Snowflake secrets needed anywhere: dbt runs inside Snowflake.

**Gate:** repo visible, no `.env` or credentials in the file list.

---

## 8. Steady state

| When (UTC) | What | Where to monitor |
|---|---|---|
| 06:00 | EventBridge → Lambda extracts (7 invocations) | CloudWatch logs |
| ~06:05-06:15 | Snowpipe ingests files as they land | `COPY_HISTORY`, `PIPE_STATUS` |
| ~06:10-06:30 | Streams fill → triggered task runs dbt build | Monitoring → Task History, `OPS.DBT_TRIGGER_LOG` |

Costs: Lambda + EventBridge ≈ $0 (free tier), Snowpipe pennies/month,
Snowflake ≈ $3/month (dbt + COPY warehouse time), GitHub free on public repos.

Day-after check: tomorrow, confirm a second `activity_date` appears in
`GOLD.FACT_DAILY_GAME_PERFORMANCE` — that's your top-100-over-time history
accumulating, hands-free.

NOTE: the dbt project of record runs from the DBT PROJECT object. After editing
models in the repo (or workspace), re-run Build in the workspace and re-Deploy
to update the scheduled runs.
