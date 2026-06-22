# AdVigilance: SQL Performance & Optimization Guide

## Table of Contents
1. [Index Strategy](#index-strategy)
2. [Partitioning](#partitioning)
3. [Query Optimization](#query-optimization)
4. [Monitoring & Maintenance](#monitoring-maintenance)
5. [Scaling Strategies](#scaling-strategies)

---

## Index Strategy

### Overview
Proper indexing is critical for AdVigilance's performance. With millions of clicks per day, poorly indexed queries can take minutes instead of milliseconds.

### Recommended Indexes

#### Click Stream Table
```sql
-- BRIN index for timestamp (time-series optimization)
CREATE INDEX idx_click_stream_timestamp ON click_stream USING BRIN (timestamp);

-- Hash index for IP lookups (faster than B-tree for equality)
CREATE INDEX idx_click_stream_ip ON click_stream USING HASH (ip_address);

-- B-tree indexes for foreign keys and sorting
CREATE INDEX idx_click_stream_user_id ON click_stream (user_id);
CREATE INDEX idx_click_stream_campaign ON click_stream (campaign_id);

-- Composite index for common query patterns
CREATE INDEX idx_click_stream_composite ON click_stream (ip_address, timestamp DESC);

-- Partial index for suspicious clicks only
CREATE INDEX idx_click_stream_suspicious ON click_stream (ip_address, fraud_score) 
WHERE is_suspicious = true;

-- GIN index for array searches
CREATE INDEX idx_click_stream_fraud_reasons ON click_stream USING GIN (fraud_reasons);
```

**Why BRIN for timestamp?**
- BRIN (Block Range Index) is perfect for naturally ordered data
- Uses 100-1000x less space than B-tree
- Ideal for time-series data that's inserted sequentially
- Queries like `WHERE timestamp > NOW() - INTERVAL '1 hour'` are extremely fast

**Why Hash for IP address?**
- Hash indexes are faster than B-tree for equality comparisons (`WHERE ip_address = '1.2.3.4'`)
- Smaller size than B-tree
- Cannot be used for range queries (but we don't need that for IPs)

#### Conversion Stream Table
```sql
CREATE INDEX idx_conversion_stream_timestamp ON conversion_stream USING BRIN (timestamp);
CREATE INDEX idx_conversion_stream_user_id ON conversion_stream (user_id);
CREATE INDEX idx_conversion_stream_attributed_click ON conversion_stream (attributed_click_id);
CREATE INDEX idx_conversion_stream_revenue ON conversion_stream (revenue DESC);
```

#### Bot Blacklist Table
```sql
-- GIST index for IP range queries (inet_ops for CIDR matching)
CREATE INDEX idx_bot_blacklist_ip ON bot_blacklist USING GIST (ip_address inet_ops);
CREATE INDEX idx_bot_blacklist_ip_range ON bot_blacklist USING GIST (ip_range inet_ops);

-- GIN index for pattern matching in user agents
CREATE INDEX idx_bot_blacklist_user_agent ON bot_blacklist 
USING GIN (user_agent_pattern gin_trgm_ops);

-- Partial index for active blacklist entries only
CREATE INDEX idx_bot_blacklist_active ON bot_blacklist (ip_address) 
WHERE is_active = true;
```

### Index Maintenance

```sql
-- Check index usage statistics
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan as index_scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'advigilance'
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;

-- Find unused indexes (candidates for removal)
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'advigilance'
    AND idx_scan = 0
    AND indexrelname NOT LIKE '%_pkey'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Rebuild bloated indexes
REINDEX INDEX CONCURRENTLY idx_click_stream_timestamp;
```

---

## Partitioning

### Why Partition?
With time-series data growing daily, partitioning by date:
1. **Improves query performance** - PostgreSQL can skip entire partitions
2. **Simplifies data management** - Drop old partitions instead of DELETE
3. **Enables parallel queries** - Each partition can be scanned independently

### Partitioning Strategy for Click Stream

```sql
-- Step 1: Drop existing table and recreate as partitioned
-- WARNING: Only do this on initial setup!

DROP TABLE IF EXISTS click_stream CASCADE;

CREATE TABLE click_stream (
    click_id UUID DEFAULT uuid_generate_v4(),
    user_id VARCHAR(100) NOT NULL,
    session_id VARCHAR(100) NOT NULL,
    campaign_id INTEGER NOT NULL,
    ad_id VARCHAR(50),
    placement_id VARCHAR(50),
    ip_address INET NOT NULL,
    user_agent TEXT NOT NULL,
    device_type VARCHAR(20),
    os_name VARCHAR(50),
    browser_name VARCHAR(50),
    browser_version VARCHAR(20),
    geo_country VARCHAR(2),
    geo_region VARCHAR(100),
    geo_city VARCHAR(100),
    geo_latitude DECIMAL(10, 8),
    geo_longitude DECIMAL(11, 8),
    referrer_url TEXT,
    landing_page_url TEXT,
    time_on_page INTEGER,
    scroll_depth INTEGER,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    ingestion_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_suspicious BOOLEAN DEFAULT false,
    fraud_score INTEGER DEFAULT 0,
    fraud_reasons TEXT[],
    
    -- Constraints
    CONSTRAINT valid_fraud_score CHECK (fraud_score BETWEEN 0 AND 100),
    CONSTRAINT valid_scroll_depth CHECK (scroll_depth BETWEEN 0 AND 100)
) PARTITION BY RANGE (timestamp);

-- Create partitions for each week
CREATE TABLE click_stream_2026_w01 PARTITION OF click_stream
    FOR VALUES FROM ('2026-01-01') TO ('2026-01-08');

CREATE TABLE click_stream_2026_w02 PARTITION OF click_stream
    FOR VALUES FROM ('2026-01-08') TO ('2026-01-15');

CREATE TABLE click_stream_2026_w03 PARTITION OF click_stream
    FOR VALUES FROM ('2026-01-15') TO ('2026-01-22');

-- Create indexes on each partition (happens automatically for UNIQUE/PRIMARY KEY)
CREATE INDEX ON click_stream_2026_w01 (ip_address);
CREATE INDEX ON click_stream_2026_w02 (ip_address);
CREATE INDEX ON click_stream_2026_w03 (ip_address);

-- Automated partition creation function
CREATE OR REPLACE FUNCTION create_click_stream_partition()
RETURNS void AS $$
DECLARE
    partition_start DATE;
    partition_end DATE;
    partition_name TEXT;
BEGIN
    -- Create partition for next week
    partition_start := DATE_TRUNC('week', NOW() + INTERVAL '1 week');
    partition_end := partition_start + INTERVAL '1 week';
    partition_name := 'click_stream_' || TO_CHAR(partition_start, 'YYYY_wIW');
    
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF click_stream FOR VALUES FROM (%L) TO (%L)',
        partition_name, partition_start, partition_end);
    
    EXECUTE format('CREATE INDEX ON %I (ip_address)', partition_name);
    EXECUTE format('CREATE INDEX ON %I (campaign_id)', partition_name);
    
    RAISE NOTICE 'Created partition % for % to %', partition_name, partition_start, partition_end;
END;
$$ LANGUAGE plpgsql;

-- Schedule with pg_cron (install extension first)
-- SELECT cron.schedule('create-partitions', '0 0 * * 0', 'SELECT create_click_stream_partition()');
```

### Partition Pruning Verification

```sql
-- Verify partition pruning is working
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM click_stream
WHERE timestamp >= '2026-01-15'
    AND timestamp < '2026-01-16';

-- Look for "Partitions removed: N" in output
```

---

## Query Optimization

### 1. Use EXPLAIN ANALYZE

```sql
-- Always check query plans
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT 
    ip_address,
    COUNT(*) as clicks
FROM click_stream
WHERE timestamp >= NOW() - INTERVAL '1 hour'
GROUP BY ip_address
HAVING COUNT(*) > 50;

-- Key metrics to watch:
-- - Planning Time: Should be < 5ms
-- - Execution Time: Goal depends on query, but < 100ms for dashboard queries
-- - Buffers: Look for "Buffers: shared hit=X read=Y" - high "read" means cache misses
-- - Parallel Workers: More workers = better utilization of CPU cores
```

### 2. Query Rewriting Techniques

#### Bad: Using IN with subquery
```sql
-- Slow for large subqueries
SELECT * FROM click_stream
WHERE ip_address IN (
    SELECT ip_address FROM bot_blacklist WHERE is_active = true
);
```

#### Good: Using EXISTS
```sql
-- Faster - stops searching after first match
SELECT * FROM click_stream c
WHERE EXISTS (
    SELECT 1 FROM bot_blacklist bl
    WHERE bl.ip_address = c.ip_address
        AND bl.is_active = true
);
```

#### Better: Using JOIN
```sql
-- Usually fastest - single table scan
SELECT DISTINCT c.*
FROM click_stream c
INNER JOIN bot_blacklist bl ON c.ip_address = bl.ip_address
WHERE bl.is_active = true;
```

### 3. Limit Early, Aggregate Late

#### Bad: Filtering after aggregation
```sql
SELECT ip_address, COUNT(*) as clicks
FROM click_stream
GROUP BY ip_address
HAVING clicks > 50;  -- PostgreSQL must compute ALL groups first
```

#### Good: Filter before aggregation when possible
```sql
WITH Recent_Clicks AS (
    SELECT ip_address
    FROM click_stream
    WHERE timestamp >= NOW() - INTERVAL '1 hour'  -- Limit data early
)
SELECT ip_address, COUNT(*) as clicks
FROM Recent_Clicks
GROUP BY ip_address
HAVING COUNT(*) > 50;
```

### 4. Avoid SELECT *

```sql
-- Bad: Fetches all columns (including large TEXT fields)
SELECT * FROM click_stream WHERE ip_address = '1.2.3.4';

-- Good: Select only needed columns
SELECT click_id, timestamp, campaign_id, fraud_score
FROM click_stream
WHERE ip_address = '1.2.3.4';
```

### 5. Use Covering Indexes

```sql
-- Create index that includes all columns needed by query
CREATE INDEX idx_click_stream_covering ON click_stream 
    (ip_address, timestamp) 
    INCLUDE (campaign_id, fraud_score);

-- Now this query can be answered entirely from index (Index Only Scan)
SELECT timestamp, campaign_id, fraud_score
FROM click_stream
WHERE ip_address = '1.2.3.4';
```

### 6. Batch Updates/Inserts

```sql
-- Bad: Individual inserts (slow)
INSERT INTO click_stream (...) VALUES (...);
INSERT INTO click_stream (...) VALUES (...);
-- ... repeated 10,000 times

-- Good: Batch insert
INSERT INTO click_stream (...)
VALUES
    (...),
    (...),
    -- ... up to 1,000 rows per statement
ON CONFLICT DO NOTHING;

-- Best: Use COPY for bulk loading
COPY click_stream FROM '/path/to/data.csv' CSV HEADER;
```

---

## Monitoring & Maintenance

### Database Statistics

```sql
-- Table sizes and bloat
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) as index_size,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows,
    ROUND(n_dead_tup * 100.0 / GREATEST(n_live_tup, 1), 2) as dead_row_percent
FROM pg_stat_user_tables
WHERE schemaname = 'advigilance'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Identify tables needing VACUUM
SELECT 
    schemaname,
    tablename,
    n_dead_tup,
    n_live_tup,
    ROUND(n_dead_tup * 100.0 / GREATEST(n_live_tup, 1), 2) as dead_row_percent
FROM pg_stat_user_tables
WHERE schemaname = 'advigilance'
    AND n_dead_tup > 1000
ORDER BY dead_row_percent DESC;
```

### Automated Maintenance

```sql
-- Configure autovacuum (in postgresql.conf or per table)
ALTER TABLE click_stream SET (
    autovacuum_vacuum_scale_factor = 0.05,  -- Trigger vacuum at 5% dead rows
    autovacuum_analyze_scale_factor = 0.02, -- Trigger analyze at 2% changed rows
    autovacuum_vacuum_cost_delay = 10       -- Slow down vacuum to reduce I/O impact
);

-- Manual vacuum (use during off-peak hours)
VACUUM ANALYZE click_stream;

-- Aggressive vacuum to reclaim disk space
VACUUM FULL ANALYZE click_stream;  -- WARNING: Takes exclusive lock!
```

### Query Performance Monitoring

```sql
-- Install pg_stat_statements extension
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Find slowest queries
SELECT 
    query,
    calls,
    ROUND(total_exec_time::numeric, 2) as total_time_ms,
    ROUND(mean_exec_time::numeric, 2) as avg_time_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_time_ms,
    ROUND((100 * total_exec_time / SUM(total_exec_time) OVER())::numeric, 2) as pct_total_time
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 20;

-- Reset statistics
SELECT pg_stat_statements_reset();
```

---

## Scaling Strategies

### Vertical Scaling (Single Server)

1. **Increase shared_buffers** (25% of RAM)
   ```
   shared_buffers = 8GB
   ```

2. **Increase work_mem** (for complex queries)
   ```
   work_mem = 256MB  # Per query operation!
   ```

3. **Enable parallel query execution**
   ```
   max_parallel_workers_per_gather = 4
   max_parallel_workers = 8
   ```

4. **Optimize for SSDs**
   ```
   random_page_cost = 1.1  # Default is 4.0 for spinning disks
   effective_io_concurrency = 200
   ```

### Horizontal Scaling (Multiple Servers)

#### Read Replicas
```
Primary Server: Handles all writes
├── Replica 1: Dashboard queries
├── Replica 2: Fraud detection analytics
└── Replica 3: Report generation
```

#### Time-Based Sharding
```
Server 1: Recent data (last 7 days) - hot data
Server 2: Historical data (7-90 days) - warm data
Server 3: Archive (> 90 days) - cold data
```

### Caching Strategies

#### Materialized Views
```sql
-- Pre-compute hourly aggregates
CREATE MATERIALIZED VIEW mv_hourly_fraud_stats AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    AVG(fraud_score) as avg_fraud_score
FROM click_stream
GROUP BY DATE_TRUNC('hour', timestamp);

-- Create index on materialized view
CREATE INDEX ON mv_hourly_fraud_stats (hour DESC);

-- Refresh every 5 minutes (can be scheduled with pg_cron)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_hourly_fraud_stats;
```

#### Application-Level Caching (Redis)
```python
import redis

cache = redis.Redis(host='localhost', port=6379)

def get_fraud_stats():
    # Try cache first
    cached = cache.get('fraud_stats')
    if cached:
        return json.loads(cached)
    
    # Query database
    stats = db.execute(fraud_query).fetchall()
    
    # Cache for 60 seconds
    cache.setex('fraud_stats', 60, json.dumps(stats))
    
    return stats
```

---

## Performance Benchmarks

### Target Metrics (for 10M rows)

| Query Type | Target Response Time | Optimization Priority |
|------------|---------------------|----------------------|
| Simple lookup (by IP) | < 10ms | High |
| Burst detection (1 hour window) | < 100ms | High |
| Attribution analysis (7 days) | < 500ms | Medium |
| Campaign ROI (30 days) | < 2s | Low |
| Full table scan | Avoid! | N/A |

### Testing Performance

```bash
# Use pgbench for load testing
pgbench -c 10 -j 2 -T 60 -f burst_detection_query.sql advigilance

# Monitor during load test
watch -n 1 'psql -c "SELECT * FROM pg_stat_activity WHERE datname = '\''advigilance'\'';"'
```

---

## Troubleshooting Common Issues

### Query Running Forever
1. Check for missing indexes: `EXPLAIN ANALYZE`
2. Look for table locks: `SELECT * FROM pg_locks`
3. Kill long-running query: `SELECT pg_terminate_backend(pid)`

### Database Growing Too Large
1. Check table bloat (see monitoring queries above)
2. Run VACUUM FULL during maintenance window
3. Archive old data to separate table/server
4. Consider partitioning with automatic drop of old partitions

### Slow Writes
1. Reduce number of indexes (each index slows writes)
2. Batch inserts (1,000 rows at a time)
3. Use COPY instead of INSERT
4. Disable triggers temporarily for bulk loads

---

## Additional Resources

- [PostgreSQL Performance Tuning](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [Use The Index, Luke](https://use-the-index-luke.com/)
- [Postgres Index Types](https://www.postgresql.org/docs/current/indexes-types.html)
- [Partitioning Best Practices](https://www.postgresql.org/docs/current/ddl-partitioning.html)
