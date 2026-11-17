"""Local administrator control for device issuance; no network endpoint."""
import argparse,os,pathlib,sqlite3,stat,sys
from account_store import AccountStore
from device_sessions import DeviceSessions

REQUIRED={'accounts','sessions','device_sessions_v2','device_scopes_v1','device_issuance_control_v1'}

def open_existing(path):
 p=pathlib.Path(path)
 if not p.is_absolute() or p.resolve()!=p:raise ValueError('database path must be absolute and canonical')
 info=os.lstat(p)
 if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('database must be private and owned')
 with sqlite3.connect('file:'+str(p)+'?mode=ro',uri=True) as db:
  if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):raise ValueError('database integrity failed')
  names={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
  if not REQUIRED<=names:raise ValueError('not an initialized device database')
 return AccountStore(str(p))

def control(path,action):
 store=open_existing(path);devices=DeviceSessions(store)
 if action=='prepare':devices.prepare_rollback()
 elif action=='resume':devices.resume_issuance()
 elif action!='status':raise ValueError('invalid action')
 with store._connection() as db:
  mode=db.execute('SELECT mode FROM device_issuance_control_v1 WHERE singleton=1').fetchone()
  if mode is None:raise ValueError('missing control state')
  active=db.execute('SELECT count(*) FROM device_sessions_v2 d JOIN sessions s ON s.token_hash=d.session_hash WHERE d.revoked=0 AND d.expires_at>? AND s.revoked=0 AND s.expires_at>?',(store.clock(),store.clock())).fetchone()[0]
 return mode[0],active

def main():
 p=argparse.ArgumentParser();p.add_argument('--database',required=True);p.add_argument('action',choices=('status','prepare','resume'));a=p.parse_args()
 try:mode,active=control(a.database,a.action)
 except (OSError,ValueError,sqlite3.Error):print('Rollback control failed; verify database and permissions.',file=sys.stderr);return 1
 print('issuance='+mode+' active_device_sessions='+str(active));return 0

if __name__=='__main__':sys.exit(main())
