import json
import boto3

secrets_client = boto3.client("secretsmanager")

def ingestion_handler(event, context):

    # 1. Extract ticker from SQS
    body = json.loads(event["Records"][0]["body"])
    ticker = body["ticker"]

    # 2. Get API key from Secrets Manager
    secret = secrets_client.get_secret_value(
        SecretId="alpha-vantage-api-key"
    )

    api_key = json.loads(secret["SecretString"])["api_key"]

    print(f"Ticker: {ticker}")
    print(f"API Key loaded successfully: {api_key[:4]}****")

    return {
        "statusCode": 200
    }