-- AdVigilance: Performance Indexes
-- Run this AFTER loading data for optimal query performance
-- Estimated time: 5-10 minutes for 1M rows, 30-60 minutes for 40M rows

-- =====================================================
-- INDEXES FOR CLICK_STREAM TABLE
-- =====================================================

-- BRIN index for timestamp (best for time-series data)
-- BRIN is 100x smaller than B-tree and perfect for sequential data
CREATE INDEX IF NOT EXISTS idx_click_stream_timestamp_brin 
    ON advigilance.click_stream USING BRIN (timestamp);

-- B-tree index for user lookups
CREATE INDEX IF NOT EXISTS idx_click_stream_user_id 
    ON advigilance.click_stream (user_id);

-- Hash index for IP address equality lookups
CREATE INDEX IF NOT EXISTS idx_click_stream_ip_hash 
    ON advigilance.click_stream USING HASH (ip_address);

-- B-tree index for campaign filtering
CREATE INDEX IF NOT EXISTS idx_click_stream_campaign 
    ON advigilance.click_stream (campaign_id);

-- Composite index for common query patterns
CREATE INDEX IF NOT EXISTS idx_click_stream_timestamp_campaign 
    ON advigilance.click_stream (timestamp DESC, campaign_id);

-- Partial index for fraud queries only
CREATE INDEX IF NOT EXISTS idx_click_stream_fraud_only 
    ON advigilance.click_stream (ip_address, fraud_score, timestamp)
    WHERE is_suspicious = true;

-- Covering index for Power BI queries
CREATE INDEX IF NOT EXISTS idx_click_stream_powerbi 
    ON advigilance.click_stream (timestamp, campaign_id)
    INCLUDE (fraud_score, is_suspicious);

-- GIN index for fraud_reasons array searches
CREATE INDEX IF NOT EXISTS idx_click_stream_fraud_reasons_gin 
    ON advigilance.click_stream USING GIN (fraud_reasons)
    WHERE fraud_reasons IS NOT NULL AND fraud_reasons != '{}';

-- =====================================================
-- INDEXES FOR CONVERSION_STREAM TABLE
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_conversion_stream_timestamp 
    ON advigilance.conversion_stream USING BRIN (timestamp);

CREATE INDEX IF NOT EXISTS idx_conversion_stream_user_id 
    ON advigilance.conversion_stream (user_id);

CREATE INDEX IF NOT EXISTS idx_conversion_stream_click_id 
    ON advigilance.conversion_stream (attributed_click_id);

-- =====================================================
-- INDEXES FOR BOT_BLACKLIST TABLE
-- =====================================================

-- GIST index for IP address range matching
CREATE INDEX IF NOT EXISTS idx_bot_blacklist_ip_gist 
    ON advigilance.bot_blacklist USING GIST (ip_address inet_ops)
    WHERE ip_address IS NOT NULL;

-- Partial index for active blacklist entries
CREATE INDEX IF NOT EXISTS idx_bot_blacklist_active 
    ON advigilance.bot_blacklist (ip_address, severity)
    WHERE is_active = true;

-- =====================================================
-- INDEXES FOR FRAUD_EVENTS TABLE
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_fraud_events_click_id 
    ON advigilance.fraud_events (click_id);

CREATE INDEX IF NOT EXISTS idx_fraud_events_detected_at 
    ON advigilance.fraud_events (detected_at DESC);

CREATE INDEX IF NOT EXISTS idx_fraud_events_fraud_type 
    ON advigilance.fraud_events (fraud_type, fraud_score);

-- =====================================================
-- STATISTICS UPDATE
-- =====================================================

-- Update table statistics for query planner
ANALYZE advigilance.click_stream;
ANALYZE advigilance.conversion_stream;
ANALYZE advigilance.bot_blacklist;
ANALYZE advigilance.campaign_budgets;
ANALYZE advigilance.fraud_events;
ANALYZE advigilance.daily_campaign_summary;

-- =====================================================
-- VERIFICATION
-- =====================================================

-- Show all indexes created
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_indexes
WHERE schemaname = 'advigilance'
ORDER BY tablename, indexname;

-- Show table sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) as index_size
FROM pg_tables
WHERE schemaname = 'advigilance'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

SELECT 'Indexes created successfully!' as status;
