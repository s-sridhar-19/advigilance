-- AdVigilance Database Schema
-- PostgreSQL 14+ optimized for time-series analytics
-- Author: Data Engineering Team
-- Last Updated: 2026-01-28

-- =====================================================
-- DATABASE CONFIGURATION
-- =====================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- For fuzzy string matching
CREATE EXTENSION IF NOT EXISTS "btree_gist"; -- For advanced indexing

-- =====================================================
-- SCHEMA CREATION
-- =====================================================

CREATE SCHEMA IF NOT EXISTS advigilance;
SET search_path TO advigilance, public;

-- =====================================================
-- TABLE 1: CLICK STREAM (Main Event Table)
-- =====================================================

DROP TABLE IF EXISTS click_stream CASCADE;

CREATE TABLE click_stream (
    -- Primary Identifiers
    click_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id VARCHAR(100) NOT NULL,
    session_id VARCHAR(100) NOT NULL,
    
    -- Campaign & Ad Details
    campaign_id INTEGER NOT NULL,
    ad_id VARCHAR(50),
    placement_id VARCHAR(50),
    
    -- Device & User Agent Information
    ip_address INET NOT NULL,
    user_agent TEXT NOT NULL,
    device_type VARCHAR(20), -- mobile, desktop, tablet
    os_name VARCHAR(50),
    browser_name VARCHAR(50),
    browser_version VARCHAR(20),
    
    -- Geographic Data
    geo_country VARCHAR(2), -- ISO 2-letter code
    geo_region VARCHAR(100),
    geo_city VARCHAR(100),
    geo_latitude DECIMAL(10, 8),
    geo_longitude DECIMAL(11, 8),
    
    -- Referrer & Context
    referrer_url TEXT,
    landing_page_url TEXT,
    
    -- Behavioral Signals
    time_on_page INTEGER, -- seconds
    scroll_depth INTEGER, -- percentage (0-100)
    
    -- Timestamp
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    ingestion_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Fraud Flags (populated by detection engine)
    is_suspicious BOOLEAN DEFAULT false,
    fraud_score INTEGER DEFAULT 0, -- 0-100
    fraud_reasons TEXT[], -- array of detection triggers
    
    -- Indexing hints
    CONSTRAINT valid_fraud_score CHECK (fraud_score BETWEEN 0 AND 100),
    CONSTRAINT valid_scroll_depth CHECK (scroll_depth BETWEEN 0 AND 100)
);

-- Create partitions for click_stream (time-series optimization)
-- This enables efficient queries on recent data
CREATE INDEX idx_click_stream_timestamp ON click_stream USING BRIN (timestamp);
CREATE INDEX idx_click_stream_ip ON click_stream USING HASH (ip_address);
CREATE INDEX idx_click_stream_user_id ON click_stream (user_id);
CREATE INDEX idx_click_stream_campaign ON click_stream (campaign_id);
CREATE INDEX idx_click_stream_composite ON click_stream (ip_address, timestamp DESC);

-- GIN index for fraud_reasons array queries
CREATE INDEX idx_click_stream_fraud_reasons ON click_stream USING GIN (fraud_reasons);

COMMENT ON TABLE click_stream IS 'Raw click event data from ad networks';
COMMENT ON COLUMN click_stream.fraud_score IS 'Computed fraud probability (0=clean, 100=definitely fraud)';

-- =====================================================
-- TABLE 2: CONVERSION STREAM
-- =====================================================

DROP TABLE IF EXISTS conversion_stream CASCADE;

CREATE TABLE conversion_stream (
    -- Primary Identifiers
    conversion_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id VARCHAR(100) NOT NULL,
    session_id VARCHAR(100) NOT NULL,
    order_id VARCHAR(100) UNIQUE,
    
    -- Financial Data
    revenue DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    product_category VARCHAR(100),
    
    -- Attribution
    attributed_click_id UUID, -- Foreign key to click_stream
    attribution_model VARCHAR(20) DEFAULT 'last_click', -- last_click, first_click, linear
    
    -- Conversion Details
    conversion_type VARCHAR(50), -- purchase, signup, download
    conversion_funnel_step INTEGER, -- 1=awareness, 2=consideration, 3=conversion
    
    -- Timestamp
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    ingestion_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Fraud Detection
    is_suspicious BOOLEAN DEFAULT false,
    fraud_score INTEGER DEFAULT 0,
    
    CONSTRAINT positive_revenue CHECK (revenue >= 0)
);

CREATE INDEX idx_conversion_stream_timestamp ON conversion_stream USING BRIN (timestamp);
CREATE INDEX idx_conversion_stream_user_id ON conversion_stream (user_id);
CREATE INDEX idx_conversion_stream_attributed_click ON conversion_stream (attributed_click_id);
CREATE INDEX idx_conversion_stream_revenue ON conversion_stream (revenue DESC);

COMMENT ON TABLE conversion_stream IS 'Conversion events (purchases, signups) attributed to ad clicks';

-- =====================================================
-- TABLE 3: BOT BLACKLIST (Threat Intelligence)
-- =====================================================

DROP TABLE IF EXISTS bot_blacklist CASCADE;

CREATE TABLE bot_blacklist (
    -- Primary Key
    blacklist_id SERIAL PRIMARY KEY,
    
    -- Identifier (can be IP, IP range, or user agent pattern)
    ip_address INET,
    ip_range CIDR, -- For IP ranges like 192.168.1.0/24
    user_agent_pattern TEXT,
    
    -- Classification
    threat_type VARCHAR(50) NOT NULL, -- bot_network, click_farm, malware, vpn
    severity VARCHAR(20) NOT NULL DEFAULT 'medium', -- low, medium, high, critical
    confidence_score INTEGER DEFAULT 50, -- 0-100
    
    -- Source & Metadata
    source VARCHAR(100), -- internal, abuseipdb, stopforumspam, etc.
    description TEXT,
    reference_url TEXT,
    
    -- Status
    is_active BOOLEAN DEFAULT true,
    first_seen TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_seen TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reported_by VARCHAR(100),
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT blacklist_has_identifier CHECK (
        ip_address IS NOT NULL OR 
        ip_range IS NOT NULL OR 
        user_agent_pattern IS NOT NULL
    )
);

CREATE INDEX idx_bot_blacklist_ip ON bot_blacklist USING GIST (ip_address inet_ops);
CREATE INDEX idx_bot_blacklist_ip_range ON bot_blacklist USING GIST (ip_range inet_ops);
CREATE INDEX idx_bot_blacklist_user_agent ON bot_blacklist USING GIN (user_agent_pattern gin_trgm_ops);
CREATE INDEX idx_bot_blacklist_active ON bot_blacklist (is_active) WHERE is_active = true;

COMMENT ON TABLE bot_blacklist IS 'Known malicious IPs, IP ranges, and user agent patterns';

-- =====================================================
-- TABLE 4: CAMPAIGN BUDGETS (Reference Data)
-- =====================================================

DROP TABLE IF EXISTS campaign_budgets CASCADE;

CREATE TABLE campaign_budgets (
    -- Primary Key
    campaign_id SERIAL PRIMARY KEY,
    
    -- Campaign Details
    campaign_name VARCHAR(200) NOT NULL,
    advertiser_id INTEGER NOT NULL,
    advertiser_name VARCHAR(200) NOT NULL,
    
    -- Budget & Pricing
    daily_budget DECIMAL(10, 2) NOT NULL,
    total_budget DECIMAL(10, 2),
    cost_per_click DECIMAL(6, 4) NOT NULL, -- CPC in dollars
    max_bid DECIMAL(6, 4),
    
    -- Campaign Configuration
    start_date DATE NOT NULL,
    end_date DATE,
    status VARCHAR(20) DEFAULT 'active', -- active, paused, completed
    
    -- Targeting
    target_geo_countries TEXT[], -- array of country codes
    target_devices TEXT[], -- array: mobile, desktop, tablet
    target_age_range VARCHAR(20), -- e.g., "25-34"
    
    -- Performance Thresholds
    max_cpa DECIMAL(10, 2), -- Cost Per Acquisition
    target_roas DECIMAL(5, 2), -- Return On Ad Spend (e.g., 3.5 = 350%)
    
    -- Fraud Protection Settings
    fraud_protection_enabled BOOLEAN DEFAULT true,
    max_clicks_per_ip_per_day INTEGER DEFAULT 10,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_campaign_budgets_advertiser ON campaign_budgets (advertiser_id);
CREATE INDEX idx_campaign_budgets_status ON campaign_budgets (status) WHERE status = 'active';

COMMENT ON TABLE campaign_budgets IS 'Campaign metadata, budgets, and fraud protection settings';

-- =====================================================
-- TABLE 5: FRAUD EVENTS (Detection Results)
-- =====================================================

DROP TABLE IF EXISTS fraud_events CASCADE;

CREATE TABLE fraud_events (
    -- Primary Key
    event_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- References
    click_id UUID REFERENCES click_stream(click_id),
    conversion_id UUID REFERENCES conversion_stream(conversion_id),
    
    -- Detection Details
    fraud_type VARCHAR(50) NOT NULL, -- burst, instant_conversion, geo_anomaly, blacklist
    detection_method VARCHAR(100) NOT NULL, -- which SQL query detected it
    fraud_score INTEGER NOT NULL,
    
    -- Evidence
    evidence JSONB, -- Flexible storage for detection-specific data
    
    -- Action Taken
    action_taken VARCHAR(50), -- blocked, flagged, whitelisted
    action_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Review
    reviewed_by VARCHAR(100),
    review_decision VARCHAR(20), -- true_positive, false_positive, uncertain
    review_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Timestamps
    detected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT valid_fraud_score CHECK (fraud_score BETWEEN 0 AND 100)
);

CREATE INDEX idx_fraud_events_click ON fraud_events (click_id);
CREATE INDEX idx_fraud_events_fraud_type ON fraud_events (fraud_type);
CREATE INDEX idx_fraud_events_detected_at ON fraud_events (detected_at DESC);
CREATE INDEX idx_fraud_events_evidence ON fraud_events USING GIN (evidence);

COMMENT ON TABLE fraud_events IS 'Log of all detected fraud events with evidence and actions';

-- =====================================================
-- TABLE 6: DAILY AGGREGATES (Pre-computed for dashboards)
-- =====================================================

DROP TABLE IF EXISTS daily_campaign_summary CASCADE;

CREATE TABLE daily_campaign_summary (
    -- Composite Primary Key
    campaign_id INTEGER REFERENCES campaign_budgets(campaign_id),
    report_date DATE NOT NULL,
    
    -- Metrics
    total_clicks INTEGER DEFAULT 0,
    legitimate_clicks INTEGER DEFAULT 0,
    fraudulent_clicks INTEGER DEFAULT 0,
    total_conversions INTEGER DEFAULT 0,
    total_revenue DECIMAL(12, 2) DEFAULT 0,
    total_cost DECIMAL(12, 2) DEFAULT 0,
    
    -- Fraud Statistics
    fraud_percentage DECIMAL(5, 2),
    fraud_cost DECIMAL(10, 2),
    estimated_savings DECIMAL(10, 2),
    
    -- Performance Metrics
    ctr DECIMAL(5, 4), -- Click-Through Rate
    conversion_rate DECIMAL(5, 4),
    cpa DECIMAL(10, 2), -- Cost Per Acquisition
    roas DECIMAL(5, 2), -- Return On Ad Spend
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    PRIMARY KEY (campaign_id, report_date)
);

CREATE INDEX idx_daily_summary_date ON daily_campaign_summary (report_date DESC);

COMMENT ON TABLE daily_campaign_summary IS 'Pre-aggregated daily metrics for fast dashboard queries';

-- =====================================================
-- VIEWS FOR COMMON QUERIES
-- =====================================================

-- View: Real-time fraud dashboard (last 24 hours)
CREATE OR REPLACE VIEW v_realtime_fraud_stats AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as suspicious_clicks,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    COUNT(DISTINCT ip_address) as unique_ips,
    COUNT(DISTINCT campaign_id) as affected_campaigns
FROM click_stream
WHERE timestamp >= NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', timestamp)
ORDER BY hour DESC;

-- View: Top fraud sources
CREATE OR REPLACE VIEW v_top_fraud_sources AS
SELECT 
    ip_address,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    ARRAY_AGG(DISTINCT fraud_reasons) as fraud_patterns,
    MAX(timestamp) as last_seen
FROM click_stream
WHERE is_suspicious = true
    AND timestamp >= NOW() - INTERVAL '7 days'
GROUP BY ip_address
HAVING COUNT(*) >= 10
ORDER BY fraud_clicks DESC
LIMIT 100;

-- =====================================================
-- FUNCTIONS & TRIGGERS
-- =====================================================

-- Function: Update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to relevant tables
CREATE TRIGGER update_campaign_budgets_updated_at
    BEFORE UPDATE ON campaign_budgets
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_bot_blacklist_updated_at
    BEFORE UPDATE ON bot_blacklist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function: Calculate fraud score (simplified example)
CREATE OR REPLACE FUNCTION calculate_fraud_score(
    p_ip_address INET,
    p_clicks_count INTEGER,
    p_conversion_speed NUMERIC
) RETURNS INTEGER AS $$
DECLARE
    v_score INTEGER := 0;
    v_is_blacklisted BOOLEAN;
BEGIN
    -- Check blacklist
    SELECT EXISTS(
        SELECT 1 FROM bot_blacklist 
        WHERE ip_address = p_ip_address 
            AND is_active = true
    ) INTO v_is_blacklisted;
    
    IF v_is_blacklisted THEN
        v_score := v_score + 50;
    END IF;
    
    -- Burst pattern
    IF p_clicks_count > 100 THEN
        v_score := v_score + 40;
    ELSIF p_clicks_count > 50 THEN
        v_score := v_score + 20;
    END IF;
    
    -- Instant conversion
    IF p_conversion_speed IS NOT NULL AND p_conversion_speed < 2 THEN
        v_score := v_score + 30;
    END IF;
    
    -- Cap at 100
    IF v_score > 100 THEN
        v_score := 100;
    END IF;
    
    RETURN v_score;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =====================================================
-- INITIAL DATA LOAD (Sample Bot Blacklist)
-- =====================================================

INSERT INTO bot_blacklist (ip_address, threat_type, severity, source, description) VALUES
    ('192.0.2.1', 'bot_network', 'high', 'internal', 'Known bot farm'),
    ('198.51.100.50', 'click_farm', 'critical', 'abuse_ipdb', 'Commercial click fraud'),
    ('203.0.113.100', 'malware', 'high', 'stopforumspam', 'Malware distribution');

-- Sample IP ranges
INSERT INTO bot_blacklist (ip_range, threat_type, severity, source, description) VALUES
    ('192.0.2.0/24', 'bot_network', 'medium', 'internal', 'Suspicious subnet'),
    ('198.51.100.0/24', 'vpn', 'low', 'internal', 'Known VPN exit nodes');

-- Sample user agent patterns (bots often use outdated browsers)
INSERT INTO bot_blacklist (user_agent_pattern, threat_type, severity, source, description) VALUES
    ('%PhantomJS%', 'bot_network', 'high', 'internal', 'Headless browser automation'),
    ('%curl%', 'bot_network', 'high', 'internal', 'Command-line tool abuse'),
    ('%Python-urllib%', 'bot_network', 'medium', 'internal', 'Python script automation');

-- =====================================================
-- SAMPLE CAMPAIGNS
-- =====================================================

INSERT INTO campaign_budgets (
    campaign_name, 
    advertiser_id, 
    advertiser_name, 
    daily_budget, 
    total_budget,
    cost_per_click, 
    start_date, 
    end_date,
    target_geo_countries,
    target_devices
) VALUES
    ('Summer Sale 2026', 1001, 'Acme Corp', 5000.00, 150000.00, 0.75, '2026-01-01', '2026-03-31', 
     ARRAY['US', 'CA', 'GB'], ARRAY['mobile', 'desktop']),
    ('Black Friday Preview', 1002, 'TechGear Inc', 10000.00, 300000.00, 1.20, '2026-01-15', '2026-02-28',
     ARRAY['US'], ARRAY['mobile']),
    ('Brand Awareness Campaign', 1003, 'FashionHub', 2000.00, 60000.00, 0.45, '2026-01-01', '2026-12-31',
     ARRAY['US', 'CA', 'GB', 'AU'], ARRAY['desktop', 'tablet']);

-- =====================================================
-- GRANT PERMISSIONS (Adjust as needed)
-- =====================================================

-- Create read-only role for analysts
CREATE ROLE analyst_readonly;
GRANT USAGE ON SCHEMA advigilance TO analyst_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA advigilance TO analyst_readonly;

-- Create read-write role for fraud detection engine
CREATE ROLE fraud_detector;
GRANT USAGE ON SCHEMA advigilance TO fraud_detector;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA advigilance TO fraud_detector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA advigilance TO fraud_detector;

-- =====================================================
-- MAINTENANCE SETUP
-- =====================================================

-- Automatically vacuum and analyze tables nightly
-- (This should be configured in postgresql.conf or via cron)

-- Example: Create a maintenance function
CREATE OR REPLACE FUNCTION maintain_click_stream() RETURNS void AS $$
BEGIN
    -- Delete clicks older than 90 days
    DELETE FROM click_stream WHERE timestamp < NOW() - INTERVAL '90 days';
    
    -- Analyze table for query planner
    ANALYZE click_stream;
    
    RAISE NOTICE 'Click stream maintenance completed at %', NOW();
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION maintain_click_stream IS 'Scheduled maintenance: purge old data and update statistics';

-- =====================================================
-- SCHEMA COMPLETE
-- =====================================================

-- Verify tables created
SELECT table_name, 
       pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) as size
FROM information_schema.tables
WHERE table_schema = 'advigilance'
ORDER BY table_name;

-- Display indexes
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'advigilance'
ORDER BY tablename, indexname;
