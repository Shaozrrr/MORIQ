"""Local SQLite account/session quota primitive, not an identity provider."""
import datetime
from contextlib import contextmanager
import os
import re
import sqlite3
import stat
import time
from urllib.parse import quote
from dataclasses import dataclass

_HASH = re.compile(r'^[0-9a-f]{64}$')
_ACCOUNT = re.compile(r'^[A-Za-z0-9_.-]{1,128}$')

@dataclass(frozen=True)
class AccountSession:
    account: str
    token_hash: str

class AccountStore:
    def __init__(self, path, clock=time.time):
        self.path = os.path.abspath(os.fspath(path))
        self.clock = clock
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            os.close(fd)
        except FileExistsError:
            info = os.lstat(self.path)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('account database must be a private regular file')
        with self._connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS accounts (
                    account_id TEXT PRIMARY KEY, daily_limit INTEGER NOT NULL CHECK(daily_limit > 0)
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id),
                    expires_at REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1))
                );
                CREATE TABLE IF NOT EXISTS daily_usage (
                    account_id TEXT NOT NULL REFERENCES accounts(account_id), day TEXT NOT NULL,
                    requests INTEGER NOT NULL CHECK(requests >= 0), PRIMARY KEY(account_id, day)
                );
                CREATE TABLE IF NOT EXISTS speech_limits (
                    account_id TEXT PRIMARY KEY REFERENCES accounts(account_id),
                    daily_seconds INTEGER NOT NULL CHECK(daily_seconds > 0)
                );
                CREATE TABLE IF NOT EXISTS speech_usage (
                    account_id TEXT NOT NULL REFERENCES accounts(account_id), day TEXT NOT NULL,
                    seconds INTEGER NOT NULL CHECK(seconds >= 0), PRIMARY KEY(account_id, day)
                );
                CREATE TABLE IF NOT EXISTS global_limits (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    daily_requests INTEGER NOT NULL CHECK(daily_requests > 0),
                    daily_speech_seconds INTEGER NOT NULL CHECK(daily_speech_seconds > 0)
                );
                CREATE TABLE IF NOT EXISTS global_usage (
                    day TEXT PRIMARY KEY, requests INTEGER NOT NULL DEFAULT 0 CHECK(requests >= 0),
                    speech_seconds INTEGER NOT NULL DEFAULT 0 CHECK(speech_seconds >= 0)
                );
            ''')
    @contextmanager
    def _connection(self):
        info = os.lstat(self.path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('account database must be a private regular file')
        db = sqlite3.connect('file:' + quote(self.path, safe='/') + '?mode=rw', uri=True, timeout=5, isolation_level=None)
        try:
            db.execute('PRAGMA foreign_keys = ON')
            yield db
        finally:
            db.close()
    def put_account(self, account, daily_limit):
        if not isinstance(account, str) or not _ACCOUNT.fullmatch(account): raise ValueError('invalid account ID')
        if isinstance(daily_limit, bool) or not isinstance(daily_limit, int) or not 1 <= daily_limit <= 100000: raise ValueError('invalid limit')
        with self._connection() as db:
            db.execute('INSERT INTO accounts(account_id,daily_limit) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET daily_limit=excluded.daily_limit', (account,daily_limit))
    def add_session(self, account, token_hash, expires_at):
        if not isinstance(account,str) or not _ACCOUNT.fullmatch(account) or not isinstance(token_hash,str) or not _HASH.fullmatch(token_hash): raise ValueError('invalid session')
        if not isinstance(expires_at,(int,float)) or not self.clock() < expires_at <= self.clock() + 90 * 86400: raise ValueError('invalid expiry')
        with self._connection() as db:
            db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)', (token_hash,account,expires_at))
    def put_speech_limit(self, account, daily_seconds):
        if not isinstance(account,str) or not _ACCOUNT.fullmatch(account): raise ValueError('invalid account ID')
        if isinstance(daily_seconds,bool) or not isinstance(daily_seconds,int) or not 1 <= daily_seconds <= 86400: raise ValueError('invalid speech limit')
        with self._connection() as db:
            db.execute('INSERT INTO speech_limits(account_id,daily_seconds) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET daily_seconds=excluded.daily_seconds',(account,daily_seconds))
    def put_global_limits(self, daily_requests, daily_speech_seconds):
        if any(isinstance(v,bool) or not isinstance(v,int) or not 1 <= v <= 100_000_000 for v in (daily_requests,daily_speech_seconds)):
            raise ValueError('invalid global limits')
        with self._connection() as db:
            db.execute('INSERT INTO global_limits(singleton,daily_requests,daily_speech_seconds) VALUES(1,?,?) ON CONFLICT(singleton) DO UPDATE SET daily_requests=excluded.daily_requests,daily_speech_seconds=excluded.daily_speech_seconds',(daily_requests,daily_speech_seconds))
    def revoke(self, token_hash):
        if not isinstance(token_hash,str) or not _HASH.fullmatch(token_hash): raise ValueError('invalid token hash')
        with self._connection() as db:
            return db.execute('UPDATE sessions SET revoked=1 WHERE token_hash=? AND revoked=0',(token_hash,)).rowcount == 1
    def authenticate(self, token_hash):
        if not isinstance(token_hash,str) or not _HASH.fullmatch(token_hash): return None
        with self._connection() as db:
            result = db.execute('SELECT account_id FROM sessions WHERE token_hash=? AND revoked=0 AND expires_at>?',(token_hash,self.clock())).fetchone()
        return AccountSession(result[0],token_hash) if result else None
    def consume(self, session):
        if not isinstance(session,AccountSession): return False
        now = self.clock()
        day = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date().isoformat()
        with self._connection() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                account = db.execute('SELECT a.daily_limit FROM accounts a JOIN sessions s ON s.account_id=a.account_id WHERE s.account_id=? AND s.token_hash=? AND s.revoked=0 AND s.expires_at>?',(session.account,session.token_hash,now)).fetchone()
                if not account:
                    db.execute('ROLLBACK'); return False
                count = db.execute('SELECT requests FROM daily_usage WHERE account_id=? AND day=?',(session.account,day)).fetchone()
                global_limit = db.execute('SELECT daily_requests FROM global_limits WHERE singleton=1').fetchone()
                global_used = db.execute('SELECT requests FROM global_usage WHERE day=?',(day,)).fetchone()
                if not global_limit or (global_used and global_used[0] >= global_limit[0]) or (count and count[0] >= account[0]):
                    db.execute('ROLLBACK'); return False
                db.execute('INSERT INTO daily_usage(account_id,day,requests) VALUES(?,?,1) ON CONFLICT(account_id,day) DO UPDATE SET requests=requests+1',(session.account,day))
                db.execute('INSERT INTO global_usage(day,requests,speech_seconds) VALUES(?,1,0) ON CONFLICT(day) DO UPDATE SET requests=requests+1',(day,))
                db.execute('COMMIT'); return True
            except BaseException:
                if db.in_transaction: db.execute('ROLLBACK')
                raise
    def consume_speech(self, session, seconds):
        """Atomically reserve input-audio seconds, never money or output tokens."""
        if not isinstance(session,AccountSession) or isinstance(seconds,bool) or not isinstance(seconds,int) or not 1 <= seconds <= 2: return False
        now = self.clock()
        day = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date().isoformat()
        with self._connection() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT l.daily_seconds FROM speech_limits l JOIN sessions s ON s.account_id=l.account_id WHERE s.account_id=? AND s.token_hash=? AND s.revoked=0 AND s.expires_at>?',(session.account,session.token_hash,now)).fetchone()
                used = db.execute('SELECT seconds FROM speech_usage WHERE account_id=? AND day=?',(session.account,day)).fetchone()
                global_limit = db.execute('SELECT daily_speech_seconds FROM global_limits WHERE singleton=1').fetchone()
                global_used = db.execute('SELECT speech_seconds FROM global_usage WHERE day=?',(day,)).fetchone()
                if not row or not global_limit or (global_used[0] if global_used else 0) + seconds > global_limit[0] or (used[0] if used else 0) + seconds > row[0]:
                    db.execute('ROLLBACK'); return False
                db.execute('INSERT INTO speech_usage(account_id,day,seconds) VALUES(?,?,?) ON CONFLICT(account_id,day) DO UPDATE SET seconds=seconds+excluded.seconds',(session.account,day,seconds))
                db.execute('INSERT INTO global_usage(day,requests,speech_seconds) VALUES(?,0,?) ON CONFLICT(day) DO UPDATE SET speech_seconds=speech_seconds+excluded.speech_seconds',(day,seconds))
                db.execute('COMMIT'); return True
            except BaseException:
                if db.in_transaction: db.execute('ROLLBACK')
                raise
