"""Validate benchmark interval attribution and interrupted-run rejection."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('library_benchmark', Path(__file__).with_name('bench-library.py'))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkReportTests(unittest.TestCase):
    def test_backend_times_belong_to_active_interval(self):
        phases = benchmark.parse_phases('''kiln-cg: machine code in 9s
BENCH-BEGIN file
kiln-cg: machine code in 200µs
kiln compiler: 100 bytes in 1ms
kiln-cg: machine code in 300µs
kiln compiler: structured program in 2ms
BENCH-END file 10000 9000 1000000
BENCH-METRIC file MIR 5000 4000 3000 2000 2 1000000
BENCH-BEGIN cached-function
BENCH-END cached-function 1000 800 1000000
BENCH-COMPLETE
''')
        self.assertEqual(phases['file']['backend_calls'], 2)
        self.assertAlmostEqual(phases['file']['machine_seconds'], .0005)
        self.assertAlmostEqual(phases['file']['backend_seconds'], .003)
        self.assertEqual(phases['file']['compilation_phases']['MIR']['self_cpu_seconds'], .002)
        self.assertEqual(phases['cached-function']['backend_calls'], 0)
        self.assertEqual(phases['file']['wall_seconds'], .01)

    def test_incomplete_and_overlapping_intervals_are_rejected(self):
        for text in ('BENCH-BEGIN file\nBENCH-COMPLETE',
                     'BENCH-BEGIN first\nBENCH-BEGIN second\nBENCH-END second 1 1 1\nBENCH-COMPLETE',
                     'BENCH-BEGIN file\nBENCH-END other 1 1 1\nBENCH-COMPLETE',
                     'BENCH-BEGIN file\nBENCH-END file 1 1 1'):
            with self.assertRaises(ValueError):
                benchmark.parse_phases(text)


if __name__ == '__main__':
    unittest.main()
