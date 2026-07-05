# AWS setup — S3 bucket + IAM role for Snowflake

Run these with the AWS CLI (or console). Replace `steam-pipeline-<yourname>` everywhere — bucket names are global.

## 1. Create the bucket

```bash
aws s3api create-bucket --bucket portfolio-steam-data-raw --region us-east-1
aws s3api put-public-access-block --bucket portfolio-steam-data-raw \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

(For regions other than us-east-1, add `--create-bucket-configuration LocationConstraint=<region>`.)

## 2. IAM policy for Snowflake access

Save as `snowflake-s3-policy.json`:

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

```bash
aws iam create-policy --policy-name snowflake-steam-s3 --policy-document file://snowflake-s3-policy.json
```

## 3. IAM role (placeholder trust, updated after Snowflake integration exists)

Save as `trust-policy.json` (temporary — your own account as principal):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:root"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "0000"}}
    }
  ]
}
```

```bash
aws iam create-role --role-name snowflake-steam-role --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name snowflake-steam-role \
  --policy-arn arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:policy/snowflake-steam-s3
```

## 4. After creating the Snowflake storage integration

Run in Snowflake (see `snowflake/02_storage_integration.sql`):

```sql
DESC STORAGE INTEGRATION steam_s3_int;
```

Copy `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID`, then update the trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "<STORAGE_AWS_IAM_USER_ARN>"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"}}
    }
  ]
}
```

```bash
aws iam update-assume-role-policy --role-name snowflake-steam-role --policy-document file://trust-policy.json
```
