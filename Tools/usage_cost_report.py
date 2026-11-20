#!/usr/bin/env python3
"""Summarize existing usage without mutating the ledger or estimating prices.

Optional Soniox CSV columns: client_reference_id,cost_usd. Only a unique,
valid match is treated as supplier-reported cost. No content or identifiers
are included in the output; unknown costs are counted, never treated as zero.
"""
import argparse
import csv
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import sqlite3


def amount(value):
    try:
        result = Decimal(str(value))
        return result if result.is_finite() and result >= 0 else None
    except (InvalidOperation, TypeError, ValueError):
        return None


def summarize(records, supplier_rows=()):
    matches = {}
    for row in supplier_rows:
        ref = row.get('client_reference_id')
        if ref:
            matches.setdefault(ref, []).append(amount(row.get('cost_usd')))
    report = {}
    for record in records:
        kind = record.get('kind')
        if kind not in ('speech', 'translation', 'assistant'):
            raise ValueError('unexpected event kind')
        bucket = report.setdefault(kind, {'requests': 0, 'billed': 0, 'estimated': 0,
                                          'unknown': 0, 'not_applicable': 0, 'totals': {}})
        bucket['requests'] += 1
        currency = None
        value = None
        candidates = matches.get(record.get('request_id'), []) if kind == 'speech' and record.get('provider') == 'soniox' else []
        if len(candidates) == 1 and candidates[0] is not None:
            classification, currency, value = 'billed', 'USD', candidates[0]
        elif candidates:
            classification = 'unknown'
        elif record.get('upstream_attempts') == 0 and record.get('outcome') in ('success', 'failure', 'cancelled'):
            classification = 'not_applicable'
        elif amount(record.get('estimated_cost')) is not None and record.get('currency') in ('USD', 'CNY'):
            classification, currency, value = 'estimated', record['currency'], amount(record['estimated_cost'])
        else:
            classification = 'unknown'
        bucket[classification] += 1
        if value is not None:
            key = classification + '_' + currency
            bucket['totals'][key] = str(Decimal(bucket['totals'].get(key, '0')) + value)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ledger', type=Path)
    parser.add_argument('--soniox-csv', type=Path)
    args = parser.parse_args()
    if not args.ledger.is_file():
        parser.error('ledger must be an existing file')
    uri = args.ledger.resolve().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as db:
        records = [json.loads(row[0]) for row in db.execute('SELECT record FROM events')]
    rows = []
    if args.soniox_csv:
        with args.soniox_csv.open(newline='', encoding='utf-8-sig') as stream:
            reader = csv.DictReader(stream)
            if not {'client_reference_id', 'cost_usd'} <= set(reader.fieldnames or []):
                parser.error('supplier CSV must contain client_reference_id and cost_usd')
            rows = list(reader)
    print(json.dumps({'features': summarize(records, rows),
                      'note': 'Supplier matches and estimates are separate; unknown is not zero.'},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
