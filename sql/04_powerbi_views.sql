-- AdVigilance: Power BI Optimized Views
-- These views are pre-aggregated for fast Power BI performance
-- Run this after loading data into click_stream table

-- =====================================================
-- VIEW 1: FRAUD SUMMARY BY HOUR
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_fraud_summary AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    campaign_id,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    COUNT(*) - SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as clean_clicks,
    ROUND(100.0 * SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) / COUNT(*), 2) as fraud_percentage,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    COUNT(DISTINCT ip_address) as unique_ips,
    COUNT(DISTINCT user_id) as unique_users
FROM advigilance.click_stream
GROUP BY DATE_TRUNC('hour', timestamp), campaign_id
ORDER BY hour DESC;

COMMENT ON VIEW advigilance.powerbi_fraud_summary IS 
'Hourly fraud metrics aggregated by campaign for time-series charts';

-- =====================================================
-- VIEW 2: TOP FRAUD IP ADDRESSES
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_top_fraud_ips AS
SELECT 
    ip_address,
    COUNT(*) as total_clicks,
    MAX(fraud_score) as max_fraud_score,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    MAX(timestamp) as last_seen,
    MIN(timestamp) as first_seen,
    COUNT(DISTINCT campaign_id) as campaigns_affected,
    COUNT(DISTINCT user_id) as unique_users,
    -- Fraud classification
    CASE 
        WHEN MAX(fraud_score) >= 90 THEN 'CRITICAL'
        WHEN MAX(fraud_score) >= 75 THEN 'HIGH'
        WHEN MAX(fraud_score) >= 50 THEN 'MEDIUM'
        ELSE 'LOW'
    END as threat_level
FROM advigilance.click_stream
WHERE is_suspicious = true
GROUP BY ip_address
ORDER BY total_clicks DESC
LIMIT 1000;

COMMENT ON VIEW advigilance.powerbi_top_fraud_ips IS 
'Top 1000 fraudulent IP addresses ranked by click volume';

-- =====================================================
-- VIEW 3: CAMPAIGN PERFORMANCE METRICS
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_campaign_performance AS
SELECT 
    cb.campaign_id,
    cb.campaign_name,
    cb.advertiser_name,
    COUNT(c.click_id) as total_clicks,
    SUM(CASE WHEN c.is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    COUNT(c.click_id) - SUM(CASE WHEN c.is_suspicious THEN 1 ELSE 0 END) as clean_clicks,
    ROUND(100.0 * SUM(CASE WHEN c.is_suspicious THEN 1 ELSE 0 END) / COUNT(c.click_id), 2) as fraud_percentage,
    ROUND(AVG(c.fraud_score), 2) as avg_fraud_score,
    COUNT(DISTINCT c.ip_address) as unique_ips,
    -- Financial metrics
    cb.cost_per_click,
    cb.daily_budget,
    ROUND(COUNT(c.click_id) * cb.cost_per_click, 2) as total_cost,
    ROUND(SUM(CASE WHEN c.is_suspicious THEN 1 ELSE 0 END) * cb.cost_per_click, 2) as fraud_cost,
    ROUND((COUNT(c.click_id) - SUM(CASE WHEN c.is_suspicious THEN 1 ELSE 0 END)) * cb.cost_per_click, 2) as clean_cost,
    -- Time range
    MIN(c.timestamp) as first_click,
    MAX(c.timestamp) as last_click
FROM advigilance.campaign_budgets cb
LEFT JOIN advigilance.click_stream c ON cb.campaign_id = c.campaign_id
GROUP BY 
    cb.campaign_id, 
    cb.campaign_name, 
    cb.advertiser_name, 
    cb.cost_per_click, 
    cb.daily_budget;

COMMENT ON VIEW advigilance.powerbi_campaign_performance IS 
'Campaign-level metrics including fraud rates and financial impact';

-- =====================================================
-- VIEW 4: HOURLY TRENDS (ALL CAMPAIGNS COMBINED)
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_hourly_trends AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    COUNT(*) - SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as clean_clicks,
    ROUND(100.0 * SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) / COUNT(*), 2) as fraud_percentage,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    COUNT(DISTINCT ip_address) as unique_ips,
    COUNT(DISTINCT user_id) as unique_users,
    COUNT(DISTINCT campaign_id) as active_campaigns
FROM advigilance.click_stream
GROUP BY DATE_TRUNC('hour', timestamp)
ORDER BY hour DESC;

COMMENT ON VIEW advigilance.powerbi_hourly_trends IS 
'Hourly trends across all campaigns for time-series analysis';

-- =====================================================
-- VIEW 5: DEVICE & GEO BREAKDOWN
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_device_geo AS
SELECT 
    device_type,
    geo_country,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    ROUND(100.0 * SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) / COUNT(*), 2) as fraud_percentage,
    COUNT(DISTINCT ip_address) as unique_ips
FROM advigilance.click_stream
GROUP BY device_type, geo_country
ORDER BY total_clicks DESC;

COMMENT ON VIEW advigilance.powerbi_device_geo IS 
'Fraud metrics broken down by device type and country';

-- =====================================================
-- VIEW 6: FRAUD TYPE BREAKDOWN
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_fraud_types AS
WITH fraud_patterns AS (
    SELECT 
        click_id,
        CASE 
            WHEN fraud_reasons::text LIKE '%burst%' THEN 'Burst Attack'
            WHEN fraud_reasons::text LIKE '%bot%' THEN 'Bot Network'
            WHEN fraud_reasons::text LIKE '%geo%' THEN 'Geo Anomaly'
            WHEN fraud_reasons::text LIKE '%blacklist%' THEN 'Blacklisted'
            WHEN fraud_reasons::text LIKE '%instant%' THEN 'Instant Conversion'
            ELSE 'Other'
        END as fraud_type,
        fraud_score,
        timestamp
    FROM advigilance.click_stream
    WHERE is_suspicious = true
)
SELECT 
    fraud_type,
    COUNT(*) as incident_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) as percentage,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen
FROM fraud_patterns
GROUP BY fraud_type
ORDER BY incident_count DESC;

COMMENT ON VIEW advigilance.powerbi_fraud_types IS 
'Breakdown of fraud incidents by detection pattern type';

-- =====================================================
-- VIEW 7: DAILY SUMMARY (FOR CALENDARS)
-- =====================================================

CREATE OR REPLACE VIEW advigilance.powerbi_daily_summary AS
SELECT 
    DATE_TRUNC('day', timestamp)::date as date,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    ROUND(100.0 * SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) / COUNT(*), 2) as fraud_percentage,
    COUNT(DISTINCT ip_address) as unique_ips,
    COUNT(DISTINCT campaign_id) as active_campaigns
FROM advigilance.click_stream
GROUP BY DATE_TRUNC('day', timestamp)::date
ORDER BY date DESC;

COMMENT ON VIEW advigilance.powerbi_daily_summary IS 
'Daily rollup for calendar visualizations and trend analysis';

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

-- Grant read access to all views
GRANT SELECT ON ALL TABLES IN SCHEMA advigilance TO PUBLIC;
GRANT SELECT ON ALL VIEWS IN SCHEMA advigilance TO PUBLIC;

-- =====================================================
-- VERIFICATION
-- =====================================================

-- List all views created
SELECT 
    schemaname,
    viewname,
    viewowner
FROM pg_views
WHERE schemaname = 'advigilance'
ORDER BY viewname;

-- Test each view
SELECT 'Testing powerbi_fraud_summary...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_fraud_summary;

SELECT 'Testing powerbi_top_fraud_ips...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_top_fraud_ips;

SELECT 'Testing powerbi_campaign_performance...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_campaign_performance;

SELECT 'Testing powerbi_hourly_trends...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_hourly_trends;

SELECT 'Testing powerbi_device_geo...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_device_geo;

SELECT 'Testing powerbi_fraud_types...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_fraud_types;

SELECT 'Testing powerbi_daily_summary...' as test;
SELECT COUNT(*) as row_count FROM advigilance.powerbi_daily_summary;

SELECT 'All Power BI views created successfully! ✓' as status;
