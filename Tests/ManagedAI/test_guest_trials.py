import concurrent.futures,hashlib,os,pathlib,sqlite3,subprocess,sys,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/ManagedAI'))
from account_store import AccountStore
from guest_trials import GuestTrials
from session_issuer import SessionIssuer

class GuestTrialsTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.path=os.path.join(self.tmp.name,'db');self.now=1780000000
  self.store=AccountStore(self.path,clock=lambda:self.now,requests_per_minute=2)
  self.store.put_global_limits(100,100)
  self.guests=GuestTrials(self.store)
 def tearDown(self):self.tmp.cleanup()
 def configure(self,max_accounts=3,max_seconds=6):
  self.guests.initialize(max_accounts=max_accounts,seconds_per_account=2,requests_per_account=5,max_seconds=max_seconds)
 def session(self,result):return self.store.authenticate(hashlib.sha256(result['token'].encode()).hexdigest())
 def test_disabled_and_non_resettable(self):
  self.assertIsNone(self.guests.issue())
  self.configure()
  with self.assertRaises(sqlite3.IntegrityError):self.configure()
  with self.assertRaises(ValueError):self.guests.issue(ttl_seconds=86401)
 def test_global_reservation_atomic_against_mass_signup_and_restart(self):
  self.configure(max_accounts=20,max_seconds=6)
  with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
   results=list(pool.map(lambda _:self.guests.issue(),range(30)))
  results=[r for r in results if r];self.assertEqual(len(results),3)
  self.assertEqual(len({r['token'] for r in results}),3)
  again=GuestTrials(AccountStore(self.path,clock=lambda:self.now)).issue()
  self.assertIsNone(again)
  with self.store._connection() as db:
   self.assertEqual(db.execute('SELECT issued_accounts,reserved_seconds FROM guest_pool').fetchone(),(3,6))
  data=pathlib.Path(self.path).read_bytes()
  for result in results:self.assertNotIn(result['token'].encode(),data)
 def test_parallel_processes_cannot_oversubscribe_global_pool(self):
  self.configure(max_accounts=20,max_seconds=6)
  code="from account_store import AccountStore; from guest_trials import GuestTrials; import sys; print(int(GuestTrials(AccountStore(sys.argv[1])).issue() is not None))"
  env=os.environ.copy();env['PYTHONPATH']=str(ROOT/'Services/ManagedAI')
  children=[subprocess.Popen([sys.executable,'-c',code,self.path],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(12)]
  issued=[]
  for child in children:
   out,err=child.communicate(timeout=15);self.assertEqual(child.returncode,0,err);issued.append(int(out.strip()))
  self.assertEqual(sum(issued),3)
 def test_lifetime_seconds_not_reset_by_day_or_revoke(self):
  self.configure(); result=self.guests.issue(ttl_seconds=86400);session=self.session(result)
  self.assertTrue(self.store.consume_speech(session,1));self.assertTrue(self.store.consume_speech(session,1))
  self.assertFalse(self.store.consume_speech(session,1));self.assertFalse(self.store.consume(session))
  self.now+=86400
  # Even a newly issued session for the same account cannot reset its lifetime budget.
  token=SessionIssuer(self.store).issue(session.account,60)
  renewed=self.store.authenticate(hashlib.sha256(token.encode()).hexdigest())
  self.assertFalse(self.store.consume_speech(renewed,1));self.assertFalse(self.store.consume(renewed))
  self.assertTrue(SessionIssuer(self.store).revoke(token));self.assertIsNone(self.store.authenticate(hashlib.sha256(token.encode()).hexdigest()))
 def test_no_global_budget_no_session(self):
  self.configure()
  with self.store._connection() as db:db.execute('DELETE FROM global_limits')
  self.assertIsNone(self.guests.issue())
  with self.store._connection() as db:self.assertEqual(db.execute('SELECT issued_accounts,reserved_seconds FROM guest_pool').fetchone(),(0,0))
 def test_exhausted_daily_budget_does_not_consume_guest_pool(self):
  self.configure(); self.store.put_global_limits(1,1)
  self.store.put_account('other',2);self.store.put_speech_limit('other',2)
  token=SessionIssuer(self.store).issue('other',60)
  session=self.store.authenticate(hashlib.sha256(token.encode()).hexdigest())
  self.assertTrue(self.store.consume_speech(session,1));self.assertIsNone(self.guests.issue())
  with self.store._connection() as db:self.assertEqual(db.execute('SELECT issued_accounts,reserved_seconds FROM guest_pool').fetchone(),(0,0))
 def test_guest_expiration_does_not_recredit_pool(self):
  self.configure(max_accounts=1,max_seconds=2);result=self.guests.issue(ttl_seconds=60)
  self.assertIsNotNone(self.session(result));self.now+=60
  self.assertIsNone(self.session(result));self.assertIsNone(self.guests.issue())
  with self.store._connection() as db:self.assertEqual(db.execute('SELECT issued_accounts,reserved_seconds FROM guest_pool').fetchone(),(1,2))
 def test_lifetime_request_limit_is_atomic_and_survives_day_and_restart(self):
  self.configure(); result=self.guests.issue();session=self.session(result)
  store=AccountStore(self.path,clock=lambda:self.now,requests_per_minute=60)
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
   attempts=list(pool.map(lambda _:store.consume(session),range(12)))
  self.assertEqual(sum(attempts),5)
  self.now+=86400
  renewed_token=SessionIssuer(store).issue(session.account,60)
  restarted=AccountStore(self.path,clock=lambda:self.now,requests_per_minute=60)
  renewed=restarted.authenticate(hashlib.sha256(renewed_token.encode()).hexdigest())
  self.assertFalse(restarted.consume(renewed))
 def test_prior_guest_schema_migration_preserves_request_use(self):
  self.store.put_account('old-guest',5);self.store.put_speech_limit('old-guest',2)
  with self.store._connection() as db:
   db.execute('DROP TABLE guest_accounts')
   db.execute('CREATE TABLE guest_accounts (account_id TEXT PRIMARY KEY REFERENCES accounts(account_id),lifetime_seconds INTEGER NOT NULL,used_seconds INTEGER NOT NULL DEFAULT 0)')
   db.execute('INSERT INTO guest_accounts VALUES(?,?,?)',('old-guest',2,1))
   db.execute('INSERT INTO daily_usage VALUES(?,?,?)',('old-guest','2026-01-01',2))
   db.execute('INSERT INTO daily_usage VALUES(?,?,?)',('old-guest','2026-01-02',1))
  migrated=AccountStore(self.path,clock=lambda:self.now)
  with migrated._connection() as db:
   self.assertEqual(db.execute('SELECT lifetime_seconds,used_seconds,lifetime_requests,used_requests FROM guest_accounts WHERE account_id=?',('old-guest',)).fetchone(),(2,1,5,3))

if __name__=='__main__':unittest.main()
