import asyncio
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Services/MORIQPersonalBeta'))
from caption_auto_translation import guard_rule
from deepseek_translation import ControlledDeepSeekProvider


class TranslationInstructionBoundaryTests(unittest.TestCase):
    def test_prompt_separates_source_from_reference(self):
        sent = {}

        class Response:
            status = 200
            def read(self, limit):
                return json.dumps({'choices': [{'finish_reason': 'stop', 'message': {'content': '门开着。'}}]}).encode()

        class Connection:
            def __init__(self, *args, **kwargs): pass
            def request(self, method, path, body, headers): sent.update(json.loads(body))
            def getresponse(self): return Response()
            def close(self): pass

        with patch('deepseek_translation.http.client.HTTPSConnection', Connection):
            result = asyncio.run(ControlledDeepSeekProvider('test-key').translate_with_context(
                'The door is open.', 'zh-Hans', 'A room was mentioned.'))
        self.assertEqual(result, '门开着。')
        user = json.loads(sent['messages'][1]['content'])
        self.assertEqual(user, {'source_text': 'The door is open.', 'context_for_reference': 'A room was mentioned.'})
        self.assertIn('不要翻译或复述', sent['messages'][0]['content'])

    def test_echo_is_rejected_but_legitimate_source_is_preserved(self):
        self.assertEqual(guard_rule('Are you ready?', '前文：旧句。待翻译：准备好了吗？'), 'instruction_echo')
        self.assertEqual(guard_rule('Are you ready?', '{"source_text":"准备好了吗？"}'), 'instruction_echo')
        self.assertIsNone(guard_rule('Are you ready?', '准备好了吗？'))
        self.assertIsNone(guard_rule('待翻译：示例', '待翻译：示例'))


if __name__ == '__main__': unittest.main()
