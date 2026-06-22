# AdVigilance v2.0: Real Data Source Implementation Guide

## Data Source Analysis & Recommendation

### Option 1: Criteo Ad-Logs Dataset ⭐ **RECOMMENDED**

#### Overview
- **Source**: Kaggle/Criteo Research
- **Size**: 45M+ click records (4.3GB compressed)
- **Format**: Tab-separated values (TSV)
- **License**: Open research dataset
- **Cost**: FREE

#### Pros
✅ **Accessibility**: Direct download, no API keys needed
✅ **Volume**: Real production-scale data (45M records)
✅ **Quality**: Actual Criteo display ad data
✅ **Structure**: Already in tabular format (easy SQL import)
✅ **Complete**: Has both clicks and conversions
✅ **No Rate Limits**: Download once, use forever
✅ **Privacy Compliant**: Already anonymized

#### Cons
❌ Static dataset (not real-time stream)
❌ Data from 2014 (still valid for learning patterns)
❌ Limited fields (13 columns vs our enriched schema)

#### Available Fields
```
1. Label (0=no conversion, 1=conversion)
2. I1-I13 (Integer features - normalized click/user data)
3. C1-C26 (Categorical features - anonymized IDs)
```

#### Data Sample
```
0   1   1   5   0   1382    4   15  2   181 1   2   ...
1   2   2   2   1   948     4   15  8   61  4   1   ...
```

---

### Option 2: Google RTB API

#### Overview
- **Source**: Google Ad Manager API
- **Type**: Real-time bidding data
- **Format**: JSON via REST API
- **Cost**: Requires Google Ads account + approval

#### Pros
✅ Real-time data stream
✅ Rich metadata (device, geo, timestamps)
✅ Industry-standard format
✅ Current data (2024-2026)

#### Cons
❌ **Complex Setup**: OAuth2, API keys, account approval
❌ **Costs**: Requires active ad campaigns ($$$)
❌ **Rate Limits**: 100K requests/day (enterprise: 1M/day)
❌ **Access Restrictions**: Need advertiser/publisher credentials
❌ **Learning Curve**: Complex API documentation
❌ **Data Volume**: Limited by budget and rate limits

---

## 🏆 Recommendation: Criteo Dataset

**For a portfolio/learning project, use Criteo because:**

1. **Immediate Access**: Download and start in 10 minutes
2. **Cost**: $0 vs potentially $1000s for real campaigns
3. **Scale**: 45M records = production-realistic
4. **Simplicity**: TSV import vs API integration complexity
5. **Offline Development**: No internet/API dependencies
6. **Reproducibility**: Same dataset = consistent demos

**For production deployment, use Google RTB API because:**
- Real-time fraud detection requires live data
- Current data reflects modern fraud patterns
- Integration with existing ad infrastructure

---

## Implementation Plan: Criteo Dataset

### Phase 1: Data Acquisition (15 minutes)

#### Step 1: Download Dataset
```bash
# Option A: Kaggle CLI (recommended)
pip install kaggle
kaggle datasets download -d kritanjalijain/displayadvertisingchallenge

# Option B: Manual download
# 1. Visit: https://www.kaggle.com/datasets/kritanjalijain/displayadvertisingchallenge
# 2. Click "Download" (requires free Kaggle account)
# 3. Extract: unzip displayadvertisingchallenge.zip
```

#### Step 2: Verify Download
```bash
# Check file size
ls -lh train.txt  # Should be ~4.3GB uncompressed

# Preview first few lines
head -5 train.txt

# Count records
wc -l train.txt   # ~45,840,617 lines
```

---

### Phase 2: Data Transformation (Map to Our Schema)

The Criteo dataset needs enrichment to match our fraud detection schema:

#### Mapping Strategy

| Criteo Field | AdVigilance Schema Field | Transformation |
|--------------|-------------------------|----------------|
| Label | conversion_occurred | Direct map (0/1) |
| I1 | click_id | Generate UUID |
| I2-I13 | User behavioral features | Use for fraud scoring |
| C1 | campaign_id | Hash to integer |
| C2 | device_type | Map hash to mobile/desktop/tablet |
| C3 | geo_country | Map hash to country code |
| C4-C26 | Additional context | Store in JSONB evidence field |
| (generated) | ip_address | Simulate based on C3 (geo) |
| (generated) | timestamp | Distribute over 30-day window |
| (generated) | user_agent | Generate based on C2 (device) |

#### Enrichment Script (Python)

We'll create a script that:
1. Reads Criteo TSV in chunks (memory-efficient)
2. Enriches with realistic IP, timestamp, user_agent
3. Applies fraud patterns (bots, bursts, geo anomalies)
4. Outputs to PostgreSQL-ready CSV

---

### Phase 3: Loading into PostgreSQL

#### Import Process
```bash
# Direct import (fast, for small datasets)
COPY click_stream FROM '/path/to/enriched_clicks.csv' CSV HEADER;

# Batch import (for 45M records)
split -l 1000000 enriched_clicks.csv chunk_
for file in chunk_*; do
    psql -d advigilance -c "COPY click_stream FROM '$file' CSV HEADER";
done
```

---

## Alternative: Google RTB API Implementation

If you choose Google RTB API (for production or advanced portfolio):

### Setup Requirements

1. **Google Cloud Account**
   - Enable Ad Manager API
   - Create OAuth2 credentials
   - Set up service account

2. **API Access**
   ```bash
   pip install google-ads google-auth google-auth-oauthlib
   ```

3. **Authentication**
   ```python
   from google.ads.googleads.client import GoogleAdsClient
   
   client = GoogleAdsClient.load_from_storage("google-ads.yaml")
   ```

4. **Fetch Real-Time Bids**
   ```python
   query = """
       SELECT 
           click_view.ad_group_ad,
           click_view.gclid,
           metrics.clicks,
           segments.device,
           segments.geo_target_country
       FROM click_view
       WHERE segments.date DURING LAST_7_DAYS
   """
   
   stream = client.service.search_stream(
       customer_id="1234567890",
       query=query
   )
   ```

### Cost Estimate
- Minimum ad spend: $10/day
- API calls: Free (within rate limits)
- **Total for 7 days of data**: ~$100-500

---

## Data Quality Comparison

| Metric | Criteo Dataset | Google RTB API |
|--------|---------------|----------------|
| **Volume** | 45M records | Limited by budget |
| **Freshness** | 2014 (static) | Real-time |
| **Cost** | $0 | $100-1000+/month |
| **Setup Time** | 15 minutes | 2-4 hours |
| **Fields** | 39 columns | 100+ fields |
| **Fraud Labels** | No (we simulate) | No (we detect) |
| **Reproducibility** | Perfect | Variable |

---

## Recommended Workflow

### For Portfolio/Learning (90% of use cases)
```
1. Download Criteo dataset (15 min)
2. Run enrichment script (30 min)
3. Import to PostgreSQL (1 hour for 45M records)
4. Run fraud detection queries (immediate)
5. Export to Power BI (10 min)
```

### For Production/Advanced Portfolio
```
1. Set up Google Cloud (1 hour)
2. Configure RTB API (1 hour)
3. Implement streaming pipeline (2-4 hours)
4. Connect to PostgreSQL (30 min)
5. Real-time Power BI dashboard (1 hour)
```

---

## Next Steps

Based on your choice, I'll provide:

**If Criteo Dataset:**
- ✅ Download and extraction script
- ✅ Enrichment script (Criteo → AdVigilance schema)
- ✅ Fraud pattern injection
- ✅ Batch import to PostgreSQL
- ✅ Power BI connection guide

**If Google RTB API:**
- ✅ API setup walkthrough
- ✅ Streaming ingestion script
- ✅ Real-time fraud detection
- ✅ Live Power BI dashboard

**Which would you prefer?** 

For a portfolio project to show to recruiters, I strongly recommend **Criteo** because:
1. Hiring managers can verify it's real data (cite Kaggle source)
2. No ongoing costs to maintain
3. Easier to demo (no API credentials needed)
4. Still shows production-scale data handling (45M records)

---

## Hybrid Approach (Best of Both Worlds)

**Use Criteo for development + Add Google RTB as "production enhancement"**

Your README can say:
> "AdVigilance was developed using the Criteo Display Advertising dataset (45M records) for reproducibility and offline development. The architecture is designed to integrate with live data sources like Google RTB API for production deployment."

This shows:
- You can work with real data (Criteo)
- You understand production requirements (RTB API)
- You make pragmatic engineering decisions (Criteo for dev, RTB for prod)

---

Let me know which path you'd like to take, and I'll provide the complete implementation!
