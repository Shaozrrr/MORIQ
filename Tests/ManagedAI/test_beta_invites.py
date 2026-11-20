import concurrent.futures, hashlib, os, pathlib, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/ManagedAI'))
from account_store import AccountStore
from beta_invites import BetaInvites
from session_issuer import SessionIssuer

class BetaInviteTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.path=os.path.join(self.tmp.name,'accounts.db'); self.now=1780000000
        self.store=AccountStore(self.path,clock=lambda:self.now)
        self.store.put_global_limits(10,60); self.store.put_account('beta-user',10); self.store.put_speech_limit('beta-user',30)
        self.invites=BetaInvites(self.store)
    def tearDown(self): self.tmp.cleanup()
    def test_one_use_and_no_plaintext_at_rest(self):
        invite=self.invites.issue('beta-user'); token=self.invites.redeem(invite,60)
        self.assertIsNotNone(token)
        session=self.store.authenticate(hashlib.sha256(token.encode()).hexdigest())
        self.assertEqual(session.account,'beta-user')
        self.assertIsNone(self.invites.redeem(invite)); self.assertFalse(SessionIssuer(self.store).revoke('bad'))
        self.assertTrue(SessionIssuer(self.store).revoke(token))
        self.assertIsNone(self.store.authenticate(hashlib.sha256(token.encode()).hexdigest()))
        data=pathlib.Path(self.path).read_bytes()
        self.assertNotIn(invite.encode(),data); self.assertNotIn(token.encode(),data)
    def test_concurrent_redemption_only_one_session_and_restart(self):
        invite=self.invites.issue('beta-user')
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
            results=list(pool.map(lambda _:self.invites.redeem(invite),range(10)))
        tokens=[x for x in results if x is not None]; self.assertEqual(len(tokens),1)
        reopened=BetaInvites(AccountStore(self.path,clock=lambda:self.now))
        self.assertIsNone(reopened.redeem(invite))
        self.assertIsNotNone(self.store.authenticate(hashlib.sha256(tokens[0].encode()).hexdigest()))
    def test_expired_invalid_unprovisioned_and_duration(self):
        invite=self.invites.issue('beta-user',60); self.now+=60
        self.assertIsNone(self.invites.redeem(invite))
        self.assertIsNone(self.invites.redeem('bad'))
        with self.assertRaises(ValueError): self.invites.issue('missing')
        with self.assertRaises(ValueError): self.invites.issue('beta-user',59)
        with self.assertRaises(ValueError): self.invites.redeem('x'*40,59)

if __name__=='__main__': unittest.main()
