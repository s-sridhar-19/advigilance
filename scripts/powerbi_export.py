#!/usr/bin/env python3
"""
Power BI Data Export Script
Exports AdVigilance fraud detection data to CSV for Power BI import
"""

import psycopg2
import pandas as pd
from pathlib import Path
from datetime import datetime
import argparse
import sys
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class PowerBIExporter:
    """Export PostgreSQL data to Power BI-optimized CSV files"""
    
    def __init__(self, db_config: dict):
        """
        Initialize exporter with database connection
        
        Args:
            db_config: Dict with keys: dbname, user, password, host, port
        """
        self.db_config = db_config
        self.conn = None
        
    def connect(self):
        """Establish database connection"""
        try:
            self.conn = psycopg2.connect(**self.db_config)
            logger.info(f"✓ Connected to {self.db_config['dbname']} on {self.db_config['host']}")
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            sys.exit(1)
    
    def close(self):
        """Close database connection"""
        if self.conn:
            self.conn.close()
            logger.info("✓ Database connection closed")
    
    def export_view(self, view_name: str, output_file: Path, limit: int = None):
        """
        Export a database view to CSV
        
        Args:
            view_name: Name of the view to export
            output_file: Path to output CSV file
            limit: Optional row limit for testing
        """
        logger.info(f"Exporting {view_name}...")
        
        try:
            # Build query
            query = f"SELECT * FROM advigilance.{view_name}"
            if limit:
                query += f" LIMIT {limit}"
            
            # Read data
            df = pd.read_sql(query, self.conn)
            
            # Clean column names for Power BI
            df.columns = [
                col.replace('_', ' ').title() 
                for col in df.columns
            ]
            
            # Handle data types
            for col in df.columns:
                # Convert timestamps to strings (Power BI will parse)
                if pd.api.types.is_datetime64_any_dtype(df[col]):
                    df[col] = df[col].dt.strftime('%Y-%m-%d %H:%M:%S')
                
                # Convert arrays to strings
                elif df[col].dtype == 'object':
                    df[col] = df[col].astype(str)
            
            # Export to CSV
            df.to_csv(output_file, index=False, encoding='utf-8')
            
            logger.info(f"  ✓ Exported {len(df):,} rows to {output_file}")
            
            # Show sample
            if len(df) > 0:
                logger.info(f"  Sample columns: {', '.join(df.columns[:5])}")
            
            return len(df)
            
        except Exception as e:
            logger.error(f"  ✗ Failed to export {view_name}: {e}")
            return 0
    
    def export_all(self, output_dir: Path, timestamp: bool = True, limit: int = None):
        """
        Export all Power BI views to CSV files
        
        Args:
            output_dir: Directory to save CSV files
            timestamp: Whether to add timestamp to filenames
            limit: Optional row limit for testing
        """
        # Create output directory
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # Get timestamp suffix
        ts = f"_{datetime.now().strftime('%Y%m%d_%H%M%S')}" if timestamp else ""
        
        # Define exports
        exports = {
            'fraud_summary': 'powerbi_fraud_summary',
            'campaign_performance': 'powerbi_campaign_performance',
            'top_fraud_sources': 'powerbi_top_fraud_sources',
            'hourly_trends': 'powerbi_hourly_fraud_trends',
        }
        
        # Track statistics
        total_rows = 0
        successful_exports = 0
        
        logger.info(f"\nExporting {len(exports)} views to {output_dir}")
        logger.info("=" * 60)
        
        for filename, view_name in exports.items():
            output_file = output_dir / f"{filename}{ts}.csv"
            rows = self.export_view(view_name, output_file, limit)
            
            if rows > 0:
                successful_exports += 1
                total_rows += rows
        
        logger.info("=" * 60)
        logger.info(f"\n✓ Export complete!")
        logger.info(f"  Files exported: {successful_exports}/{len(exports)}")
        logger.info(f"  Total rows: {total_rows:,}")
        logger.info(f"  Output directory: {output_dir}")
        
        return successful_exports, total_rows
    
    def create_powerbi_manifest(self, output_dir: Path):
        """
        Create a manifest file with metadata about the exports
        Useful for Power BI data source documentation
        """
        manifest = {
            'export_date': datetime.now().isoformat(),
            'database': self.db_config['dbname'],
            'server': f"{self.db_config['host']}:{self.db_config['port']}",
            'files': []
        }
        
        # List all CSV files in output directory
        for csv_file in output_dir.glob('*.csv'):
            manifest['files'].append({
                'filename': csv_file.name,
                'size_bytes': csv_file.stat().st_size,
                'modified': datetime.fromtimestamp(csv_file.stat().st_mtime).isoformat()
            })
        
        # Save manifest
        manifest_file = output_dir / 'manifest.json'
        import json
        with open(manifest_file, 'w') as f:
            json.dump(manifest, f, indent=2)
        
        logger.info(f"✓ Created manifest: {manifest_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Export AdVigilance data for Power BI',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Export all views with timestamp
  python powerbi_export.py --output powerbi_exports/
  
  # Export specific view
  python powerbi_export.py --view powerbi_fraud_summary --output exports/
  
  # Test export (first 1000 rows only)
  python powerbi_export.py --output test_exports/ --limit 1000
  
  # Export without timestamp in filename
  python powerbi_export.py --output exports/ --no-timestamp
        """
    )
    
    # Database connection arguments
    parser.add_argument('--dbname', default='advigilance', help='Database name')
    parser.add_argument('--user', default='postgres', help='Database user')
    parser.add_argument('--password', default='', help='Database password')
    parser.add_argument('--host', default='localhost', help='Database host')
    parser.add_argument('--port', default='5432', help='Database port')
    
    # Export arguments
    parser.add_argument('--output', default='powerbi_exports', help='Output directory')
    parser.add_argument('--view', help='Export specific view only (e.g., powerbi_fraud_summary)')
    parser.add_argument('--limit', type=int, help='Limit number of rows (for testing)')
    parser.add_argument('--no-timestamp', action='store_true', help='Do not add timestamp to filenames')
    parser.add_argument('--manifest', action='store_true', help='Create manifest.json file')
    
    args = parser.parse_args()
    
    # Build database configuration
    db_config = {
        'dbname': args.dbname,
        'user': args.user,
        'password': args.password,
        'host': args.host,
        'port': args.port
    }
    
    # Initialize exporter
    exporter = PowerBIExporter(db_config)
    
    try:
        # Connect to database
        exporter.connect()
        
        # Create output directory
        output_dir = Path(args.output)
        
        # Export data
        if args.view:
            # Export single view
            output_file = output_dir / f"{args.view}.csv"
            exporter.export_view(args.view, output_file, args.limit)
        else:
            # Export all views
            exporter.export_all(
                output_dir, 
                timestamp=not args.no_timestamp,
                limit=args.limit
            )
        
        # Create manifest if requested
        if args.manifest:
            exporter.create_powerbi_manifest(output_dir)
        
        # Instructions for Power BI
        logger.info("\n" + "=" * 60)
        logger.info("Power BI Import Instructions:")
        logger.info("=" * 60)
        logger.info("1. Open Power BI Desktop")
        logger.info("2. Get Data → Text/CSV")
        logger.info(f"3. Navigate to: {output_dir.absolute()}")
        logger.info("4. Select CSV file(s) to import")
        logger.info("5. Click 'Transform Data' to adjust data types")
        logger.info("6. Close & Apply")
        logger.info("")
        logger.info("Recommended data type changes:")
        logger.info("  - 'Hour' → Date/Time")
        logger.info("  - 'Fraud Score' → Whole Number")
        logger.info("  - 'Total Revenue' → Decimal Number")
        logger.info("")
        
    except KeyboardInterrupt:
        logger.warning("\n⚠ Export interrupted by user")
    except Exception as e:
        logger.error(f"\n✗ Export failed: {e}")
        sys.exit(1)
    finally:
        # Close connection
        exporter.close()


if __name__ == '__main__':
    main()
