import asyncio
import datetime
import hashlib
import pathlib
import sys
import tempfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Services/MORIQPersonalBeta'))
from account_store import AccountStore
from anonymous_activation import AnonymousActivation
from caption_memory_ledger import MemorySourceLedger


class CaptionBudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = AccountStore(str(pathlib.Path(self.temp.name) / 'accounts.db'))
        self.store.put_global_limits(10, 7200)
        self.activation = AnonymousActivation(self.store)
        self.ledger = MemorySourceLedger(self.store, fake_only=True)
        self.addCleanup(self.ledger.shutdown)

    def claim(self, account):
        session, epoch, unit = (str(uuid.uuid4()) for _ in range(3))
        self.ledger.put_final(account, session, epoch, unit, 1,
                              [{'text': 'Hello.', 'is_final': True, 'translation_status': 'original'}])
        return self.ledger._claim(account, session, epoch, unit, 1, 'zh-Hans')

    def test_anonymous_translation_keeps_global_limits_and_usage(self):
        access, device = 'a' * 64, 'd' * 64
        self.assertTrue(self.activation.activate(device, access))
        account = self.store.authenticate(hashlib.sha256(access.encode()).hexdigest())
        self.assertTrue(self.store.consume(account))  # Starting the speech stream.
        day = datetime.datetime.fromtimestamp(self.store.clock(), datetime.timezone.utc).date().isoformat()
        with self.store._connection() as db:
            db.execute('INSERT INTO volatile_source_chars VALUES(?,?,?)', (account.account, day, 20000))
        self.assertEqual(self.claim(account)[0], 'Hello.')
        with self.store._connection() as db:
            self.assertEqual(db.execute('SELECT requests FROM global_usage WHERE day=?', (day,)).fetchone()[0], 2)
            self.assertGreater(db.execute('SELECT characters FROM volatile_source_chars WHERE account_id=? AND day=?', (account.account, day)).fetchone()[0], 20000)
            db.execute('UPDATE global_limits SET daily_requests=2 WHERE singleton=1')
        with self.assertRaises(PermissionError):
            self.claim(account)
        with self.store._connection() as db:
            db.execute('UPDATE global_limits SET daily_requests=10 WHERE singleton=1')
            db.execute('UPDATE volatile_source_global_chars SET characters=100000 WHERE day=?', (day,))
        with self.assertRaises(PermissionError):
            self.claim(account)

    def test_existing_account_keeps_its_limit(self):
        token = 'b' * 64
        self.store.put_account('existing', 1)
        self.store.put_speech_limit('existing', 60)
        digest = hashlib.sha256(token.encode()).hexdigest()
        self.store.add_session('existing', digest, self.store.clock() + 3600)
        account = self.store.authenticate(digest)
        self.assertTrue(self.store.consume(account))
        with self.assertRaises(PermissionError):
            self.claim(account)

    def test_automatic_translation_dispatches_after_speech_start(self):
        access, device = 'c' * 64, 'e' * 64
        self.assertTrue(self.activation.activate(device, access))
        account = self.store.authenticate(hashlib.sha256(access.encode()).hexdigest())
        self.assertTrue(self.store.consume(account))
        session, epoch, unit = (str(uuid.uuid4()) for _ in range(3))
        self.ledger.put_final(account, session, epoch, unit, 1,
                              [{'text': 'Hello.', 'is_final': True, 'translation_status': 'original'}])
        calls = []

        async def provider(source, target):
            calls.append((source, target))
            return '你好。'

        result = asyncio.run(self.ledger.review(account, {
            'session': session, 'epoch': epoch, 'unit': unit,
            'revision': 1, 'target': 'zh-Hans',
        }, provider))
        self.assertEqual(result['status'], 'candidate')
        self.assertEqual(result['candidate'], '你好。')
        self.assertEqual(calls, [('Hello.', 'zh-Hans')])


if __name__ == '__main__':
    unittest.main()
