"""Synthetic native transport into actual sampled parser; no official runtime."""
import unittest
import test_native_wrapper as native
from sampled_contract import parse_sample, estimate_samples
from application_contract import ContractError

class SampleTransportIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls): native.NativeSampleWrapperTests.setUpClass()
    @classmethod
    def tearDownClass(cls): native.NativeSampleWrapperTests.tearDownClass()
    def setUp(self):
        self.transport=native.NativeSampleWrapperTests()
        self.transport.setUp()
    def tearDown(self): self.transport.tearDown()
    def test_complete_stub_raw_parses_with_distinct_estimate_semantics(self):
        self.transport.case()
        sample=parse_sample(self.transport.directory/native.FINAL)
        self.assertEqual(sample['rawSampleHeader'],(1,64,1,64))
        self.assertFalse(sample['fullHeapCoverage'])
        estimate=estimate_samples(sample)
        self.assertTrue(estimate['estimateNotExact'])
        self.assertFalse(estimate['zeroMeansNoLeak'])
    def test_transport_acceptance_does_not_hide_invalid_raw(self):
        result=self.transport.case('nul')
        self.assertEqual(result['accepted'],1) # transport success only
        raw=self.transport.directory/native.FINAL
        self.assertTrue(raw.read_bytes().endswith(b'\0'))
        with self.assertRaises(ContractError):parse_sample(raw)
        self.assertTrue(raw.exists())
