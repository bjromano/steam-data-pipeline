-- Run as ACCOUNTADMIN. Replace <YOUR_AWS_ACCOUNT_ID> and bucket name.
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION steam_s3_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-steam-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://portfolio-steam-data-raw/raw/');

-- Grab STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this output,
-- then update the IAM role trust policy (see infra/aws_setup.md step 4).
DESC STORAGE INTEGRATION steam_s3_int;

GRANT USAGE ON INTEGRATION steam_s3_int TO ROLE SYSADMIN;
