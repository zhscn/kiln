"""Check Maxima reports retain named failures and distinguish empty runs."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('maxima_runner', Path(__file__).with_name('test-maxima.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class MaximaReportTests(unittest.TestCase):
    def test_wrapped_failures_and_thousands(self):
        report = runner.test_summary('''Error summary:
  /corpus/tests/rtest2.mac problems:
    (52 310
     311 312)
  /corpus/tests/rtest_elliptic.mac problem:
    (358)
5 tests failed out of 17,205 total tests.
''')
        self.assertEqual(report['failures'], {'rtest2.mac': [52, 310, 311, 312],
                                               'rtest_elliptic.mac': [358]})
        self.assertEqual(report['failed_totals'], [{'failed': 5, 'total': 17205}])
        self.assertEqual(report['tests_without_unexpected_errors'], [])

    def test_separate_success_and_failure_summaries(self):
        report = runner.test_summary('''No unexpected errors found out of 17,205 tests.
1 test failed out of 435 total tests.
''')
        self.assertEqual(report['tests_without_unexpected_errors'], [17205])
        self.assertEqual(report['failed_totals'], [{'failed': 1, 'total': 435}])

    def test_verbose_problem_headings_are_not_failures(self):
        report = runner.test_summary('''rtest1.mac: Problem 52
... Which was correct.
No unexpected errors found out of 192 tests.
''')
        self.assertEqual(report['failures'], {})
        self.assertEqual(report['failed_totals'], [])
        self.assertEqual(runner.test_summary('No tests to run')['tests_without_unexpected_errors'], [])


if __name__ == '__main__':
    unittest.main()
