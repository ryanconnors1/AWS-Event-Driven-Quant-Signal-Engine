import json
import boto3
import os
import numpy as np
import pandas as pd
from datetime import datetime

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DDB_TABLE"])

def processing_handler(event, context):

    try:

    results = []

    # Process each record in the event
    for record in event["Records"]:

        # Parse SQS message
        msg = json.loads(record["body"])

        # Get S3 bucket, key, and ticker
        bucket = msg["bucket"]
        key = msg["key"]

        ticker = key.split("/")[1].upper()

        # Get data from S3
        obj = s3.get_object(Bucket=bucket, Key=key)
        data = json.loads(obj["Body"].read())

        # Convert data to DataFrame
        if "Time Series (Daily)" not in data:
            raise ValueError(f"Invalid API response: {data.keys()}")

        df = pd.DataFrame(data["Time Series (Daily)"]).T
        df = df.astype(float)

        if len(df) < 50:
            raise ValueError(f"Not enough data: {len(df)} rows. Need at least 50 rows.")

        cleaned_df = clean_data(df)

        # Compute score and signal
        score = compute_score(cleaned_df)
        signal = generate_signal(score)

        # Write result to DynamoDB
        write_result(table, ticker, score, signal)

        results.append({
        "ticker": ticker,
        "score": score,
        "signal": signal
    })

    except Exception as e:
        print(e)
        raise e
    
    return {

        "statusCode": 200,
        "body": json.dumps(results)

    }

def compute_trend(df):
    # Compute 20-day and 50-day simple moving averages
    sma20 = df["4. close"].rolling(20).mean()
    sma50 = df["4. close"].rolling(50).mean()

    # Compute trend as the difference between the two moving averages divided by the 50-day moving average
    return (sma20.iloc[-1] - sma50.iloc[-1]) / sma50.iloc[-1]

def compute_momentum(df):
    # Compute momentum as the difference between the current close and the close 5 days ago
    close = df["4. close"]

    # Compute momentum as the difference between the current close and the close 5 days ago
    return (close.iloc[-1] / close.iloc[-5]) - 1

def compute_volatility(df):
    # Compute volatility as the standard deviation of the returns
    returns = df["4. close"].pct_change()

    return returns.rolling(20).std().iloc[-1]

def compute_zscore(df):
    # Compute Z-score as the difference between the current close and the mean of the last 20 closes divided by the standard deviation of the last 20 closes
    close = df["4. close"]

    mean = close.rolling(20).mean()
    std = close.rolling(20).std()

    if std.iloc[-1] == 0:
        return 0

    return (close.iloc[-1] - mean.iloc[-1]) / std.iloc[-1]

def compute_score(df):
    # Compute score as the weighted average of the trend, momentum, volatility, and Z-score
    trend = compute_trend(df)
    momentum = compute_momentum(df)
    vol = compute_volatility(df)
    z = compute_zscore(df)

    score = (
        0.4 * trend +
        0.3 * momentum +
        0.2 * (-z) +
        0.1 * (1 / (vol + 1e-6))
    )

    return score

def generate_signal(score):
    # Generate signal as BUY, SELL, or HOLD based on the score
    if score > 0.5:
        return "BUY"
    elif score < -0.5:
        return "SELL"
    else:
        return "HOLD"

def write_result(table, ticker, score, signal):
    # Write result to DynamoDB
    table.put_item(
        Item={
            "PK": ticker,
            "SK": datetime.utcnow().isoformat(),
            "score": str(score),
            "signal": signal
        }
    )

def clean_data(df):
    # Clean data by renaming columns and ensuring required columns are present
    df.columns = [c.strip().lower().replace(" ", "") for c in df.columns]

    df = df.rename(columns={
        "1.open": "open",
        "2.high": "high",
        "3.low": "low",
        "4.close": "close",
        "5.volume": "volume"
    })

    required = ["open", "high", "low", "close", "volume"]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Missing columns: {missing}")

    return df