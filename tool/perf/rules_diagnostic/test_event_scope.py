import unittest
from event_scope import scope_for_event

class ScopeTests(unittest.TestCase):
    def decide(self, action='synchronize', paths=(), before='a'*40, check=lambda _: True):
        event = {'action': action, 'before': before, 'pull_request': {'head': {'sha': 'b'*40}, 'base': {'sha': 'c'*40}}}
        seen=[]
        result=scope_for_event('pull_request',event,None,check,lambda a,b: seen.append((a,b)) or paths)
        return result,seen
    def test_actual_push_not_cumulative_base(self):
        result,seen=self.decide(paths=['lib/main.dart'])
        self.assertFalse(result['run'])
        self.assertEqual(seen,[('a'*40,'b'*40)])
    def test_changed_diagnostic(self):
        self.assertTrue(self.decide(paths=['tool/perf/rules_diagnostic/event_scope.py'])[0]['run'])
    def test_opened_uses_base(self):
        self.assertEqual(self.decide(action='opened')[1],[('c'*40,'b'*40)])
    def test_missing_or_unresolved_before_fails(self):
        for before in (None, '', 'abc'):
            with self.assertRaises(ValueError): self.decide(before=before)
        with self.assertRaises(ValueError): self.decide(check=lambda _: False)
    def test_dispatch_exact_identity(self):
        self.assertTrue(scope_for_event('workflow_dispatch',{},'b'*40,lambda _: True,lambda a,b: self.fail())['run'])
        with self.assertRaises(ValueError): scope_for_event('workflow_dispatch',{},None,lambda _: True,lambda a,b: [])

if __name__ == '__main__': unittest.main()
