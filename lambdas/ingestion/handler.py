import json
import boto3
import urllib.request
import os
from datetime import datetime

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")


def ingestion_handler(event, context):
    print("Received event:", event)

    # 1. Parse SQS message
    body = json.loads(event["Records"][0]["body"])
    ticker = body["ticker"]

    # 2. Get API key from Secrets Manager
    secret = secrets.get_secret_value(
        SecretId="alpha-vantage-api-key"
    )
    api_key = json.loads(secret["SecretString"])["api_key"]

    # 3. Call Alpha Vantage
    url = (
        "https://www.alphavantage.co/query"
        f"?function=TIME_SERIES_DAILY"
        f"&symbol={ticker}"
        f"&apikey={api_key}"
    )

    with urllib.request.urlopen(url) as response:
        data = json.loads(response.read().decode())

    # 4. Create S3 key (VERY important pattern)
    timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%S")

    key = f"raw/{ticker}/{timestamp}.json"

    # 5. Write to S3
    bucket = os.environ["BUCKET_NAME"]

    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(data)
    )

    print(f"Wrote data to s3://{bucket}/{key}")

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "success"})
    }