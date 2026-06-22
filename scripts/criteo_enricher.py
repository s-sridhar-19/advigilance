#!/usr/bin/env python3
"""
Criteo Dataset Enricher - CORRECTED VERSION
Transforms Criteo Display Advertising dataset into AdVigilance schema
Handles actual Criteo format: tab-separated, no headers, label + I1-I13 + C1-C26
"""

import pandas as pd
import numpy as np
import argparse
import sys
from datetime import datetime, timedelta
from pathlib import Path
import uuid
import random
import hashlib
from typing import List, Dict, Tuple
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class CriteoEnricher:
    """Enriches Criteo dataset with AdVigilance schema and fraud patterns"""
    
    def __init__(self, fraud_rate: float = 0.20):
        self.fraud_rate = fraud_rate
        self.start_date = datetime.now() - timedelta(days=30)
        
        # IP pools
        self.ip_pools = {
            'US': self._generate_ip_pool(5000, '192.168'),
            'GB': self._generate_ip_pool(2000, '193.0'),
            'FR': self._generate_ip_pool(1500, '194.1'),
            'DE': self._generate_ip_pool(1500, '195.2'),
            'CA': self._generate_ip_pool(1000, '196.3'),
        }
        
        self.bot_ips = self._generate_ip_pool(100, '203.0.113')
        
        # Device type mapping
        self.device_mapping = {
            'mobile': ['iPhone', 'Android', 'iPad', 'Samsung'],
            'desktop': ['Windows', 'Macintosh', 'Linux'],
            'tablet': ['iPad', 'Android Tablet', 'Surface']
        }
        
        # Country mapping
        self.country_codes = ['US', 'GB', 'FR', 'DE', 'CA', 'AU', 'ES', 'IT', 'NL', 'JP']
        
        # User agent templates
        self.user_agents = {
            'mobile': [
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0',
            ],
            'desktop': [
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0',
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
            ],
            'tablet': [
                'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
            ],
        }
        
        # Bot user agents
        self.bot_user_agents = [
            'curl/7.64.1',
            'Python-urllib/3.8',
            'Mozilla/5.0 (compatible; Googlebot/2.1)',
            'PhantomJS/2.1.1',
        ]
    
    def _generate_ip_pool(self, size: int, prefix: str) -> List[str]:
        """Generate pool of IP addresses with given prefix"""
        ips = []
        for _ in range(size):
            octets = prefix.split('.')
            while len(octets) < 4:
                octets.append(str(random.randint(1, 254)))
            ips.append('.'.join(octets))
        return ips
    
    def _hash_to_int(self, hash_str: str, max_val: int) -> int:
        """Convert Criteo hash to deterministic integer"""
        if pd.isna(hash_str) or hash_str == '' or not hash_str:
            return random.randint(0, max_val - 1)
        try:
            hash_val = int(hashlib.md5(str(hash_str).encode()).hexdigest(), 16)
            return hash_val % max_val
        except:
            return random.randint(0, max_val - 1)
    
    def _map_device_type(self, c2_hash: str) -> str:
        """Map Criteo C2 hash to device type"""
        val = self._hash_to_int(c2_hash, 100)
        if val < 60:
            return 'mobile'
        elif val < 90:
            return 'desktop'
        else:
            return 'tablet'
    
    def _map_country(self, c3_hash: str) -> str:
        """Map Criteo C3 hash to country code"""
        val = self._hash_to_int(c3_hash, len(self.country_codes))
        return self.country_codes[val]
    
    def _get_ip_address(self, country: str, is_fraud: bool) -> str:
        """Get IP address based on country and fraud status"""
        if is_fraud and random.random() < 0.7:
            return random.choice(self.bot_ips)
        
        if country in self.ip_pools:
            return random.choice(self.ip_pools[country])
        return random.choice(self.ip_pools['US'])
    
    def _get_user_agent(self, device_type: str, is_fraud: bool) -> str:
        """Generate user agent string"""
        if is_fraud and random.random() < 0.6:
            return random.choice(self.bot_user_agents)
        
        return random.choice(self.user_agents.get(device_type, self.user_agents['desktop']))
    
    def _generate_timestamp(self, row_index: int, total_rows: int, is_fraud: bool) -> datetime:
        """Generate timestamp with fraud burst patterns"""
        # Distribute over 30 days
        base_offset = (row_index / max(total_rows, 1)) * 30
        timestamp = self.start_date + timedelta(days=base_offset)
        
        # Add intraday variation
        timestamp += timedelta(
            hours=random.randint(0, 23),
            minutes=random.randint(0, 59),
            seconds=random.randint(0, 59)
        )
        
        # Fraud creates burst patterns
        if is_fraud and random.random() < 0.3:
            timestamp += timedelta(seconds=random.uniform(0, 10))
        
        return timestamp
    
    def _calculate_fraud_score(self, row: Dict, is_fraud: bool) -> Tuple[int, List[str]]:
        """Calculate fraud score and reasons"""
        if not is_fraud:
            return random.randint(0, 30), []
        
        score = 0
        reasons = []
        
        fraud_type = random.choice(['bot_network', 'burst', 'geo_anomaly', 'blacklist'])
        
        if fraud_type == 'bot_network':
            score += 40
            reasons.append('suspicious_user_agent')
            reasons.append('instant_conversion')
        elif fraud_type == 'burst':
            score += 35
            reasons.append('burst')
        elif fraud_type == 'geo_anomaly':
            score += 30
            reasons.append('geo_anomaly')
        elif fraud_type == 'blacklist':
            score += 45
            reasons.append('blacklist')
        
        if row.get('time_on_page', 10) < 3:
            score += 15
            reasons.append('short_time_on_page')
        
        if row.get('scroll_depth', 50) < 10:
            score += 10
            reasons.append('low_engagement')
        
        return min(score, 100), reasons
    
    def enrich_batch(self, df: pd.DataFrame, start_idx: int) -> pd.DataFrame:
        """Enrich a batch of Criteo data"""
        logger.info(f"Enriching batch of {len(df)} records starting at index {start_idx}")
        
        # Determine which rows are fraudulent
        num_fraud = int(len(df) * self.fraud_rate)
        fraud_indices = set(random.sample(range(len(df)), min(num_fraud, len(df))))
        
        # Criteo data has NO HEADERS, columns are:
        # Col 0: Label (0/1)
        # Col 1-13: I1-I13 (integer features)
        # Col 14-39: C1-C26 (categorical features)
        enriched = []
        
        for idx, row in df.iterrows():
            global_idx = start_idx + idx
            is_fraud = idx in fraud_indices
            
            # Extract Criteo fields by position
            label = int(row.iloc[0]) if pd.notna(row.iloc[0]) else 0
            
            # Integer features (columns 1-13)
            i_features = {}
            for i in range(1, 14):
                try:
                    i_features[f'I{i}'] = int(row.iloc[i]) if pd.notna(row.iloc[i]) and row.iloc[i] != '' else 0
                except:
                    i_features[f'I{i}'] = 0
            
            # Categorical features (columns 14-39)
            c_features = {}
            for i in range(1, 27):
                try:
                    c_features[f'C{i}'] = str(row.iloc[13+i]) if pd.notna(row.iloc[13+i]) and row.iloc[13+i] != '' else ''
                except:
                    c_features[f'C{i}'] = ''
            
            # Map to our schema
            device_type = self._map_device_type(c_features.get('C2', ''))
            country = self._map_country(c_features.get('C3', ''))
            
            enriched_row = {
                # Identifiers
                'click_id': str(uuid.uuid4()),
                'user_id': f"user_{self._hash_to_int(c_features.get('C1', ''), 100000)}",
                'session_id': f"session_{uuid.uuid4().hex[:16]}",
                
                # Campaign (derived from C1)
                'campaign_id': self._hash_to_int(c_features.get('C1', ''), 3) + 1,
                'ad_id': f"ad_{self._hash_to_int(c_features.get('C4', ''), 100)}",
                'placement_id': f"placement_{self._hash_to_int(c_features.get('C5', ''), 50)}",
                
                # Network
                'ip_address': self._get_ip_address(country, is_fraud),
                'user_agent': self._get_user_agent(device_type, is_fraud),
                
                # Device
                'device_type': device_type,
                'os_name': 'iOS' if 'iPhone' in device_type else 'Android' if device_type == 'mobile' else 'Windows',
                'browser_name': 'Safari' if 'iPhone' in device_type else 'Chrome',
                'browser_version': str(random.randint(110, 125)),
                
                # Geography
                'geo_country': country,
                'geo_region': f"{country}-Region-{random.randint(1, 5)}",
                'geo_city': f"{country}-City-{random.randint(1, 10)}",
                'geo_latitude': round(random.uniform(-90, 90), 6),
                'geo_longitude': round(random.uniform(-180, 180), 6),
                
                # Context
                'referrer_url': f"https://referrer-{random.randint(1, 100)}.com" if random.random() < 0.8 else '',
                'landing_page_url': f"https://advertiser.com/page_{self._hash_to_int(c_features.get('C6', ''), 20)}",
                
                # Behavior (use Criteo integer features)
                'time_on_page': max(0, int(i_features.get('I2', 0) * 10)) if not is_fraud else random.randint(0, 5),
                'scroll_depth': max(0, min(100, int(i_features.get('I3', 0) * 100))) if not is_fraud else random.randint(0, 20),
                
                # Temporal
                'timestamp': self._generate_timestamp(global_idx, 1000000, is_fraud).isoformat(),
            }
            
            # Fraud scoring
            enriched_row['is_suspicious'] = is_fraud
            fraud_score, fraud_reasons = self._calculate_fraud_score(enriched_row, is_fraud)
            enriched_row['fraud_score'] = fraud_score
            enriched_row['fraud_reasons'] = '{' + ','.join(fraud_reasons) + '}' if fraud_reasons else '{}'
            
            enriched.append(enriched_row)
        
        return pd.DataFrame(enriched)
    
    def process_file(self, input_file: str, output_file: str, chunk_size: int = 100000, max_rows: int = None):
        """Process Criteo file in chunks"""
        logger.info(f"Processing {input_file} → {output_file}")
        logger.info(f"Chunk size: {chunk_size:,} | Fraud rate: {self.fraud_rate:.1%}")
        logger.info("Criteo format detected: tab-separated, no headers, label + I1-I13 + C1-C26")
        
        total_rows = 0
        chunk_num = 0
        first_chunk = True
        
        # Criteo data is tab-separated with NO HEADERS
        try:
            for chunk in pd.read_csv(input_file, sep='\t', header=None, chunksize=chunk_size, nrows=max_rows):
                chunk_num += 1
                logger.info(f"Processing chunk {chunk_num} ({len(chunk):,} records)")
                
                enriched_chunk = self.enrich_batch(chunk, total_rows)
                
                enriched_chunk.to_csv(
                    output_file,
                    mode='w' if first_chunk else 'a',
                    header=first_chunk,
                    index=False
                )
                
                first_chunk = False
                total_rows += len(chunk)
                
                logger.info(f"  Progress: {total_rows:,} rows enriched")
                
                if max_rows and total_rows >= max_rows:
                    break
        except Exception as e:
            logger.error(f"Error processing file: {e}")
            import traceback
            traceback.print_exc()
            raise
        
        logger.info(f"✓ Complete! Enriched {total_rows:,} total records")
        logger.info(f"✓ Output: {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Enrich Criteo dataset with AdVigilance schema and fraud patterns'
    )
    parser.add_argument(
        'input_file',
        help='Path to Criteo dataset (train.txt or test.txt)'
    )
    parser.add_argument(
        '--output',
        default='data/enriched_clicks.csv',
        help='Output CSV file path'
    )
    parser.add_argument(
        '--fraud-rate',
        type=float,
        default=0.23,
        help='Fraud rate (0.0 to 1.0)'
    )
    parser.add_argument(
        '--chunk-size',
        type=int,
        default=100000,
        help='Number of rows to process per chunk'
    )
    parser.add_argument(
        '--max-rows',
        type=int,
        help='Maximum rows to process (for testing)'
    )
    
    args = parser.parse_args()
    
    # Validate inputs
    if not Path(args.input_file).exists():
        logger.error(f"Input file not found: {args.input_file}")
        sys.exit(1)
    
    if args.fraud_rate < 0 or args.fraud_rate > 1:
        logger.error("Fraud rate must be between 0 and 1")
        sys.exit(1)
    
    # Create output directory
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    
    # Process file
    enricher = CriteoEnricher(fraud_rate=args.fraud_rate)
    enricher.process_file(args.input_file, args.output, args.chunk_size, args.max_rows)
    
    # Print statistics
    logger.info("\n" + "="*60)
    logger.info("ENRICHMENT SUMMARY")
    logger.info("="*60)
    logger.info(f"Input:  {args.input_file}")
    logger.info(f"Output: {args.output}")
    logger.info(f"Fraud Rate: {args.fraud_rate:.1%}")
    
    # Read output sample
    try:
        df_out = pd.read_csv(args.output, nrows=1000)
        fraud_count = df_out['is_suspicious'].sum()
        logger.info(f"Sample fraud rate: {fraud_count / len(df_out):.1%}")
        logger.info(f"Columns: {len(df_out.columns)}")
    except Exception as e:
        logger.warning(f"Could not read output sample: {e}")


if __name__ == '__main__':
    main()
