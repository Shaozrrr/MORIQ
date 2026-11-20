import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from Tools.usage_cost_report import summarize


class UsageCostReportTests(unittest.TestCase):
    def test_supplier_match_and_unknown_are_distinct(self):
        records = [
            {'request_id': 'one', 'kind': 'speech', 'provider': 'soniox', 'outcome': 'success', 'upstream_attempts': 1},
            {'request_id': 'missing', 'kind': 'speech', 'provider': 'soniox', 'outcome': 'failure', 'upstream_attempts': 1},
            {'request_id': 'offline', 'kind': 'assistant', 'outcome': 'failure', 'upstream_attempts': 0},
            {'request_id': 'estimate', 'kind': 'translation', 'outcome': 'success', 'upstream_attempts': 1,
             'estimated_cost': '0.05', 'currency': 'CNY'},
        ]
        result = summarize(records, [{'client_reference_id': 'one', 'cost_usd': '0.003858'}])
        self.assertEqual((result['speech']['billed'], result['speech']['unknown']), (1, 1))
        self.assertEqual(result['speech']['totals']['billed_USD'], '0.003858')
        self.assertEqual(result['assistant']['not_applicable'], 1)
        self.assertEqual(result['translation']['totals']['estimated_CNY'], '0.05')

    def test_duplicate_or_invalid_supplier_records_never_become_billed(self):
        row = {'request_id': 'one', 'kind': 'speech', 'provider': 'soniox',
               'outcome': 'success', 'upstream_attempts': 1,
               'estimated_cost': '0.02', 'currency': 'USD'}
        for supplier in ([{'client_reference_id': 'one', 'cost_usd': 'NaN'}],
                         [{'client_reference_id': 'one', 'cost_usd': '1'},
                          {'client_reference_id': 'one', 'cost_usd': '1'}]):
            result = summarize([row], supplier)['speech']
            self.assertEqual(result['unknown'], 1)
            self.assertEqual(result['totals'], {})

    def test_cli_reads_ledger_and_supplier_csv_without_changing_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / 'usage.db'
            record = {'request_id': 'one', 'kind': 'speech', 'provider': 'soniox',
                      'outcome': 'success', 'upstream_attempts': 1}
            with sqlite3.connect(ledger) as db:
                db.execute('CREATE TABLE events(record TEXT NOT NULL)')
                db.execute('INSERT INTO events VALUES(?)', (json.dumps(record),))
            before = ledger.read_bytes()
            csv_path = root / 'supplier.csv'
            csv_path.write_text('client_reference_id,cost_usd\none,0.003858\n')
            script = Path(__file__).resolve().parents[2] / 'Tools/usage_cost_report.py'
            result = subprocess.run([sys.executable, str(script), str(ledger), '--soniox-csv', str(csv_path)],
                                    check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)['features']['speech']['totals']['billed_USD'], '0.003858')
            self.assertEqual(ledger.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
