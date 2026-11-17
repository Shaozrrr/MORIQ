"""Issue an invitation to a pre-provisioned account without printing it."""
import argparse,os,pathlib,stat,sys
from account_store import AccountStore
from activation import Activation
from device_invites import digest

def issue(database,account,output,scopes,ttl):
 path=pathlib.Path(output)
 if not path.is_absolute() or path.name in ('.','..') or path.parent.resolve()!=path.parent:
  raise ValueError('output must be an absolute path in a real directory')
 parent=path.parent.stat()
 if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.getuid() or parent.st_mode&0o077:
  raise ValueError('output directory must be private and owned by the current user')
 flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)
 fd=os.open(path,flags,0o600)
 invitation=None;store=None
 try:
  store=AccountStore(database);invitation=Activation(store).issue(account,ttl=ttl,scopes=scopes)
  with os.fdopen(fd,'w',encoding='ascii') as file:
   fd=-1;file.write(invitation+'\n');file.flush();os.fsync(file.fileno())
 except BaseException:
  if fd>=0:os.close(fd)
  if invitation is not None and store is not None:
   with store._connection() as db:db.execute('UPDATE activation_invites_v2 SET cancelled=1 WHERE invite_hash=?',(digest(invitation),))
  try:path.unlink()
  except FileNotFoundError:pass
  raise

def main():
 p=argparse.ArgumentParser();p.add_argument('--database',required=True);p.add_argument('--account',required=True);p.add_argument('--output',required=True)
 p.add_argument('--assistant',action='store_true');p.add_argument('--ttl-seconds',type=int,default=172800)
 a=p.parse_args()
 try:
  issue(a.database,a.account,a.output,('speech','assistant') if a.assistant else ('speech',),a.ttl_seconds)
 except Exception:
  print('Invitation could not be issued; check private paths and account provisioning.',file=sys.stderr);return 1
 print('Invitation saved in the private output file.');return 0

if __name__=='__main__':sys.exit(main())
