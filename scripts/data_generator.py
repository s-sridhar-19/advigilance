#!/usr/bin/env python3
"""
AdVigilance Data Generator
Simulates realistic ad click and conversion data with embedded fraud patterns
Supports both PostgreSQL and CSV output
"""

import random
import argparse
import csv
from datetime import datetime, timedelta
from typing import List, Dict, Tuple
import uuid
from faker import Faker
import sys

# Initialize Faker for realistic data generation
fake = Faker()


class AdTrafficGenerator:
    """Generates synthetic ad traffic data with realistic fraud patterns"""
    
    def __init__(self, num_events: int = 100000, fraud_rate: float = 0.20):
        """
        Initialize the generator
        
        Args:
            num_events: Total number of click events to generate
            fraud_rate: Percentage of events that should be fraudulent (0.0 to 1.0)
        """
        self.num_events = num_events
        self.fraud_rate = fraud_rate
        self.start_date = datetime.now() - timedelta(days=30)
        
        # Pre-generate some fraudulent IPs for consistency
        self.fraud_bot_ips = [fake.ipv4() for _ in range(50)]
        self.fraud_click_farm_ips = [fake.ipv4() for _ in range(30)]
        
        # Legitimate IP pool (simulate normal users)
        self.legitimate_ips = [fake.ipv4() for _ in range(5000)]
        
        # Campaign IDs (matching schema)
        self.campaign_ids = [1, 2, 3]
        
        # Device distributions
        self.devices = {
            'mobile': 0.60,  # 60% mobile
            'desktop': 0.35,  # 35% desktop
            'tablet': 0.05   # 5% tablet
        }
        
        # Browser distributions
        self.browsers = {
            'Chrome': 0.65,
            'Safari': 0.20,
            'Firefox': 0.10,
            'Edge': 0.05
        }
        
        # Countries with weights
        self.countries = {
            'US': 0.50,
            'GB': 0.15,
            'CA': 0.10,
            'AU': 0.08,
            'DE': 0.07,
            'FR': 0.05,
            'JP': 0.03,
            'IN': 0.02
        }
        
        # Fraudulent user agents (outdated browsers, bots)
        self.fraud_user_agents = [
            'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
            'Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36',
            'curl/7.64.1',
            'Python-urllib/3.8',
            'PhantomJS/2.1.1',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:58.0) Gecko/20100101 Firefox/58.0'
        ]
    
    def weighted_choice(self, choices: Dict) -> str:
        """Select item based on weights"""
        items = list(choices.keys())
        weights = list(choices.values())
        return random.choices(items, weights=weights, k=1)[0]
    
    def generate_user_agent(self, is_fraud: bool = False) -> str:
        """Generate realistic user agent string"""
        if is_fraud and random.random() < 0.7:
            return random.choice(self.fraud_user_agents)
        
        browser = self.weighted_choice(self.browsers)
        os_type = random.choice(['Windows NT 10.0', 'Macintosh; Intel Mac OS X 10_15_7', 'X11; Linux x86_64'])
        
        if browser == 'Chrome':
            version = random.randint(110, 122)
            return f'Mozilla/5.0 ({os_type}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{version}.0.0.0 Safari/537.36'
        elif browser == 'Safari':
            return f'Mozilla/5.0 ({os_type}) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'
        elif browser == 'Firefox':
            version = random.randint(115, 125)
            return f'Mozilla/5.0 ({os_type}; rv:{version}.0) Gecko/20100101 Firefox/{version}.0'
        else:  # Edge
            version = random.randint(110, 122)
            return f'Mozilla/5.0 ({os_type}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{version}.0.0.0 Safari/537.36 Edg/{version}.0.0.0'
    
    def generate_geo_data(self, country: str) -> Tuple[str, str, float, float]:
        """Generate geographic data for a country"""
        cities = {
            'US': [('New York', 40.7128, -74.0060), ('Los Angeles', 34.0522, -118.2437), 
                   ('Chicago', 41.8781, -87.6298), ('Houston', 29.7604, -95.3698)],
            'GB': [('London', 51.5074, -0.1278), ('Manchester', 53.4808, -2.2426)],
            'CA': [('Toronto', 43.6532, -79.3832), ('Vancouver', 49.2827, -123.1207)],
            'AU': [('Sydney', -33.8688, 151.2093), ('Melbourne', -37.8136, 144.9631)],
            'DE': [('Berlin', 52.5200, 13.4050), ('Munich', 48.1351, 11.5820)],
            'FR': [('Paris', 48.8566, 2.3522), ('Lyon', 45.7640, 4.8357)],
            'JP': [('Tokyo', 35.6762, 139.6503), ('Osaka', 34.6937, 135.5023)],
            'IN': [('Mumbai', 19.0760, 72.8777), ('Delhi', 28.7041, 77.1025)]
        }
        
        city_data = random.choice(cities.get(country, [('Unknown', 0.0, 0.0)]))
        region = city_data[0] + ' Region'
        
        return region, city_data[0], city_data[1], city_data[2]
    
    def generate_click_event(self, index: int, is_fraud: bool) -> Dict:
        """Generate a single click event"""
        # Determine fraud pattern
        fraud_pattern = None
        if is_fraud:
            fraud_pattern = random.choice(['bot_network', 'click_farm', 'geo_anomaly', 'blacklist'])
        
        # Select IP based on fraud pattern
        if fraud_pattern == 'bot_network':
            ip_address = random.choice(self.fraud_bot_ips)
        elif fraud_pattern == 'click_farm':
            ip_address = random.choice(self.fraud_click_farm_ips)
        else:
            ip_address = random.choice(self.legitimate_ips)
        
        # User and session IDs
        user_id = f"user_{random.randint(1, 50000 if not is_fraud else 1000)}"
        session_id = f"session_{uuid.uuid4().hex[:16]}"
        
        # Campaign
        campaign_id = random.choice(self.campaign_ids)
        
        # Device and browser
        device_type = self.weighted_choice(self.devices)
        user_agent = self.generate_user_agent(is_fraud)
        
        # Extract browser info from user agent
        if 'Chrome' in user_agent and 'Edg' not in user_agent:
            browser_name = 'Chrome'
        elif 'Safari' in user_agent and 'Chrome' not in user_agent:
            browser_name = 'Safari'
        elif 'Firefox' in user_agent:
            browser_name = 'Firefox'
        elif 'Edg' in user_agent:
            browser_name = 'Edge'
        else:
            browser_name = 'Other'
        
        os_name = 'Windows' if 'Windows' in user_agent else 'macOS' if 'Mac' in user_agent else 'Linux'
        
        # Geographic data
        country = self.weighted_choice(self.countries)
        region, city, latitude, longitude = self.generate_geo_data(country)
        
        # Timestamp - spread over 30 days, with fraud creating burst patterns
        if fraud_pattern == 'bot_network' and random.random() < 0.3:
            # Create burst: multiple clicks in short time
            base_time = self.start_date + timedelta(
                days=random.randint(0, 29),
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59)
            )
            timestamp = base_time + timedelta(seconds=random.randint(0, 10))
        else:
            timestamp = self.start_date + timedelta(
                days=random.randint(0, 29),
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59),
                seconds=random.randint(0, 59)
            )
        
        # Behavioral signals
        time_on_page = random.randint(1, 300) if not is_fraud else random.randint(0, 5)
        scroll_depth = random.randint(20, 100) if not is_fraud else random.randint(0, 15)
        
        # Fraud scoring
        fraud_score = 0
        fraud_reasons = []
        
        if is_fraud:
            if fraud_pattern == 'bot_network':
                fraud_score = random.randint(80, 100)
                fraud_reasons = ['burst', 'suspicious_user_agent']
            elif fraud_pattern == 'click_farm':
                fraud_score = random.randint(70, 90)
                fraud_reasons = ['burst', 'short_time_on_page']
            elif fraud_pattern == 'geo_anomaly':
                fraud_score = random.randint(60, 85)
                fraud_reasons = ['geo_anomaly']
            elif fraud_pattern == 'blacklist':
                fraud_score = random.randint(75, 95)
                fraud_reasons = ['blacklist']
        else:
            fraud_score = random.randint(0, 25)
        
        return {
            'click_id': str(uuid.uuid4()),
            'user_id': user_id,
            'session_id': session_id,
            'campaign_id': campaign_id,
            'ad_id': f"ad_{random.randint(1, 100)}",
            'placement_id': f"placement_{random.randint(1, 50)}",
            'ip_address': ip_address,
            'user_agent': user_agent,
            'device_type': device_type,
            'os_name': os_name,
            'browser_name': browser_name,
            'browser_version': str(random.randint(90, 125)),
            'geo_country': country,
            'geo_region': region,
            'geo_city': city,
            'geo_latitude': latitude,
            'geo_longitude': longitude,
            'referrer_url': fake.url() if random.random() < 0.8 else None,
            'landing_page_url': f"https://example-advertiser.com/page_{random.randint(1, 20)}",
            'time_on_page': time_on_page,
            'scroll_depth': scroll_depth,
            'timestamp': timestamp.isoformat(),
            'is_suspicious': is_fraud,
            'fraud_score': fraud_score,
            'fraud_reasons': fraud_reasons,
            'fraud_pattern': fraud_pattern  # For analysis, not in schema
        }
    
    def generate_conversion_event(self, click: Dict) -> Dict:
        """Generate a conversion event based on a click"""
        # Conversions should happen after clicks
        click_time = datetime.fromisoformat(click['timestamp'])
        
        # Fraudulent conversions happen very quickly
        if click['is_suspicious']:
            conversion_delay = timedelta(seconds=random.uniform(0.5, 3))
        else:
            # Legitimate conversions take longer
            conversion_delay = timedelta(seconds=random.uniform(5, 3600))
        
        conversion_time = click_time + conversion_delay
        
        # Revenue varies
        if click['campaign_id'] == 1:  # Summer Sale
            revenue = round(random.uniform(25, 200), 2)
        elif click['campaign_id'] == 2:  # Black Friday
            revenue = round(random.uniform(50, 500), 2)
        else:  # Brand Awareness
            revenue = round(random.uniform(15, 100), 2)
        
        return {
            'conversion_id': str(uuid.uuid4()),
            'user_id': click['user_id'],
            'session_id': click['session_id'],
            'order_id': f"order_{uuid.uuid4().hex[:12]}",
            'revenue': revenue,
            'currency': 'USD',
            'product_category': random.choice(['Electronics', 'Clothing', 'Home', 'Sports', 'Books']),
            'attributed_click_id': click['click_id'],
            'attribution_model': 'last_click',
            'conversion_type': 'purchase',
            'conversion_funnel_step': 3,
            'timestamp': conversion_time.isoformat(),
            'is_suspicious': click['is_suspicious'],
            'fraud_score': click['fraud_score']
        }
    
    def generate_dataset(self) -> Tuple[List[Dict], List[Dict]]:
        """Generate complete dataset of clicks and conversions"""
        print(f"Generating {self.num_events:,} click events...")
        
        clicks = []
        conversions = []
        
        num_fraud = int(self.num_events * self.fraud_rate)
        
        for i in range(self.num_events):
            is_fraud = i < num_fraud
            click = self.generate_click_event(i, is_fraud)
            clicks.append(click)
            
            # Generate conversion (conversion rate ~5% for legit, 3% for fraud)
            conversion_rate = 0.03 if is_fraud else 0.05
            if random.random() < conversion_rate:
                conversion = self.generate_conversion_event(click)
                conversions.append(conversion)
            
            if (i + 1) % 10000 == 0:
                print(f"  Generated {i + 1:,} clicks, {len(conversions):,} conversions")
        
        print(f"✓ Generated {len(clicks):,} clicks and {len(conversions):,} conversions")
        print(f"  Fraud rate: {num_fraud / len(clicks) * 100:.1f}%")
        
        return clicks, conversions
    
    def save_to_csv(self, clicks: List[Dict], conversions: List[Dict], output_dir: str = './data'):
        """Save data to CSV files"""
        import os
        os.makedirs(output_dir, exist_ok=True)
        
        # Save clicks
        clicks_file = os.path.join(output_dir, 'sample_clicks.csv')
        click_fields = [k for k in clicks[0].keys() if k != 'fraud_pattern']  # Exclude internal field
        
        with open(clicks_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=click_fields)
            writer.writeheader()
            for click in clicks:
                row = {k: v for k, v in click.items() if k != 'fraud_pattern'}
                # Convert lists to PostgreSQL array format
                if 'fraud_reasons' in row:
                    row['fraud_reasons'] = '{' + ','.join(row['fraud_reasons']) + '}' if row['fraud_reasons'] else '{}'
                writer.writerow(row)
        
        print(f"✓ Saved clicks to {clicks_file}")
        
        # Save conversions
        conversions_file = os.path.join(output_dir, 'sample_conversions.csv')
        conversion_fields = list(conversions[0].keys())
        
        with open(conversions_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=conversion_fields)
            writer.writeheader()
            writer.writerows(conversions)
        
        print(f"✓ Saved conversions to {conversions_file}")
        
        # Generate summary statistics
        summary_file = os.path.join(output_dir, 'dataset_summary.txt')
        with open(summary_file, 'w') as f:
            f.write("AdVigilance Dataset Summary\n")
            f.write("=" * 50 + "\n\n")
            f.write(f"Total Clicks: {len(clicks):,}\n")
            f.write(f"Total Conversions: {len(conversions):,}\n")
            f.write(f"Conversion Rate: {len(conversions) / len(clicks) * 100:.2f}%\n\n")
            
            fraud_clicks = sum(1 for c in clicks if c['is_suspicious'])
            f.write(f"Fraudulent Clicks: {fraud_clicks:,}\n")
            f.write(f"Fraud Rate: {fraud_clicks / len(clicks) * 100:.2f}%\n\n")
            
            # Fraud breakdown by pattern
            patterns = {}
            for click in clicks:
                if click.get('fraud_pattern'):
                    patterns[click['fraud_pattern']] = patterns.get(click['fraud_pattern'], 0) + 1
            
            f.write("Fraud Pattern Breakdown:\n")
            for pattern, count in sorted(patterns.items(), key=lambda x: x[1], reverse=True):
                f.write(f"  {pattern}: {count:,} ({count / fraud_clicks * 100:.1f}%)\n")
        
        print(f"✓ Saved summary to {summary_file}")


def main():
    parser = argparse.ArgumentParser(description='Generate synthetic ad traffic data for AdVigilance')
    parser.add_argument('--events', type=int, default=100000, help='Number of click events to generate')
    parser.add_argument('--fraud-rate', type=float, default=0.23, help='Fraud rate (0.0 to 1.0)')
    parser.add_argument('--output', type=str, default='./data', help='Output directory for CSV files')
    
    args = parser.parse_args()
    
    print("\n" + "=" * 60)
    print("AdVigilance Data Generator")
    print("=" * 60 + "\n")
    
    # Validate inputs
    if args.fraud_rate < 0 or args.fraud_rate > 1:
        print("Error: fraud-rate must be between 0.0 and 1.0")
        sys.exit(1)
    
    # Generate data
    generator = AdTrafficGenerator(num_events=args.events, fraud_rate=args.fraud_rate)
    clicks, conversions = generator.generate_dataset()
    
    # Save to CSV
    generator.save_to_csv(clicks, conversions, output_dir=args.output)
    
    print("\n" + "=" * 60)
    print("Dataset generation complete!")
    print("=" * 60 + "\n")
    print("Next steps:")
    print("1. Load data: psql -d advigilance -c \"\\copy click_stream FROM 'data/sample_clicks.csv' CSV HEADER\"")
    print("2. Run fraud detection: python scripts/fraud_detector.py")
    print("3. Generate report: python scripts/generate_report.py")
    print()


if __name__ == '__main__':
    main()
