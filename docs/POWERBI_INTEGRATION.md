# AdVigilance Power BI Integration Guide

## Overview

This guide covers three methods to connect AdVigilance data to Power BI:
1. **Direct PostgreSQL Connection** (Recommended for real-time dashboards)
2. **CSV Export** (Best for static reports and sharing)
3. **REST API** (Advanced: for live streaming)

---

## Method 1: Direct PostgreSQL Connection ⭐ RECOMMENDED

### Advantages
✅ Real-time data (queries run live against database)
✅ Automatic refresh (no manual exports)
✅ Supports large datasets (billions of rows)
✅ Query folding (Power BI pushes filtering to SQL)
✅ Incremental refresh (only load new data)

### Setup Steps

#### Step 1: Install PostgreSQL ODBC Driver

**Windows:**
```powershell
# Download from: https://www.postgresql.org/ftp/odbc/versions/msi/
# Install: psqlodbc_x64.msi
```

**Verify Installation:**
1. Open "ODBC Data Sources (64-bit)"
2. Go to "Drivers" tab
3. Look for "PostgreSQL Unicode(x64)"

#### Step 2: Configure PostgreSQL for Remote Access

Edit `postgresql.conf`:
```conf
# Allow connections from Power BI machine
listen_addresses = '*'  # Or specific IP: '192.168.1.100'

# Increase connection limit if needed
max_connections = 200
```

Edit `pg_hba.conf`:
```conf
# Allow password authentication from Power BI IP
host    advigilance    all    192.168.1.0/24    md5
```

Restart PostgreSQL:
```bash
sudo systemctl restart postgresql
```

#### Step 3: Connect Power BI to PostgreSQL

**In Power BI Desktop:**

1. **Get Data** → **Database** → **PostgreSQL database**

2. **Connection Settings:**
   ```
   Server: localhost (or your-server-ip:5432)
   Database: advigilance
   
   Data Connectivity mode:
   ○ Import (loads data into Power BI - faster queries)
   ● DirectQuery (queries database live - always fresh)
   ```

3. **Credentials:**
   ```
   Database authentication:
   Username: your_username
   Password: your_password
   ```

4. **Navigator:**
   - Expand "advigilance" schema
   - Select tables to import:
     ☑ click_stream
     ☑ conversion_stream
     ☑ campaign_budgets
     ☑ bot_blacklist
     ☑ fraud_events
     ☑ daily_campaign_summary

5. **Load vs Transform:**
   - Click **Transform Data** to open Power Query Editor
   - Apply any initial filtering/transformations
   - Click **Close & Apply**

#### Step 4: Optimize for Power BI

**Create Power BI-Optimized Views:**

```sql
-- View 1: Click Fraud Summary (for main dashboard)
CREATE OR REPLACE VIEW powerbi_click_fraud_summary AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    campaign_id,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    COUNT(DISTINCT ip_address) as unique_ips,
    AVG(fraud_score) as avg_fraud_score,
    SUM(CASE WHEN fraud_score >= 90 THEN 1 ELSE 0 END) as critical_fraud,
    SUM(CASE WHEN fraud_score BETWEEN 50 AND 89 THEN 1 ELSE 0 END) as suspicious_fraud
FROM click_stream
WHERE timestamp >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('hour', timestamp), campaign_id;

-- View 2: Campaign Performance (for ROI analysis)
CREATE OR REPLACE VIEW powerbi_campaign_performance AS
WITH campaign_clicks AS (
    SELECT 
        campaign_id,
        COUNT(*) as total_clicks,
        SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks
    FROM click_stream
    WHERE timestamp >= NOW() - INTERVAL '7 days'
    GROUP BY campaign_id
),
campaign_conversions AS (
    SELECT 
        c.campaign_id,
        COUNT(DISTINCT cv.conversion_id) as total_conversions,
        SUM(cv.revenue) as total_revenue
    FROM click_stream c
    LEFT JOIN conversion_stream cv ON c.user_id = cv.user_id
    WHERE c.timestamp >= NOW() - INTERVAL '7 days'
    GROUP BY c.campaign_id
)
SELECT 
    cb.campaign_id,
    cb.campaign_name,
    cb.advertiser_name,
    cc.total_clicks,
    cc.fraud_clicks,
    cc.total_clicks - cc.fraud_clicks as clean_clicks,
    ccv.total_conversions,
    ccv.total_revenue,
    cb.cost_per_click,
    cc.total_clicks * cb.cost_per_click as total_cost,
    cc.fraud_clicks * cb.cost_per_click as fraud_cost,
    CASE 
        WHEN (cc.total_clicks - cc.fraud_clicks) > 0 
        THEN ROUND((ccv.total_revenue / ((cc.total_clicks - cc.fraud_clicks) * cb.cost_per_click) - 1) * 100, 2)
        ELSE 0 
    END as clean_roi_percentage
FROM campaign_budgets cb
LEFT JOIN campaign_clicks cc ON cb.campaign_id = cc.campaign_id
LEFT JOIN campaign_conversions ccv ON cb.campaign_id = ccv.campaign_id;

-- View 3: Top Fraud Sources (for threat intelligence)
CREATE OR REPLACE VIEW powerbi_top_fraud_sources AS
SELECT 
    ip_address,
    COUNT(*) as total_clicks,
    MAX(fraud_score) as max_fraud_score,
    ARRAY_AGG(DISTINCT fraud_reasons) FILTER (WHERE fraud_reasons IS NOT NULL) as fraud_patterns,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen,
    COUNT(DISTINCT campaign_id) as campaigns_affected
FROM click_stream
WHERE is_suspicious = true
    AND timestamp >= NOW() - INTERVAL '7 days'
GROUP BY ip_address
ORDER BY total_clicks DESC
LIMIT 100;

-- View 4: Hourly Fraud Trends (for time-series charts)
CREATE OR REPLACE VIEW powerbi_hourly_fraud_trends AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    COUNT(*) as total_clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks,
    ROUND(AVG(fraud_score), 2) as avg_fraud_score,
    COUNT(DISTINCT ip_address) as unique_ips,
    -- Count by fraud type
    SUM(CASE WHEN 'burst' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as burst_fraud,
    SUM(CASE WHEN 'instant_conversion' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as conversion_fraud,
    SUM(CASE WHEN 'geo_anomaly' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as geo_fraud,
    SUM(CASE WHEN 'blacklist' = ANY(fraud_reasons) THEN 1 ELSE 0 END) as blacklist_fraud
FROM click_stream
WHERE timestamp >= NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('hour', timestamp)
ORDER BY hour DESC;
```

**Grant Power BI User Access:**
```sql
-- Create read-only user for Power BI
CREATE USER powerbi_user WITH PASSWORD 'secure_password_here';

-- Grant access to schema and views
GRANT USAGE ON SCHEMA advigilance TO powerbi_user;
GRANT SELECT ON ALL TABLES IN SCHEMA advigilance TO powerbi_user;
GRANT SELECT ON ALL VIEWS IN SCHEMA advigilance TO powerbi_user;
```

---

## Method 2: CSV Export

### When to Use
- Sharing reports with stakeholders who don't have database access
- Creating static snapshots for presentations
- Archiving historical data

### Export Scripts

**Export Fraud Summary:**
```bash
psql -d advigilance -c "
COPY (
    SELECT * FROM powerbi_click_fraud_summary
) TO STDOUT CSV HEADER
" > powerbi_exports/fraud_summary.csv
```

**Export Campaign Performance:**
```bash
psql -d advigilance -c "
COPY (
    SELECT * FROM powerbi_campaign_performance
) TO STDOUT CSV HEADER
" > powerbi_exports/campaign_performance.csv
```

**Python Script for Automated Exports:**
```python
#!/usr/bin/env python3
"""Export AdVigilance data for Power BI"""

import psycopg2
import pandas as pd
from pathlib import Path
from datetime import datetime

def export_to_powerbi():
    """Export all Power BI views to CSV"""
    
    # Connect to database
    conn = psycopg2.connect(
        dbname="advigilance",
        user="your_user",
        password="your_password",
        host="localhost",
        port="5432"
    )
    
    # Create export directory
    export_dir = Path("powerbi_exports")
    export_dir.mkdir(exist_ok=True)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # Tables to export
    exports = {
        'fraud_summary': 'SELECT * FROM powerbi_click_fraud_summary',
        'campaign_performance': 'SELECT * FROM powerbi_campaign_performance',
        'top_fraud_sources': 'SELECT * FROM powerbi_top_fraud_sources',
        'hourly_trends': 'SELECT * FROM powerbi_hourly_fraud_trends',
    }
    
    for name, query in exports.items():
        print(f"Exporting {name}...")
        df = pd.read_sql(query, conn)
        
        # Clean column names for Power BI
        df.columns = df.columns.str.replace('_', ' ').str.title()
        
        # Export
        output_file = export_dir / f"{name}_{timestamp}.csv"
        df.to_csv(output_file, index=False)
        print(f"  ✓ Saved: {output_file} ({len(df):,} rows)")
    
    conn.close()
    print("\n✓ All exports complete!")

if __name__ == '__main__':
    export_to_powerbi()
```

**Connect CSV to Power BI:**
1. **Get Data** → **Text/CSV**
2. Select your CSV file
3. Power BI auto-detects data types
4. Click **Load**

---

## Recommended Power BI Visualizations

### 1. Executive KPI Dashboard

**Page 1: Overview**

**KPI Cards (4 across top):**
```dax
// Total Clicks
Total Clicks = SUM('Click Stream'[total_clicks])

// Fraud Rate
Fraud Rate % = 
    DIVIDE(
        SUM('Click Stream'[fraud_clicks]),
        SUM('Click Stream'[total_clicks])
    ) * 100

// Estimated Savings
Estimated Savings = SUM('Campaign Performance'[fraud_cost])

// Detection Latency
Avg Detection Time = 
    AVERAGE('Fraud Events'[detection_latency_ms])
```

**Visual: KPI Card**
- Format: Large number with trend indicator
- Conditional formatting: Red if fraud rate > 30%

---

### 2. Time Series Fraud Trends

**Line Chart: Fraud Over Time**

**X-Axis:** `Hour` (from `powerbi_hourly_fraud_trends`)
**Y-Axis (Multiple Lines):**
- Total Clicks (blue line)
- Fraud Clicks (red line)
- Avg Fraud Score (orange line, secondary axis)

**DAX Measure:**
```dax
Fraud Trend = 
    CALCULATE(
        SUM('Hourly Trends'[fraud_clicks]),
        DATESINPERIOD(
            'Hourly Trends'[hour],
            MAX('Hourly Trends'[hour]),
            -7,
            DAY
        )
    )
```

**Interactivity:**
- Drill down: Year → Month → Day → Hour
- Tooltip: Show fraud breakdown by type

---

### 3. Campaign ROI Comparison

**Clustered Bar Chart:**

**Y-Axis:** Campaign Name
**X-Axis (2 bars per campaign):**
- Reported ROI (light blue)
- Clean ROI (dark blue, after fraud removal)

**DAX Measures:**
```dax
Reported ROI % = 
    DIVIDE(
        [Total Revenue] - [Total Cost],
        [Total Cost]
    ) * 100

Clean ROI % = 
    DIVIDE(
        [Total Revenue] - [Clean Cost],
        [Clean Cost]
    ) * 100

// Clean Cost = Total Cost - Fraud Cost
Clean Cost = [Total Cost] - [Fraud Cost]
```

**Conditional Formatting:**
- Green if Clean ROI > 200%
- Yellow if Clean ROI 100-200%
- Red if Clean ROI < 100%

---

### 4. Geo Map: Fraud Hotspots

**Map Visual:**

**Location:** `geo_country` or `geo_city`
**Size:** `total_clicks`
**Color:** `fraud_percentage`

**Color Scale:**
- 0-10%: Green (safe)
- 10-20%: Yellow (monitor)
- 20-30%: Orange (concerning)
- 30%+: Red (critical)

**Tooltip:**
```
Country: [geo_country]
Total Clicks: [total_clicks]
Fraud Clicks: [fraud_clicks]
Fraud Rate: [fraud_percentage]%
Top Fraud IP: [ip_address]
```

---

### 5. Fraud Pattern Breakdown

**Donut Chart:**

**Values:** Count of fraud events
**Legend:** Fraud type (burst, bot_network, geo_anomaly, blacklist)

**DAX Measure:**
```dax
Fraud by Type = 
    SWITCH(
        TRUE(),
        'Hourly Trends'[burst_fraud] > 0, "Burst Attacks",
        'Hourly Trends'[conversion_fraud] > 0, "Bot Networks",
        'Hourly Trends'[geo_fraud] > 0, "Geo Anomalies",
        'Hourly Trends'[blacklist_fraud] > 0, "Blacklisted",
        "Unknown"
    )
```

**Color Coding:**
- Burst: Orange
- Bot Networks: Red
- Geo Anomalies: Purple
- Blacklisted: Dark Red

---

### 6. Top 10 Fraud IPs Table

**Table Visual:**

**Columns:**
1. IP Address
2. Total Clicks
3. Fraud Score (with conditional formatting)
4. Fraud Patterns (comma-separated)
5. First Seen
6. Last Seen
7. Campaigns Affected

**Conditional Formatting on Fraud Score:**
- 90-100: Dark red background, white text
- 75-89: Orange background
- 50-74: Yellow background

**Drill-through:**
- Click IP → See detailed click history

---

### 7. Real-Time Alerts Panel

**Card Visual (Updates every 5 minutes):**

```dax
Critical Alerts = 
    CALCULATE(
        COUNTROWS('Fraud Events'),
        'Fraud Events'[fraud_score] >= 90,
        'Fraud Events'[detected_at] >= NOW() - TIME(0, 15, 0)  // Last 15 min
    )
```

**Visual:** Large number with alert icon
**Conditional Formatting:** Blink/pulse if > 0

---

## Power BI Report Layout

### Suggested Page Structure

**Page 1: Executive Summary**
- KPI cards (top)
- Fraud trend line chart (middle left)
- Campaign ROI comparison (middle right)
- Geo map (bottom)

**Page 2: Fraud Analysis**
- Fraud pattern donut chart (top left)
- Hourly trends (top right)
- Top fraud sources table (bottom)

**Page 3: Campaign Deep Dive**
- Campaign selector slicer (top)
- Campaign metrics (KPIs)
- Click funnel visualization
- Conversion timeline

**Page 4: Threat Intelligence**
- Recent alerts (scrolling marquee)
- Blacklist status table
- IP reputation scores
- Detection method performance

---

## DAX Measures Library

Save these in a separate "Measures" table:

```dax
// === Basic Metrics ===
Total Clicks = SUM('Click Stream'[total_clicks])

Total Fraud = SUM('Click Stream'[fraud_clicks])

Fraud Rate % = DIVIDE([Total Fraud], [Total Clicks], 0) * 100

// === Financial ===
Total Revenue = SUM('Conversion Stream'[revenue])

Total Cost = SUM('Campaign Performance'[total_cost])

Fraud Cost = SUM('Campaign Performance'[fraud_cost])

Estimated Savings = [Fraud Cost]

ROI % = DIVIDE([Total Revenue] - [Total Cost], [Total Cost], 0) * 100

Clean ROI % = 
    DIVIDE(
        [Total Revenue] - ([Total Cost] - [Fraud Cost]),
        [Total Cost] - [Fraud Cost],
        0
    ) * 100

// === Performance ===
Conversion Rate % = 
    DIVIDE(
        COUNTROWS('Conversion Stream'),
        [Total Clicks],
        0
    ) * 100

Clean Conversion Rate % = 
    DIVIDE(
        COUNTROWS('Conversion Stream'),
        [Total Clicks] - [Total Fraud],
        0
    ) * 100

// === Time Intelligence ===
Fraud MTD = 
    CALCULATE(
        [Total Fraud],
        DATESMTD('Calendar'[Date])
    )

Fraud vs Last Week = 
    [Total Fraud] - 
    CALCULATE(
        [Total Fraud],
        DATEADD('Calendar'[Date], -7, DAY)
    )
```

---

## Performance Optimization

### 1. Use DirectQuery for Large Datasets

**Benefits:**
- No import size limits
- Always shows latest data
- Reduces Power BI file size

**Limitations:**
- Slower than Import mode
- Limited DAX functions
- Requires fast database

### 2. Implement Incremental Refresh

**For Import Mode:**

1. Add `timestamp` parameter
2. Configure refresh policy:
   ```
   Archive data older than: 365 days
   Incrementally refresh: Last 7 days
   ```

3. Power BI only refreshes last 7 days daily, full refresh yearly

### 3. Aggregate Tables

Create summary tables in PostgreSQL:
```sql
CREATE TABLE powerbi_daily_aggregates AS
SELECT 
    DATE_TRUNC('day', timestamp) as date,
    campaign_id,
    COUNT(*) as clicks,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as fraud_clicks
FROM click_stream
GROUP BY DATE_TRUNC('day', timestamp), campaign_id;

CREATE INDEX ON powerbi_daily_aggregates (date, campaign_id);
```

Power BI uses daily aggregates instead of millions of raw clicks.

---

## Scheduled Refresh Setup

### Power BI Service (Cloud)

1. **Publish Report:**
   - File → Publish to Power BI
   - Select workspace

2. **Configure Gateway:**
   - Install On-Premises Data Gateway on server with database access
   - Configure database credentials

3. **Schedule Refresh:**
   - Go to Dataset Settings
   - Scheduled Refresh → On
   - Frequency: Daily at 6:00 AM, 12:00 PM, 6:00 PM
   - Time zone: UTC

4. **Alerts:**
   - Set up email alerts for refresh failures

---

## Troubleshooting

### Issue: "Can't connect to PostgreSQL"
**Solution:**
1. Check firewall allows port 5432
2. Verify `pg_hba.conf` allows remote connections
3. Test connection: `psql -h YOUR_IP -U powerbi_user -d advigilance`

### Issue: "Query timeout"
**Solution:**
1. Switch to Import mode
2. Use pre-aggregated views
3. Add indexes to queried columns
4. Increase PostgreSQL `statement_timeout`

### Issue: "Data not refreshing"
**Solution:**
1. Check scheduled refresh settings
2. Verify gateway is online
3. Review refresh history for errors
4. Manually trigger refresh to test

---

## Next Steps

1. **Create Views:** Run the SQL view creation scripts
2. **Connect Power BI:** Use Method 1 (Direct PostgreSQL)
3. **Build Dashboards:** Implement the 7 visualizations
4. **Test:** Verify data updates in real-time
5. **Deploy:** Publish to Power BI Service
6. **Share:** Distribute to stakeholders

**Estimated Setup Time:** 2-3 hours

---

## Example Power BI File Structure

```
AdVigilance.pbix
├── Pages
│   ├── 1. Executive Summary
│   ├── 2. Fraud Analysis
│   ├── 3. Campaign Performance
│   └── 4. Threat Intelligence
├── Data Sources
│   ├── PostgreSQL: advigilance (DirectQuery)
│   └── Views:
│       ├── powerbi_click_fraud_summary
│       ├── powerbi_campaign_performance
│       ├── powerbi_top_fraud_sources
│       └── powerbi_hourly_fraud_trends
├── Measures (calculated fields)
│   ├── Total Clicks
│   ├── Fraud Rate %
│   ├── Clean ROI %
│   └── ... (30+ measures)
└── Relationships
    ├── Click Stream → Campaign Budgets (campaign_id)
    ├── Click Stream → Conversion Stream (user_id)
    └── Click Stream → Fraud Events (click_id)
```

Your Power BI dashboard is now ready to impress stakeholders! 📊
