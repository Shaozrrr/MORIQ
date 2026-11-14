"""DeepL request adapter for isolated tests. No real HTTP transport is provided.

The injected transport must enforce TLS, disable proxies/redirects, apply a
streaming response size limit before buffering and never log requests. This
module does not make it safe to install an unreviewed transport in production.
"""
import asyncio
import json
import ssl

class DeepLExperimentError(Exception):
    pass

class DeepLExperiment:
    FREE = 'https://api-free.deepl.com/v2/translate'
    PRO = 'https://api.deepl.com/v2/translate'
    TARGETS = {'zh':'ZH-HANS', 'zh-Hans':'ZH-HANS', 'en':'EN-US', 'en-US':'EN-US', 'en-GB':'EN-GB', 'ja':'JA', 'ko':'KO'}
    def __init__(self, key, transport, *, endpoint=FREE, context='', timeout=3, model_type='quality_optimized'):
        if endpoint not in (self.FREE,self.PRO): raise ValueError('invalid DeepL endpoint')
        if not isinstance(key,str) or not key or not key.isascii() or any(not 33<=ord(c)<=126 for c in key): raise ValueError('invalid credential')
        if model_type not in (None,'quality_optimized'): raise ValueError('invalid model configuration')
        if not callable(transport) or not isinstance(context,str) or len(context)>4000 or not 0<timeout<=10: raise ValueError('invalid adapter configuration')
        self.__key=key; self._transport=transport; self._endpoint=endpoint; self._context=context; self._timeout=timeout; self._model_type=model_type

    async def __call__(self, text, target):
        if not isinstance(text,str) or not text.strip() or len(text)>4000 or not isinstance(target,str) or target not in self.TARGETS:
            raise DeepLExperimentError('invalid translation request')
        payload={'text':[text], 'target_lang':self.TARGETS[target]}
        if self._model_type: payload['model_type']=self._model_type
        if self._context: payload['context']=self._context
        try:
            # The transport API has an explicit no-redirect and bounded-body contract.
            status, raw = await asyncio.wait_for(self._transport(
                url=self._endpoint, headers={'Authorization':'DeepL-Auth-Key '+self.__key,'Content-Type':'application/json'},
                body=json.dumps(payload,ensure_ascii=False).encode('utf-8'), timeout=self._timeout,
                allow_redirects=False, max_response_bytes=32768), timeout=self._timeout)
            if type(status) is not int: raise DeepLExperimentError('invalid_response')
            if status != 200:
                category={401:'auth',403:'auth',429:'rate_limit',456:'quota'}.get(status,'http_error')
                raise DeepLExperimentError(category)
            if not isinstance(raw,bytes) or len(raw)>32768: raise DeepLExperimentError('invalid_response')
            data=json.loads(raw)
            translations=data.get('translations') if isinstance(data,dict) else None
            if not isinstance(translations,list) or len(translations)!=1 or not isinstance(translations[0],dict):
                raise DeepLExperimentError('invalid_response')
            translated=translations[0].get('text')
            if not isinstance(translated,str) or not translated.strip() or len(translated)>4000:
                raise DeepLExperimentError('invalid_response')
            return translated
        except asyncio.CancelledError:
            raise
        except DeepLExperimentError:
            raise
        except (asyncio.TimeoutError,TimeoutError):
            raise DeepLExperimentError('timeout') from None
        except ssl.SSLError:
            raise DeepLExperimentError('tls') from None
        except (ConnectionError,OSError):
            raise DeepLExperimentError('network') from None
        except Exception:
            # No provider error bodies, source text, exception details or keys.
            raise DeepLExperimentError('invalid_response') from None
