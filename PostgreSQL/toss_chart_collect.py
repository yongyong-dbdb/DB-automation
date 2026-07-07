import os
import time

import psycopg2
import requests
from psycopg2.extras import Json


DB_CONFIG = {
    "host": os.getenv("DB_HOST", "172.17.0.4"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "postgres"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", "postgres"),
}

MARKET_TYPE = os.getenv("MARKET_TYPE", "us-s")
PRODUCT_INPUTS = [
    code.strip()
    for code in os.getenv("PRODUCT_CODES", "AMX2606012005,BE,SPAX,INTC").split(",")
    if code.strip()
]
CHART_RANGE = os.getenv("CHART_RANGE", "min:1")

# Number of recent candles to request.
COUNT = int(os.getenv("COUNT", "10"))

# Collection interval in seconds.
SLEEP_SECONDS = int(os.getenv("SLEEP_SECONDS", "300"))

BASE_URL = "https://wts-info-api.tossinvest.com/api/v1/c-chart"
STOCK_INFO_URL = "https://wts-info-api.tossinvest.com/api/v2/stock-infos/code-or-symbol"


def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def resolve_product_codes(product_inputs):
    resolved = []
    seen = set()

    for product_input in product_inputs:
        product = resolve_product_code(product_input)
        product_code = product["code"]

        if product_code in seen:
            print(
                f"skip duplicate: {product_input} -> {product_code} ({product['symbol']})",
                flush=True,
            )
            continue

        seen.add(product_code)
        resolved.append(product)

    return resolved


def resolve_product_code(product_input):
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/json",
        "Referer": f"https://www.tossinvest.com/stocks/{product_input}/order",
    }

    response = requests.get(
        f"{STOCK_INFO_URL}/{product_input}",
        headers=headers,
        timeout=15,
    )
    response.raise_for_status()

    result = response.json().get("result", {})
    product_code = result.get("code") or product_input
    symbol = result.get("symbol") or product_input
    name = result.get("name") or result.get("englishName") or product_input

    if product_code != product_input:
        print(f"resolved {product_input} -> {product_code} ({symbol}, {name})", flush=True)

    return {
        "input": product_input,
        "code": product_code,
        "symbol": symbol,
        "name": name,
    }


def fetch_chart(product_code):
    url = f"{BASE_URL}/{MARKET_TYPE}/{product_code}/{CHART_RANGE}"

    params = {
        "count": COUNT,
        "useAdjustedRate": "true",
    }

    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/json",
        "Referer": f"https://www.tossinvest.com/stocks/{product_code}/order",
    }

    print(f"product code   = {product_code}", flush=True)
    print(f"request url    = {url}", flush=True)
    print(f"request params = {params}", flush=True)

    response = requests.get(
        url,
        params=params,
        headers=headers,
        timeout=15,
    )

    response.raise_for_status()

    return response.json()


def parse_candles(data):
    result = data.get("result", {})
    exchange_rate = result.get("exchangeRate")
    candles = result.get("candles", [])

    parsed = []

    for row in candles:
        candle_time = row.get("dt")

        if candle_time is None:
            continue

        parsed.append(
            {
                "candle_time": candle_time,
                "base_price": row.get("base"),
                "open_price": row.get("open"),
                "high_price": row.get("high"),
                "low_price": row.get("low"),
                "close_price": row.get("close"),
                "volume": row.get("volume"),
                "amount": row.get("amount"),
                "exchange_rate": exchange_rate,
                "raw_data": row,
            }
        )

    return parsed


def save_candles(product, candles):
    product_code = product["code"]

    if not candles:
        print(f"no candles to save: {product_code}", flush=True)
        return

    sql = """
        INSERT INTO toss_chart_candle (
            market_type,
            product_code,
            product_symbol,
            product_name,
            chart_range,
            candle_time,
            base_price,
            open_price,
            high_price,
            low_price,
            close_price,
            volume,
            amount,
            exchange_rate,
            raw_data,
            updated_at
        )
        VALUES (
            %(market_type)s,
            %(product_code)s,
            %(product_symbol)s,
            %(product_name)s,
            %(chart_range)s,
            %(candle_time)s,
            %(base_price)s,
            %(open_price)s,
            %(high_price)s,
            %(low_price)s,
            %(close_price)s,
            %(volume)s,
            %(amount)s,
            %(exchange_rate)s,
            %(raw_data)s,
            now()
        )
        ON CONFLICT (
            market_type,
            product_code,
            chart_range,
            candle_time
        )
        DO UPDATE SET
            product_symbol = EXCLUDED.product_symbol,
            product_name = EXCLUDED.product_name,
            base_price = EXCLUDED.base_price,
            open_price = EXCLUDED.open_price,
            high_price = EXCLUDED.high_price,
            low_price = EXCLUDED.low_price,
            close_price = EXCLUDED.close_price,
            volume = EXCLUDED.volume,
            amount = EXCLUDED.amount,
            exchange_rate = EXCLUDED.exchange_rate,
            raw_data = EXCLUDED.raw_data,
            updated_at = now();
    """

    with get_connection() as conn:
        with conn.cursor() as cur:
            for candle in candles:
                cur.execute(
                    sql,
                    {
                        "market_type": MARKET_TYPE,
                        "product_code": product_code,
                        "product_symbol": product["symbol"],
                        "product_name": product["name"],
                        "chart_range": CHART_RANGE,
                        "candle_time": candle["candle_time"],
                        "base_price": candle["base_price"],
                        "open_price": candle["open_price"],
                        "high_price": candle["high_price"],
                        "low_price": candle["low_price"],
                        "close_price": candle["close_price"],
                        "volume": candle["volume"],
                        "amount": candle["amount"],
                        "exchange_rate": candle["exchange_rate"],
                        "raw_data": Json(candle["raw_data"]),
                    },
                )

    print(f"saved {len(candles)} rows: {product_code} ({product['symbol']}, {product['name']})", flush=True)


def collect_once(products):
    for product in products:
        product_code = product["code"]
        try:
            data = fetch_chart(product_code)
            candles = parse_candles(data)
            save_candles(product, candles)
        except Exception as e:
            print(f"ERROR [{product_code}]: {e}", flush=True)


if __name__ == "__main__":
    print(
        "DB connection: "
        f"{DB_CONFIG['user']}@{DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['dbname']}",
        flush=True,
    )
    print(f"product inputs: {', '.join(PRODUCT_INPUTS)}", flush=True)
    print(f"chart range: {CHART_RANGE}", flush=True)
    products = resolve_product_codes(PRODUCT_INPUTS)
    print(
        "product codes: "
        + ", ".join(f"{product['code']}({product['symbol']})" for product in products),
        flush=True,
    )

    while True:
        collect_once(products)

        print(f"sleep {SLEEP_SECONDS} sec", flush=True)
        time.sleep(SLEEP_SECONDS)
