from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
OPS = ROOT / 'Packages/FilaKit/Sources/FilaFileOps/Jobs'


class CopyDiagnosticWiringTests(unittest.TestCase):
    def test_file_job_passes_the_existing_note_callback_to_the_tally(self):
        source = (OPS / 'FileJob.swift').read_text()
        run = source.split('public func run(', 1)[1].split('// MARK: - The work', 1)[0]
        self.assertIn('JobTally(job: self, report: report, note: note)', run)
        self.assertIn('note: @escaping (String) -> Void = { _ in }', run)
        self.assertNotIn('import FilaLog', source)

    def test_callback_captures_errno_before_any_work_and_still_quits(self):
        source = (OPS / 'JobTally.swift').read_text()
        callback = source.split('let filaCopyProgress:', 1)[1].split('if stage == COPYFILE_START', 1)[0]
        self.assertLess(callback.index('let callbackErrno = Darwin.errno'), callback.index('guard let context'))
        self.assertIn('code: callbackErrno', callback)
        self.assertIn('phase: "callback what=', callback)
        self.assertIn('Darwin.errno = callbackErrno\n        return COPYFILE_QUIT', callback)
        self.assertIn('if tally.job.isCancelled {\n        return COPYFILE_QUIT', callback)

    def test_first_error_is_saved_before_diagnostics_and_log_preserves_errno(self):
        source = (OPS / 'JobTally.swift').read_text()
        failure = source.split('func recordCopyFailure(', 1)[1].split('func recordFailure(_ failure:', 1)[0]
        self.assertLess(failure.index('guard failure == nil'), failure.index('failure = FilaFailure'))
        self.assertLess(failure.index('failure = FilaFailure'), failure.index('noteCopyFailure(source:'))
        self.assertIn('defer { Darwin.errno = saved }', failure)
        self.assertIn('unicodeScalars.prefix(1024)', failure)
        self.assertNotIn('import FilaLog', source)

    def test_existing_app_and_daemon_note_sinks_are_retained(self):
        for path in ['Packages/FilaKit/Sources/FilaClient/LocalFileService.swift', 'Filad/Server/DaemonServer.swift']:
            source = (ROOT / path).read_text()
            self.assertIn('note: {', source)
            self.assertIn('FilaLog.', source)
        tests = (ROOT / 'Packages/FilaKit/Tests/FilaFileOpsTests/CopyFailureDiagnosticsTests.swift').read_text()
        self.assertEqual(tests.count('    @Test\n'), 7)
        self.assertIn('filaCopyProgress(', tests)
        self.assertIn('FileJob(request:', tests)


if __name__ == '__main__':
    unittest.main()
