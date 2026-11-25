"""A large screen context must settle actual usage without disabling services."""
import hashlib
import pathlib
import sqlite3
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Services/MORIQPersonalBeta'))
from account_store import AccountStore


class ReservationOverage(unittest.TestCase):
    def test_settles_actual_and_applies_limits_to_following_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'accounts.db'
            store = AccountStore(path, assistant_schema=True)
            store.put_global_limits(20, 20)
            store.put_account('test', 20)
            store.put_token_limits('test', 12000, 12000)
            token_hash = hashlib.sha256(b'test').hexdigest()
            store.add_session('test', token_hash, time.time() + 600)
            session = store.authenticate(token_hash)
            self.assertTrue(store.consume(session, '1' * 32, '2' * 32, 4096))
            self.assertTrue(store.settle_tokens(session, '1' * 32, 11063))
            self.assertFalse(store.settle_tokens(session, '1' * 32, 11063))
            self.assertFalse(store.consume(session, '3' * 32, '4' * 32, 1000))
            self.assertTrue(store.consume(session, '5' * 32, '6' * 32, 900))
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute('SELECT settled_tokens FROM token_reservations WHERE request_id=?', ('1' * 32,)).fetchone(), (11063,))
                self.assertEqual(db.execute('SELECT COUNT(*) FROM token_budget_halt').fetchone(), (0,))


if __name__ == '__main__':
    unittest.main()
