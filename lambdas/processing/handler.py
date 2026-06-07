import json
import boto3
import os
import urllib.parse
import pandas as pd
from datetime import datetime
from decimal import Decimal

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
factor_snapshots_table = dynamodb.Table(os.environ["FACTOR_SNAPSHOTS_TABLE"])

def processing_handler(event, context):

    try:

        results = []

        for record in event["Records"]:

            body = json.loads(record["body"])

            for s3_event in body["Records"]:
                bucket = s3_event["s3"]["bucket"]["name"]
                key = urllib.parse.unquote_plus(s3_event["s3"]["object"]["key"])

                ticker = key.split("/")[1].upper()

                print(f"Processing key={key}, ticker={ticker}")

                obj = s3.get_object(Bucket=bucket, Key=key)
                data = json.loads(obj["Body"].read())

                if "Time Series (Daily)" not in data:
                    raise ValueError(f"Invalid API response: {data.keys()}")

                df = pd.DataFrame(data["Time Series (Daily)"]).T
                df = df.astype(float)

                if len(df) < 50:
                    raise ValueError(f"Not enough data: {len(df)} rows. Need at least 50 rows.")

                cleaned_df = clean_data(df)

                factors = compute_factors(cleaned_df)
                batch_id = extract_batch_id(key)
                write_factor_snapshot(factor_snapshots_table, batch_id, ticker, factors, key)

                print(f"{ticker} factors={factors} written to FactorSnapshots (batch_id={batch_id})")

                results.append({
                    "ticker": ticker,
                    "batch_id": batch_id,
                    "factors": factors,
                })

    except Exception as e:
        print(e)
        raise e

    return {
        "statusCode": 200,
        "body": json.dumps(results),
    }

def compute_factors(df) -> dict:
    return {
        "trend": compute_trend(df),
        "momentum": compute_momentum(df),
        "volatility": compute_volatility(df),
        "zscore": compute_zscore(df),
    }

def extract_batch_id(s3_key: str) -> str:
    timestamp = s3_key.split("/")[2].replace(".json", "")
    return timestamp.split("T")[0]

def write_factor_snapshot(table, batch_id, ticker, factors, s3_key):
    table.put_item(
        Item={
            "PK": batch_id,
            "SK": ticker,
            "trend": Decimal(str(factors["trend"])),
            "momentum": Decimal(str(factors["momentum"])),
            "volatility": Decimal(str(factors["volatility"])),
            "zscore": Decimal(str(factors["zscore"])),
            "s3_key": s3_key,
            "updated_at": datetime.utcnow().isoformat(),
        }
    )

def compute_trend(df):
    sma20 = df["close"].rolling(20).mean()
    sma50 = df["close"].rolling(50).mean()

    return (sma20.iloc[-1] - sma50.iloc[-1]) / sma50.iloc[-1]

def compute_momentum(df):
    close = df["close"]

    return (close.iloc[-1] / close.iloc[-5]) - 1

def compute_volatility(df):
    returns = df["close"].pct_change()

    return returns.rolling(20).std().iloc[-1]

def compute_zscore(df):
    close = df["close"]

    mean = close.rolling(20).mean()
    std = close.rolling(20).std()

    if std.iloc[-1] == 0:
        return 0

    return (close.iloc[-1] - mean.iloc[-1]) / std.iloc[-1]

def clean_data(df):
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
