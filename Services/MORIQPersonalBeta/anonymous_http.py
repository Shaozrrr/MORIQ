"""Isolated anonymous issuance endpoint with mandatory persistent admission.

Not connected to production. Trusted proxy addresses must be configured by the
deployment and must overwrite the forwarded address with a single client IP.
"""
import asyncio
import ipaddress
import sqlite3
from aiohttp import web
from activation_http import FairWindowLimit
from device_invites import digest


def register(app, activation, limiter, *, trusted_proxies=(), trusted_header='X-Forwarded-For'):
 if not isinstance(limiter, FairWindowLimit) or limiter.store is not activation.store:
  raise ValueError('persistent admission required')
 trusted = {str(ipaddress.ip_address(value)) for value in trusted_proxies}
 if trusted_header not in ('X-Forwarded-For','X-Real-IP'): raise ValueError('invalid trusted header')
 async def handle(request):
  headers={'Cache-Control':'no-store'}
  try:
   peer=str(ipaddress.ip_address(request.remote))
   if peer in trusted:
    values=request.headers.getall(trusted_header,[])
    if len(values)!=1: raise ValueError()
    forwarded=values[0]
    if ',' in forwarded: raise ValueError()
    peer=str(ipaddress.ip_address(forwarded))
   try:
    if request.content_type != 'application/json': raise ValueError()
    body=await request.json()
    if not isinstance(body,dict) or set(body) != {'device','access'} or not all(isinstance(body[k],str) and len(body[k])<=256 for k in body): raise ValueError()
   except (ValueError,TypeError,web.HTTPRequestEntityTooLarge): body=None
   credential=body['device'] if body is not None else 'invalid'
   if not await asyncio.to_thread(limiter.admit,peer,credential):
    return web.json_response({'ok':False},status=429,headers={**headers,'Retry-After':str(limiter.seconds)})
   if body is None: raise ValueError()
   result=await asyncio.to_thread(activation.activate,body['device'],body['access'])
   if result:
    with activation.store._connection() as db:
     row=db.execute('SELECT expires_at FROM sessions WHERE token_hash=? AND revoked=0',(digest(body['access']),)).fetchone()
    remaining=int(row[0]-activation.store.clock()) if row else 0
    if remaining>0:return web.json_response({'ok':True,'expires_in':remaining},headers=headers)
  except sqlite3.Error:return web.json_response({'ok':False},status=503,headers=headers)
  except (ValueError,TypeError,web.HTTPRequestEntityTooLarge):pass
  return web.json_response({'ok':False},status=400,headers=headers)
 app.router.add_post('/v1/devices/anonymous',handle)
 return app

def make_app(activation, limiter, *, trusted_proxies=(), trusted_header='X-Forwarded-For'):
 return register(web.Application(client_max_size=2048), activation, limiter, trusted_proxies=trusted_proxies, trusted_header=trusted_header)
