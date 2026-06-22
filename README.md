# 🛡️ AdVigilance — Real-Data Ad-Fraud & Bot Detection Engine

A SQL-first **ad-fraud detection engine** built on **PostgreSQL**, powered by the real
**Criteo Display Advertising dataset (~45M clicks)**, with a tuned time-series index strategy,
advanced fraud-detection analytics, and **Power BI** reporting.

AdVigilance ingests real ad-click feature data, enriches it into a realistic ad-event schema,
and runs window-function-driven SQL to surface bot networks, click-burst attacks, impossible-travel
anomalies, and fraud-adjusted campaign ROI — the patterns that quietly drain digital ad budgets.

> Portfolio project demonstrating advanced PostgreSQL (window functions, temporal joins, CTEs),
> production-grade indexing (BRIN / HASH / partial / covering / GIN / GIST), real-data engineering,
> and BI integration.

---

## 🎯 Business Intent & Core Value

Digital ad fraud is a multi-billion-dollar problem — industry estimates put advertiser losses at
**15–30% of digital ad spend**, drained by bot networks, click farms, and attribution fraud. The
money is gone *before anyone notices*, because the fraudulent clicks look like ordinary traffic in
aggregate reports.

AdVigilance attacks that problem at the data layer. Instead of trusting raw click counts, it:

- **Flags fraud before payment** — detects bot/burst/anomaly patterns in the click stream so
  spend can be challenged rather than written off.
- **Separates clean ROI from reported ROI** — recomputes campaign performance with fraudulent
  clicks removed, exposing the gap between what a campaign *looks* like it returned and what it
  *actually* returned.
- **Turns raw events into decisions** — feeds optimized views into Power BI so analysts can
  monitor invalid-traffic rates and threats without writing SQL.

**The core value:** converting a 45M-row real ad dataset into governed, query-optimized fraud
intelligence that quantifies wasted spend and protects campaign budgets.

---

## 🏗️ Architecture

```
   Criteo Display Advertising dataset (~45M clicks, tab-separated)
                          │
                          ▼
        ┌────────────────────────────────────┐
        │  Enrichment Layer (Python)          │
        │  criteo_enricher.py                 │
        │  • parse label + I1–I13 + C1–C26    │
        │  • synthesize IP / geo / device /UA │
        │  • inject realistic fraud patterns  │
        └──────────────┬─────────────────────┘
                       ▼
        ┌────────────────────────────────────┐
        │  PostgreSQL 14+ (advigilance schema)│
        │  click_stream · conversion_stream   │
        │  bot_blacklist · campaign_budgets   │
        │  + BRIN/HASH/partial/GIN/GIST idx   │
        └──────────────┬─────────────────────┘
                       ▼
        ┌────────────────────────────────────┐
        │  Fraud Detection (advanced SQL)     │
        │  • instant-conversion bot detection │
        │  • sliding-window burst detection   │
        │  • geographic impossible-travel     │
        │  • clean vs. reported campaign ROI  │
        └──────────────┬─────────────────────┘
                       ▼
        ┌────────────────────────────────────┐
        │  Reporting                          │
        │  Power BI views + DAX  ·  HTML dash │
        └────────────────────────────────────┘
```

Full design in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md);
Power BI details in [`docs/POWERBI_INTEGRATION.md`](docs/POWERBI_INTEGRATION.md).

---

## 🛠️ Tech Stack

| Layer | Tool |
|---|---|
| Database | PostgreSQL 14+ (`uuid-ossp`, `pg_trgm`, `btree_gist`) |
| Data | Criteo Display Advertising dataset (real, ~45M rows) |
| Enrichment / ETL | Python (pandas, numpy) |
| Fraud analytics | Advanced SQL (window functions, temporal joins, CTEs) |
| Reporting | Power BI (views + DAX) · HTML dashboard |
| Synthetic fallback | `data_generator.py` (Faker-based, v1) |

---

## ✨ Key Features

- **Real-data pipeline** — transforms the raw Criteo dataset into a realistic ad-event schema
  with IPs, geo, devices, user agents, and injected fraud patterns.
- **Four fraud-detection techniques** — instant-conversion bot detection (temporal joins),
  burst detection (sliding `RANGE BETWEEN` windows), geographic impossible-travel (`LAG`), and
  fraud-adjusted ROI.
- **Production-grade indexing** — BRIN (time-series), HASH (IP equality), partial (fraud-only),
  covering (`INCLUDE` for BI), GIN (array search), and GIST `inet_ops` (CIDR matching).
- **Power BI integration** — purpose-built reporting views and DAX measures over a DirectQuery
  connection.

---

## 🧩 Engineering Complexities & Core Triumphs

**🔄 Real Criteo format wrangling.**
The Criteo dataset ships as headerless, tab-separated rows of `label + I1–I13` (integer features)
`+ C1–C26` (hashed categorical features) — nothing resembling ad events. `criteo_enricher.py`
parses that raw structure and synthesizes a realistic event schema around it (IP pools per country,
device/user-agent mapping, geo, timestamps), then injects controlled fraud patterns at a
configurable rate for validation.

**📈 100K synthetic → 45M real (the v2 migration).**
v1 ran on a Faker-generated 100K-row simulation. v2 swapped in the real Criteo dataset — **~450x more
data** — which is the difference between "I generated fake clicks" and "I processed a real 45M-row
advertising dataset" in an interview. See [`docs/V2_MIGRATION.md`](docs/V2_MIGRATION.md).

**⚙️ Index engineering matched to query shape.**
Rather than blanket B-trees, each index targets a real access pattern: **BRIN** on `timestamp`
(≈100× smaller than B-tree for naturally-ordered time-series), **HASH** on `ip_address` for
equality lookups, **partial** indexes scoped to `WHERE is_suspicious = true`, **covering** indexes
with `INCLUDE` to satisfy Power BI queries from the index alone, **GIN** for `fraud_reasons` array
search, and **GIST** with `inet_ops` for CIDR/IP-range matching against the blacklist.

**🪟 Window-function-driven fraud logic.**
The detection layer leans on temporal joins with attribution windows (click → conversion within an
interval), `RANGE BETWEEN` sliding windows for burst patterns, and `LAG()` partitioned by user to
catch impossible travel — then computes **clean vs. reported ROI** to show the true cost of fraud.

**🏆 The triumph:** a project that proves SQL depth on *real* data — the enrichment, the
index-per-pattern discipline, and the analytical queries are all things an interviewer can probe
line by line.

---

## 📁 Project Structure

```
advigilance/
├── README.md
├── requirements.txt
├── sql/
│   ├── 01_create_schema.sql          # Tables + extensions (advigilance schema)
│   ├── 02_create_indexes.sql         # BRIN/HASH/partial/covering/GIN/GIST indexes
│   ├── 03_fraud_detection_queries.sql# Core detection logic
│   └── 03_powerbi_views.sql          # Reporting views for Power BI
├── scripts/
│   ├── criteo_enricher.py            # Criteo raw → enriched ad-event schema
│   ├── data_generator.py             # Synthetic generator (v1 fallback)
│   └── powerbi_export.py             # Export/refresh for Power BI
├── dashboard/
│   └── fraud_dashboard.html          # Static HTML dashboard
└── docs/
    ├── ARCHITECTURE.md
    ├── DATA_SOURCE_GUIDE.md
    ├── REAL_DATA_DOWNLOAD.md
    ├── POWERBI_INTEGRATION.md
    ├── PERFORMANCE.md
    └── V2_MIGRATION.md
```

---

## 🚀 Setup & Installation

### Prerequisites

- PostgreSQL 14+
- Python 3.9+
- The Criteo Display Advertising dataset (download instructions in
  [`docs/REAL_DATA_DOWNLOAD.md`](docs/REAL_DATA_DOWNLOAD.md))

### 1. Install dependencies

```bash
pip install -r requirements.txt
```

### 2. Create the database & schema

```bash
createdb advigilance
psql -d advigilance -f sql/01_create_schema.sql
```

### 3. Enrich the real Criteo data

```bash
# Download train.txt per docs/REAL_DATA_DOWNLOAD.md, then:
python scripts/criteo_enricher.py train.txt --output enriched_clicks.csv
```

> No Criteo download? Generate a synthetic sample instead:
> `python scripts/data_generator.py --events 1000000`

### 4. Load the data, then build indexes

```bash
# Load enriched_clicks.csv into PostgreSQL (e.g. \copy), then:
psql -d advigilance -f sql/02_create_indexes.sql   # run AFTER loading for best performance
```

### 5. Run fraud detection

```bash
psql -d advigilance -f sql/03_fraud_detection_queries.sql
```

### 6. Reporting

```bash
psql -d advigilance -f sql/03_powerbi_views.sql     # create BI views
python scripts/powerbi_export.py                    # export/refresh for Power BI
# or open dashboard/fraud_dashboard.html for the static view
```

---

## 🎓 Skills Demonstrated

- **Advanced SQL** — window functions (`LAG`, `RANGE BETWEEN`), temporal joins, CTEs, fraud scoring
- **PostgreSQL performance** — index-per-pattern strategy (BRIN/HASH/partial/covering/GIN/GIST)
- **Data engineering** — real-dataset ingestion, enrichment, schema design
- **AdTech domain** — attribution windows, invalid-traffic detection, clean vs. reported ROI
- **BI integration** — Power BI views and DAX over PostgreSQL

---

## 📄 License

Released for portfolio and educational purposes. The Criteo dataset is owned by its original
publishers and subject to their terms.
