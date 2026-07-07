ALTER TABLE toss_chart_candle
    ADD COLUMN IF NOT EXISTS product_symbol text,
    ADD COLUMN IF NOT EXISTS product_name text;

CREATE INDEX IF NOT EXISTS idx_toss_chart_candle_symbol_time
    ON toss_chart_candle (product_symbol, candle_time DESC);
