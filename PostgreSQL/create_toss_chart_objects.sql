CREATE TABLE IF NOT EXISTS toss_chart_candle (
    id bigserial PRIMARY KEY,
    market_type text NOT NULL,
    product_code text NOT NULL,
    product_symbol text,
    product_name text,
    chart_range text NOT NULL,
    candle_time text NOT NULL,
    base_price numeric,
    open_price numeric,
    high_price numeric,
    low_price numeric,
    close_price numeric,
    volume numeric,
    amount numeric,
    exchange_rate numeric,
    raw_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT toss_chart_candle_unique_candle
        UNIQUE (market_type, product_code, chart_range, candle_time)
);

CREATE INDEX IF NOT EXISTS idx_toss_chart_candle_lookup
    ON toss_chart_candle (market_type, product_code, chart_range, candle_time DESC);

CREATE INDEX IF NOT EXISTS idx_toss_chart_candle_product_time
    ON toss_chart_candle (product_code, candle_time DESC);
