"""Session lifecycle primitive for a future trusted identity service.

This is not a login endpoint. Callers MUST authenticate the person and decide
whether this account may receive a session before calling issue(). The caller
must protect the returned token and never log it. Only its hash is persisted.
"""
import hashlib
import secrets

class SessionIssuer:
    def __init__(self, store):
        self.store = store

    def issue(self, account, ttl_seconds):
        if isinstance(ttl_seconds, bool) or not isinstance(ttl_seconds, int) or not 60 <= ttl_seconds <= 7 * 86400:
            raise ValueError('invalid session duration')
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode('ascii')).hexdigest()
        self.store.add_session(account, digest, self.store.clock() + ttl_seconds)
        return token

    def revoke(self, token):
        if not isinstance(token, str) or not 32 <= len(token) <= 256 or not token.isascii() or not all(33 <= ord(c) <= 126 for c in token):
            return False
        return self.store.revoke(hashlib.sha256(token.encode('ascii')).hexdigest())
