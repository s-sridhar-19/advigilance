-- AdVigilance: Core Fraud Detection Queries
-- These queries power the real-time fraud detection engine
-- Optimized for PostgreSQL 14+ with time-series data

-- =====================================================
-- QUERY 1: INSTANT CONVERSION FRAUD DETECTOR
-- =====================================================
-- Detects bot networks that convert (purchase) too quickly after clicking
-- Human behavior: 5-10+ seconds to complete a purchase
-- Bot behavior: < 2 seconds (automated scripts)

WITH Click_Conversion_Match AS (
    SELECT 
        c.click_id,
        c.ip_address,
        c.campaign_id,
        c.user_id,
        c.device_type,
        c.geo_country,
        cv.conversion_id,
        cv.revenue,
        cv.conversion_type,
        -- Calculate time difference in seconds
        EXTRACT(EPOCH FROM (cv.timestamp - c.timestamp)) as time_to_convert,
        c.timestamp as click_time,
        cv.timestamp as conversion_time,
        -- Add context
        c.user_agent,
        c.referrer_url
    FROM click_stream c
    INNER JOIN conversion_stream cv 
        ON c.user_id = cv.user_id
    WHERE 
        -- Conversion must happen AFTER click
        cv.timestamp > c.timestamp
        -- Attribution window: conversions within 1 hour of click
        AND cv.timestamp <= c.timestamp + INTERVAL '1 hour'
        -- Focus on recent data (adjust based on data volume)
        AND c.timestamp >= NOW() - INTERVAL '7 days'
),
IP_Fraud_Metrics AS (
    SELECT 
        ip_address,
        COUNT(DISTINCT click_id) as total_conversions,
        AVG(time_to_convert) as avg_conversion_speed_seconds,
        MIN(time_to_convert) as fastest_conversion_seconds,
        STDDEV(time_to_convert) as conversion_speed_variance,
        SUM(revenue) as total_revenue,
        COUNT(DISTINCT campaign_id) as campaigns_affected,
        COUNT(DISTINCT geo_country) as countries_used,
        ARRAY_AGG(DISTINCT device_type) as device_types,
        -- Calculate suspicious patterns
        SUM(CASE WHEN time_to_convert < 2 THEN 1 ELSE 0 END) as instant_conversions,
        SUM(CASE WHEN time_to_convert BETWEEN 2 AND 5 THEN 1 ELSE 0 END) as fast_conversions,
        -- Statistical anomaly detection
        AVG(time_to_convert) - 2 * STDDEV(time_to_convert) as lower_bound
    FROM Click_Conversion_Match
    GROUP BY ip_address
    -- Minimum threshold to establish pattern
    HAVING COUNT(click_id) > 5
)
SELECT 
    ip_address,
    total_conversions,
    ROUND(avg_conversion_speed_seconds::numeric, 2) as avg_conversion_speed,
    ROUND(fastest_conversion_seconds::numeric, 2) as fastest_conversion,
    total_revenue,
    campaigns_affected,
    countries_used,
    device_types,
    instant_conversions,
    fast_conversions,
    -- Business Logic: Risk Classification
    CASE 
        WHEN avg_conversion_speed_seconds < 2 THEN 'CRITICAL: BOT NETWORK'
        WHEN avg_conversion_speed_seconds < 5 THEN 'SUSPICIOUS: CLICK FARM'
        WHEN instant_conversions > total_conversions * 0.5 THEN 'HIGH RISK: Mixed Pattern'
        ELSE 'LEGITIMATE'
    END as fraud_status,
    -- Calculate fraud confidence score (0-100)
    LEAST(100, GREATEST(0,
        (100 - ROUND(avg_conversion_speed_seconds * 10)) + 
        (instant_conversions * 10) +
        CASE WHEN countries_used > 5 THEN 20 ELSE 0 END +
        CASE WHEN conversion_speed_variance < 1 THEN 15 ELSE 0 END  -- Too consistent = scripted
    )) as fraud_confidence_score,
    -- Calculate potential fraud loss
    CASE 
        WHEN avg_conversion_speed_seconds < 2 THEN ROUND(total_revenue::numeric, 2)
        WHEN avg_conversion_speed_seconds < 5 THEN ROUND((total_revenue * 0.7)::numeric, 2)
        ELSE 0
    END as estimated_fraud_amount,
    -- Add evidence for review
    JSONB_BUILD_OBJECT(
        'avg_speed', ROUND(avg_conversion_speed_seconds::numeric, 2),
        'instant_count', instant_conversions,
        'revenue_at_risk', total_revenue,
        'geographic_hops', countries_used,
        'device_diversity', ARRAY_LENGTH(device_types, 1)
    ) as evidence
FROM IP_Fraud_Metrics
WHERE avg_conversion_speed_seconds < 10  -- Only flag suspicious IPs
ORDER BY fraud_confidence_score DESC, avg_conversion_speed_seconds ASC
LIMIT 500;

-- Performance Explanation:
-- This query is efficient because:
-- 1. Uses indexed timestamp columns for join
-- 2. Filters to recent data (7 days) to limit scan
-- 3. Groups by IP (typically small cardinality in fraud cases)
-- 4. Uses INNER JOIN (only rows with conversions)

-- =====================================================
-- QUERY 2: BURST PATTERN DETECTION (Sliding Window)
-- =====================================================
-- Detects IPs generating unnatural click volumes in short time windows
-- Uses advanced window functions to count clicks in rolling time periods

WITH Click_Windows AS (
    SELECT 
        click_id,
        ip_address,
        user_id,
        campaign_id,
        timestamp,
        device_type,
        geo_country,
        user_agent,
        -- Sliding window: count clicks in last 10 seconds
        COUNT(*) OVER (
            PARTITION BY ip_address 
            ORDER BY timestamp 
            RANGE BETWEEN INTERVAL '10 seconds' PRECEDING AND CURRENT ROW
        ) as clicks_in_10sec,
        -- Also check 1-minute window
        COUNT(*) OVER (
            PARTITION BY ip_address 
            ORDER BY timestamp 
            RANGE BETWEEN INTERVAL '1 minute' PRECEDING AND CURRENT ROW
        ) as clicks_in_1min,
        -- Check 5-minute window for sustained attacks
        COUNT(*) OVER (
            PARTITION BY ip_address 
            ORDER BY timestamp 
            RANGE BETWEEN INTERVAL '5 minutes' PRECEDING AND CURRENT ROW
        ) as clicks_in_5min,
        -- Calculate time since last click from same IP
        EXTRACT(EPOCH FROM (
            timestamp - LAG(timestamp) OVER (PARTITION BY ip_address ORDER BY timestamp)
        )) as seconds_since_last_click
    FROM click_stream
    WHERE timestamp >= NOW() - INTERVAL '1 hour'  -- Focus on recent activity
),
Burst_IPs AS (
    SELECT 
        ip_address,
        MAX(clicks_in_10sec) as max_burst_10sec,
        MAX(clicks_in_1min) as max_burst_1min,
        MAX(clicks_in_5min) as max_burst_5min,
        COUNT(DISTINCT click_id) as total_clicks,
        COUNT(DISTINCT campaign_id) as campaigns_targeted,
        COUNT(DISTINCT geo_country) as countries_used,
        MIN(seconds_since_last_click) as fastest_click_interval,
        AVG(seconds_since_last_click) as avg_click_interval,
        -- Count how many times they exceeded burst threshold
        COUNT(*) FILTER (WHERE clicks_in_10sec > 50) as burst_events,
        -- Identify time period of attack
        MIN(timestamp) as attack_start,
        MAX(timestamp) as attack_end,
        COUNT(DISTINCT DATE_TRUNC('minute', timestamp)) as active_minutes
    FROM Click_Windows
    WHERE 
        -- Flag IPs that exceeded any threshold
        clicks_in_10sec > 50 
        OR clicks_in_1min > 200 
        OR clicks_in_5min > 500
    GROUP BY ip_address
),
Enriched_Bursts AS (
    SELECT 
        b.*,
        -- Check if IP is in blacklist
        bl.threat_type as blacklist_threat_type,
        bl.severity as blacklist_severity,
        COALESCE(bl.is_active, false) as is_blacklisted,
        -- Get sample of user agents used
        ARRAY_AGG(DISTINCT cw.user_agent) as user_agents_sample,
        -- Calculate attack duration
        EXTRACT(EPOCH FROM (b.attack_end - b.attack_start)) as attack_duration_seconds
    FROM Burst_IPs b
    LEFT JOIN bot_blacklist bl ON b.ip_address = bl.ip_address
    LEFT JOIN Click_Windows cw ON b.ip_address = cw.ip_address
    GROUP BY 
        b.ip_address, b.max_burst_10sec, b.max_burst_1min, b.max_burst_5min,
        b.total_clicks, b.campaigns_targeted, b.countries_used,
        b.fastest_click_interval, b.avg_click_interval, b.burst_events,
        b.attack_start, b.attack_end, b.active_minutes,
        bl.threat_type, bl.severity, bl.is_active
)
SELECT 
    ip_address,
    max_burst_10sec,
    max_burst_1min,
    max_burst_5min,
    total_clicks,
    campaigns_targeted,
    burst_events,
    ROUND(fastest_click_interval::numeric, 3) as fastest_click_interval_sec,
    ROUND(avg_click_interval::numeric, 3) as avg_click_interval_sec,
    ROUND(attack_duration_seconds::numeric, 0) as attack_duration_sec,
    active_minutes,
    COALESCE(blacklist_threat_type, 'NEW_THREAT') as threat_classification,
    COALESCE(blacklist_severity, 'UNKNOWN') as severity,
    is_blacklisted,
    -- Calculate fraud confidence score (0-100)
    LEAST(100, GREATEST(0,
        CASE 
            WHEN max_burst_10sec > 200 THEN 100
            WHEN max_burst_10sec > 100 THEN 90
            WHEN max_burst_10sec > 75 THEN 80
            WHEN max_burst_10sec > 50 THEN 70
            ELSE 50
        END +
        CASE WHEN is_blacklisted THEN 20 ELSE 0 END +
        CASE WHEN fastest_click_interval < 0.1 THEN 10 ELSE 0 END +  -- Superhuman speed
        CASE WHEN campaigns_targeted > 10 THEN 10 ELSE 0 END  -- Spraying multiple campaigns
    )) as fraud_confidence_score,
    -- Evidence
    JSONB_BUILD_OBJECT(
        'max_burst', max_burst_10sec,
        'total_clicks', total_clicks,
        'campaigns', campaigns_targeted,
        'duration', ROUND(attack_duration_seconds, 0),
        'avg_interval', ROUND(avg_click_interval::numeric, 3),
        'user_agents', user_agents_sample
    ) as evidence,
    attack_start,
    attack_end
FROM Enriched_Bursts
ORDER BY fraud_confidence_score DESC, max_burst_10sec DESC
LIMIT 500;

-- Why this query is powerful:
-- 1. RANGE BETWEEN: True sliding window over time (not row-based)
-- 2. Multiple time windows: Catches both flash attacks and sustained attacks
-- 3. LAG function: Detects superhuman click speeds
-- 4. Enrichment: Correlates with blacklist data
-- 5. Flexible scoring: Combines multiple signals

-- =====================================================
-- QUERY 3: GEOGRAPHIC ANOMALY DETECTION
-- =====================================================
-- Detects impossible travel patterns (user in NYC then Tokyo in 5 minutes)

WITH Click_Sequence AS (
    SELECT 
        user_id,
        click_id,
        ip_address,
        geo_country,
        geo_city,
        geo_latitude,
        geo_longitude,
        timestamp,
        device_type,
        -- Get previous location
        LAG(geo_country) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_country,
        LAG(geo_city) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_city,
        LAG(geo_latitude) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_lat,
        LAG(geo_longitude) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_lon,
        LAG(timestamp) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_timestamp,
        LAG(ip_address) OVER (PARTITION BY user_id ORDER BY timestamp) as prev_ip
    FROM click_stream
    WHERE 
        timestamp >= NOW() - INTERVAL '24 hours'
        AND geo_country IS NOT NULL
        AND geo_latitude IS NOT NULL
        AND geo_longitude IS NOT NULL
),
Geographic_Anomalies AS (
    SELECT 
        user_id,
        click_id,
        ip_address,
        geo_country,
        geo_city,
        prev_country,
        prev_city,
        timestamp,
        prev_timestamp,
        -- Calculate time between clicks
        EXTRACT(EPOCH FROM (timestamp - prev_timestamp)) / 60 as minutes_between,
        -- Calculate approximate distance using Haversine formula (simplified)
        -- For production, use PostGIS extension for accurate calculations
        111.32 * SQRT(
            POW(geo_latitude - prev_lat, 2) + 
            POW((geo_longitude - prev_lon) * COS(RADIANS(geo_latitude)), 2)
        ) as distance_km,
        device_type,
        -- Flag impossible travel
        CASE 
            -- International travel in < 1 hour
            WHEN geo_country != prev_country 
                 AND EXTRACT(EPOCH FROM (timestamp - prev_timestamp)) < 3600 
            THEN 'IMPOSSIBLE_INTERNATIONAL'
            -- Different city in < 30 minutes
            WHEN geo_city != prev_city 
                 AND EXTRACT(EPOCH FROM (timestamp - prev_timestamp)) < 1800 
            THEN 'SUSPICIOUS_DOMESTIC'
            -- Same user, different IP, same location (proxy rotation)
            WHEN ip_address != prev_ip 
                 AND geo_city = prev_city 
                 AND EXTRACT(EPOCH FROM (timestamp - prev_timestamp)) < 300
            THEN 'PROXY_ROTATION'
            ELSE 'NORMAL'
        END as anomaly_type
    FROM Click_Sequence
    WHERE prev_country IS NOT NULL
),
User_Anomaly_Summary AS (
    SELECT 
        user_id,
        COUNT(*) as total_anomalies,
        -- Create travel pattern string
        STRING_AGG(
            DISTINCT CONCAT(prev_country, ' → ', geo_country), 
            ' | ' 
            ORDER BY CONCAT(prev_country, ' → ', geo_country)
        ) as travel_pattern,
        STRING_AGG(
            DISTINCT CONCAT(prev_city, ' → ', geo_city),
            ' | '
            ORDER BY CONCAT(prev_city, ' → ', geo_city)
        ) as city_pattern,
        MIN(minutes_between) as fastest_travel_minutes,
        MAX(distance_km) as max_distance_km,
        AVG(distance_km) as avg_distance_km,
        anomaly_type,
        ARRAY_AGG(DISTINCT ip_address) as ip_addresses_used,
        COUNT(DISTINCT ip_address) as unique_ips,
        MIN(timestamp) as first_anomaly,
        MAX(timestamp) as last_anomaly
    FROM Geographic_Anomalies
    WHERE anomaly_type != 'NORMAL'
    GROUP BY user_id, anomaly_type
    HAVING COUNT(*) >= 2  -- At least 2 anomalies to establish pattern
)
SELECT 
    user_id,
    total_anomalies,
    anomaly_type,
    travel_pattern,
    city_pattern,
    ROUND(fastest_travel_minutes::numeric, 1) as fastest_travel_min,
    ROUND(max_distance_km::numeric, 0) as max_distance_km,
    unique_ips,
    -- Calculate fraud score
    LEAST(100, 
        CASE anomaly_type
            WHEN 'IMPOSSIBLE_INTERNATIONAL' THEN 90
            WHEN 'PROXY_ROTATION' THEN 85
            WHEN 'SUSPICIOUS_DOMESTIC' THEN 65
            ELSE 50
        END +
        CASE WHEN unique_ips > 5 THEN 10 ELSE 0 END +
        CASE WHEN total_anomalies > 10 THEN 10 ELSE 0 END
    ) as fraud_confidence_score,
    -- Evidence
    JSONB_BUILD_OBJECT(
        'anomaly_count', total_anomalies,
        'travel_pattern', travel_pattern,
        'fastest_travel', ROUND(fastest_travel_minutes::numeric, 1),
        'ip_count', unique_ips,
        'max_distance', ROUND(max_distance_km::numeric, 0)
    ) as evidence,
    first_anomaly,
    last_anomaly
FROM User_Anomaly_Summary
ORDER BY fraud_confidence_score DESC, total_anomalies DESC
LIMIT 500;

-- Advanced features:
-- 1. LAG function: Access previous row data in partition
-- 2. Haversine calculation: Distance between geographic coordinates
-- 3. String aggregation: Create readable travel patterns
-- 4. Multi-criteria fraud scoring
-- 5. Time-series analysis per user

-- =====================================================
-- QUERY 4: CAMPAIGN ATTRIBUTION & CLEAN ROI ANALYSIS
-- =====================================================
-- Calculate true ROI by removing fraudulent clicks from attribution

WITH Campaign_Performance AS (
    SELECT 
        c.campaign_id,
        cb.campaign_name,
        cb.advertiser_name,
        cb.cost_per_click,
        cb.daily_budget,
        -- Click metrics
        COUNT(DISTINCT c.click_id) as total_clicks,
        COUNT(DISTINCT c.ip_address) as unique_ips,
        -- Conversion metrics (with proper attribution)
        COUNT(DISTINCT cv.conversion_id) as total_conversions,
        SUM(cv.revenue) as total_revenue,
        -- Financial calculations
        COUNT(DISTINCT c.click_id) * cb.cost_per_click as total_cost,
        AVG(EXTRACT(EPOCH FROM (cv.timestamp - c.timestamp))) as avg_time_to_conversion
    FROM click_stream c
    INNER JOIN campaign_budgets cb ON c.campaign_id = cb.campaign_id
    LEFT JOIN conversion_stream cv 
        ON c.user_id = cv.user_id
        AND cv.timestamp > c.timestamp
        AND cv.timestamp <= c.timestamp + INTERVAL '1 hour'  -- Attribution window
    WHERE 
        c.timestamp >= NOW() - INTERVAL '7 days'
        AND cb.status = 'active'
    GROUP BY 
        c.campaign_id, 
        cb.campaign_name, 
        cb.advertiser_name,
        cb.cost_per_click,
        cb.daily_budget
),
Identified_Fraud_Clicks AS (
    -- Combine multiple fraud detection methods
    SELECT DISTINCT c.click_id, c.campaign_id
    FROM click_stream c
    LEFT JOIN bot_blacklist bl ON c.ip_address = bl.ip_address
    WHERE c.timestamp >= NOW() - INTERVAL '7 days'
        AND (
            -- Blacklisted IP
            bl.is_active = true
            -- High fraud score
            OR c.fraud_score > 75
            -- Flagged as suspicious
            OR c.is_suspicious = true
        )
),
Fraud_Impact_By_Campaign AS (
    SELECT 
        campaign_id,
        COUNT(*) as fraud_clicks,
        COUNT(*) * AVG(cost_per_click) OVER (PARTITION BY campaign_id) as fraud_cost
    FROM Identified_Fraud_Clicks fc
    JOIN campaign_budgets cb USING (campaign_id)
    GROUP BY campaign_id
),
Clean_Metrics AS (
    SELECT 
        cp.*,
        COALESCE(fi.fraud_clicks, 0) as fraud_clicks,
        COALESCE(fi.fraud_cost, 0) as fraud_cost,
        -- Calculate clean metrics
        cp.total_clicks - COALESCE(fi.fraud_clicks, 0) as clean_clicks,
        cp.total_cost - COALESCE(fi.fraud_cost, 0) as clean_cost
    FROM Campaign_Performance cp
    LEFT JOIN Fraud_Impact_By_Campaign fi ON cp.campaign_id = fi.campaign_id
)
SELECT 
    campaign_id,
    campaign_name,
    advertiser_name,
    -- Raw metrics
    total_clicks,
    unique_ips,
    fraud_clicks,
    clean_clicks,
    total_conversions,
    ROUND(total_revenue::numeric, 2) as total_revenue,
    -- Cost breakdown
    ROUND(total_cost::numeric, 2) as total_cost,
    ROUND(fraud_cost::numeric, 2) as fraud_cost,
    ROUND(clean_cost::numeric, 2) as clean_cost,
    -- Savings
    ROUND(fraud_cost::numeric, 2) as estimated_savings,
    -- Fraud percentage
    CASE 
        WHEN total_clicks > 0 THEN ROUND((fraud_clicks::numeric / total_clicks * 100), 2)
        ELSE 0 
    END as fraud_percentage,
    -- Conversion rates
    CASE 
        WHEN clean_clicks > 0 THEN ROUND((total_conversions::numeric / clean_clicks * 100), 4)
        ELSE 0 
    END as clean_conversion_rate,
    CASE 
        WHEN total_clicks > 0 THEN ROUND((total_conversions::numeric / total_clicks * 100), 4)
        ELSE 0 
    END as reported_conversion_rate,
    -- ROI calculations (Clean = fraud removed)
    CASE 
        WHEN clean_cost > 0 
        THEN ROUND(((total_revenue - clean_cost) / clean_cost * 100)::numeric, 2)
        ELSE 0
    END as clean_roi_percentage,
    -- ROI with fraud (what would be reported without detection)
    CASE 
        WHEN total_cost > 0 
        THEN ROUND(((total_revenue - total_cost) / total_cost * 100)::numeric, 2)
        ELSE 0
    END as reported_roi_percentage,
    -- Return on Ad Spend (ROAS)
    CASE 
        WHEN clean_cost > 0 THEN ROUND((total_revenue / clean_cost)::numeric, 2)
        ELSE 0
    END as clean_roas,
    -- CPA (Cost Per Acquisition)
    CASE 
        WHEN total_conversions > 0 THEN ROUND((clean_cost / total_conversions)::numeric, 2)
        ELSE 0
    END as clean_cpa,
    -- Average time to conversion
    ROUND(avg_time_to_conversion::numeric, 0) as avg_seconds_to_conversion,
    -- Budget utilization
    ROUND((clean_cost / daily_budget * 100)::numeric, 2) as budget_utilization_pct
FROM Clean_Metrics
WHERE total_clicks > 0
ORDER BY estimated_savings DESC, clean_roi_percentage DESC;

-- Business value:
-- 1. Shows true profitability after removing fraud
-- 2. Quantifies exact savings from fraud detection
-- 3. Provides clean metrics for optimization decisions
-- 4. Compares "reported" vs "actual" performance

-- =====================================================
-- QUERY 5: HOURLY FRAUD TRENDS (Dashboard Query)
-- =====================================================
-- Real-time dashboard showing fraud evolution over time

WITH Hourly_Clicks AS (
    SELECT 
        DATE_TRUNC('hour', timestamp) as hour,
        COUNT(*) as total_clicks,
        COUNT(DISTINCT ip_address) as unique_ips,
        COUNT(DISTINCT campaign_id) as campaigns_affected,
        SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as suspicious_clicks,
        AVG(fraud_score) as avg_fraud_score,
        -- Count specific fraud types
        SUM(CASE WHEN 'burst' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as burst_fraud,
        SUM(CASE WHEN 'instant_conversion' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as conversion_fraud,
        SUM(CASE WHEN 'geo_anomaly' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as geo_fraud,
        SUM(CASE WHEN 'blacklist' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as blacklist_fraud
    FROM click_stream
    WHERE timestamp >= NOW() - INTERVAL '24 hours'
    GROUP BY DATE_TRUNC('hour', timestamp)
),
Hourly_Conversions AS (
    SELECT 
        DATE_TRUNC('hour', timestamp) as hour,
        COUNT(*) as total_conversions,
        SUM(revenue) as total_revenue,
        SUM(CASE WHEN is_suspicious THEN revenue ELSE 0 END) as suspicious_revenue
    FROM conversion_stream
    WHERE timestamp >= NOW() - INTERVAL '24 hours'
    GROUP BY DATE_TRUNC('hour', timestamp)
)
SELECT 
    hc.hour,
    hc.total_clicks,
    hc.unique_ips,
    hc.campaigns_affected,
    hc.suspicious_clicks,
    ROUND(hc.avg_fraud_score::numeric, 2) as avg_fraud_score,
    COALESCE(hcv.total_conversions, 0) as total_conversions,
    ROUND(COALESCE(hcv.total_revenue, 0)::numeric, 2) as total_revenue,
    -- Fraud percentage
    CASE 
        WHEN hc.total_clicks > 0 
        THEN ROUND((hc.suspicious_clicks::numeric / hc.total_clicks * 100), 2)
        ELSE 0 
    END as fraud_percentage,
    -- Fraud type breakdown
    hc.burst_fraud,
    hc.conversion_fraud,
    hc.geo_fraud,
    hc.blacklist_fraud,
    -- Conversion rate
    CASE 
        WHEN hc.total_clicks > 0 
        THEN ROUND((COALESCE(hcv.total_conversions, 0)::numeric / hc.total_clicks * 100), 4)
        ELSE 0 
    END as conversion_rate,
    -- Suspicious revenue
    ROUND(COALESCE(hcv.suspicious_revenue, 0)::numeric, 2) as suspicious_revenue
FROM Hourly_Clicks hc
LEFT JOIN Hourly_Conversions hcv ON hc.hour = hcv.hour
ORDER BY hc.hour DESC;

-- Dashboard value:
-- 1. Shows trends over time (are attacks increasing?)
-- 2. Breaks down fraud by type
-- 3. Correlates clicks with conversions and revenue
-- 4. Perfect for visualization (line charts, bar charts)

-- =====================================================
-- BONUS: UNIFIED FRAUD SCORING VIEW
-- =====================================================
-- Creates a master view combining all fraud signals for each click

CREATE OR REPLACE VIEW v_unified_fraud_scores AS
WITH Fraud_Signals AS (
    SELECT 
        c.click_id,
        c.ip_address,
        c.user_id,
        c.campaign_id,
        c.timestamp,
        -- Signal 1: Blacklist match
        CASE WHEN bl.ip_address IS NOT NULL THEN 30 ELSE 0 END as blacklist_score,
        -- Signal 2: Burst pattern (from window function)
        CASE 
            WHEN c.fraud_reasons @> ARRAY['burst'] THEN 25
            ELSE 0 
        END as burst_score,
        -- Signal 3: Instant conversion
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM conversion_stream cv 
                WHERE cv.user_id = c.user_id 
                    AND cv.timestamp > c.timestamp
                    AND EXTRACT(EPOCH FROM (cv.timestamp - c.timestamp)) < 2
            ) THEN 30
            ELSE 0
        END as conversion_speed_score,
        -- Signal 4: Geographic anomaly
        CASE 
            WHEN c.fraud_reasons @> ARRAY['geo_anomaly'] THEN 20
            ELSE 0 
        END as geo_score,
        -- Signal 5: Suspicious user agent
        CASE 
            WHEN c.user_agent ILIKE '%bot%' 
                OR c.user_agent ILIKE '%crawler%'
                OR c.user_agent ILIKE '%phantom%'
            THEN 15
            ELSE 0
        END as user_agent_score,
        -- Aggregate existing flags
        c.fraud_score as existing_score,
        c.fraud_reasons
    FROM click_stream c
    LEFT JOIN bot_blacklist bl ON c.ip_address = bl.ip_address AND bl.is_active = true
    WHERE c.timestamp >= NOW() - INTERVAL '7 days'
)
SELECT 
    click_id,
    ip_address,
    user_id,
    campaign_id,
    timestamp,
    -- Calculate combined fraud score
    LEAST(100, 
        blacklist_score + 
        burst_score + 
        conversion_speed_score + 
        geo_score + 
        user_agent_score
    ) as computed_fraud_score,
    existing_score,
    -- Fraud classification
    CASE 
        WHEN (blacklist_score + burst_score + conversion_speed_score + geo_score + user_agent_score) >= 75 
        THEN 'HIGH_RISK'
        WHEN (blacklist_score + burst_score + conversion_speed_score + geo_score + user_agent_score) >= 50 
        THEN 'MEDIUM_RISK'
        WHEN (blacklist_score + burst_score + conversion_speed_score + geo_score + user_agent_score) >= 25 
        THEN 'LOW_RISK'
        ELSE 'CLEAN'
    END as risk_category,
    -- Individual signal scores for analysis
    blacklist_score,
    burst_score,
    conversion_speed_score,
    geo_score,
    user_agent_score,
    fraud_reasons
FROM Fraud_Signals
ORDER BY computed_fraud_score DESC;

-- This view provides:
-- 1. Single source of truth for fraud scores
-- 2. Breakdown of contributing factors
-- 3. Easy to query for dashboards
-- 4. Can be materialized for performance

-- =====================================================
-- PERFORMANCE TIPS
-- =====================================================

/*
1. Index Strategy:
   - BRIN indexes on timestamp columns (time-series data)
   - Hash indexes on IP addresses (equality lookups)
   - B-tree indexes on foreign keys
   - GIN indexes on array columns (fraud_reasons)

2. Partitioning:
   - Partition click_stream by day/week for faster queries
   - Archive old data to separate tables

3. Materialized Views:
   - Pre-compute daily/hourly aggregates
   - Refresh on schedule (every 5-15 minutes)

4. Query Optimization:
   - Always filter on timestamp first
   - Use EXISTS instead of IN for subqueries
   - LIMIT results when appropriate
   - Use CTEs for readability and query planning

5. Monitoring:
   - Use EXPLAIN ANALYZE to check query plans
   - Monitor index usage with pg_stat_user_indexes
   - Track table bloat and run VACUUM regularly
*/
