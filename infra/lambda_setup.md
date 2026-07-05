# Lambda setup (v2, event-driven extraction)

Architecture: EventBridge cron → Lambda (chart mode) → async self-invocations (worker mode)
→ S3 → S3 event notification → Snowpipe → bronze → stream-triggered dbt (or GHA-scheduled dbt).

Replace `<ACCOUNT_ID>` with your AWS account ID throughout. Region: us-east-1.

## 1. Execution role

`lambda-trust.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
```

`lambda-policy.json` (S3 write + self-invoke + logs):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::portfolio-steam-data-raw/raw/*"},
    {"Effect": "Allow", "Action": "lambda:InvokeFunction", "Resource": "arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:steam-extract"},
    {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"}
  ]
}
```

```bash
aws iam create-role --role-name steam-extract-lambda-role --assume-role-policy-document file://lambda-trust.json
aws iam put-role-policy --role-name steam-extract-lambda-role --policy-name steam-extract --policy-document file://lambda-policy.json
```

## 2. Package and deploy

From the `lambda/` folder (PowerShell):
```powershell
pip install -r requirements.txt -t package/ --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all:
Copy-Item handler.py package/
Copy-Item ..\steam_api.py package/    # shared extraction module
Compress-Archive -Path package/* -DestinationPath steam-extract.zip -Force
```

```bash
aws lambda create-function \
  --function-name steam-extract \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::<ACCOUNT_ID>:role/steam-extract-lambda-role \
  --zip-file fileb://steam-extract.zip \
  --timeout 900 --memory-size 256 \
  --environment "Variables={S3_BUCKET=portfolio-steam-data-raw,TOP_N=100,CHUNK_SIZE=50}"
```

Redeploying after code changes is automated: pushes to main touching
`lambda/**` or `steam_api.py` rebuild and deploy via
`.github/workflows/deploy_lambda.yml`. (Manual equivalent: rebuild the zip,
then `aws lambda update-function-code --function-name steam-extract --zip-file fileb://steam-extract.zip`)

## 3. EventBridge schedule

```bash
aws events put-rule --name steam-daily-extract --schedule-expression "cron(0 6 * * ? *)"
aws lambda add-permission --function-name steam-extract --statement-id eventbridge \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn arn:aws:events:us-east-1:<ACCOUNT_ID>:rule/steam-daily-extract
aws events put-targets --rule steam-daily-extract \
  --targets '[{"Id":"1","Arn":"arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:steam-extract","Input":"{\"task\":\"chart\"}"}]'
```

## 4. S3 → Snowpipe notification

Run `snowflake/04_snowpipe.sql` first, copy the `notification_channel` ARN from
`SHOW PIPES` (all four pipes share one), then:

`notification.json`:
```json
{
  "QueueConfigurations": [{
    "QueueArn": "<notification_channel ARN from SHOW PIPES>",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "raw/"}]}}
  }]
}
```

```bash
aws s3api put-bucket-notification-configuration --bucket portfolio-steam-data-raw \
  --notification-configuration file://notification.json
```

## 5. Test end to end

```bash
# manual trigger (chart mode fans out workers automatically)
aws lambda invoke --function-name steam-extract \
  --payload '{"task":"chart"}' --cli-binary-format raw-in-base64-out out.json && cat out.json

# watch workers in CloudWatch
aws logs tail /aws/lambda/steam-extract --follow
```

Then in Snowflake (within ~5 min of workers finishing):
```sql
SELECT SYSTEM$PIPE_STATUS('OPS.PIPE_REVIEWS');
SELECT COUNT(*), MAX(_loaded_at) FROM RAW.REVIEWS;
```

## Cost

Lambda: ~13 invocations/day, ~20 total compute-minutes at 256MB — comfortably in
the permanent free tier ($0). Snowpipe: serverless, fractions of a cent per day
at this volume. EventBridge/SQS/CloudWatch: $0 at this scale.

## Coexistence with v1

- Suspend the Snowflake task DAG (`ALTER TASK OPS.T1_EXTRACT_STEAM SUSPEND;` etc.)
  so two schedulers don't both extract. The Snowpark proc (05) and task DAG (07)
  stay in the repo as the documented all-in-Snowflake alternative.
- dbt runs natively in Snowflake (DBT PROJECT object + stream-triggered task,
  see snowflake/05); GitHub Actions keeps only PR checks and the
  `manual_extract.yml` backfill trigger.
- Don't call `OPS.LOAD_RAW()` once Snowpipe is enabled: bulk COPY and Snowpipe
  keep SEPARATE load histories, so mixing them can double-load files. (Silver
  models dedupe with QUALIFY, so it degrades gracefully — but don't do it.)
