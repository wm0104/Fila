"""Copy merge uses existing confirmation and reports possibly partial cancellation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'Fila/Interface/FileActions/FileDelivery.swift').read_text()
NATIVE = SOURCE.split('private static func native(', 1)[1].split('private static func transfer(', 1)[0]
MERGE = 'Files with the same names will be replaced; this cannot be undone. Folders with the same names are merged, and what they already hold is kept.'
REPLACE = 'Items with the same names will be replaced, not moved to the trash. This cannot be undone. Non-empty folders cannot be replaced.'


class CopyDeliveryTests(unittest.TestCase):
    def test_only_copy_uses_existing_merge_confirmation(self):
        question = NATIVE.split('guard await confirmReplacement(', 1)[1].split('from: presenter,', 1)[0]
        self.assertIn('request.kind == .copy', question)
        self.assertIn('? String.LocalizationValue("' + MERGE + '")', question)
        self.assertIn(': String.LocalizationValue("' + REPLACE + '")', question)
        self.assertEqual(SOURCE.count('CardQuestion.ask('), 1)
        self.assertEqual(SOURCE.count('AlertViewController('), 1)
        self.assertEqual(SOURCE.count('FeedbackAlert.show('), 2)

    def test_replace_runs_only_after_confirmation(self):
        self.assertIn('if outcome.systemError == EEXIST, !request.overwrite', NATIVE)
        self.assertIn(') else { return false }', NATIVE)
        approved = NATIVE.index('replacement.overwrite = true')
        self.assertLess(NATIVE.index('guard await confirmReplacement('), approved)
        self.assertLess(approved, NATIVE.index('center.awaitJob(replacement'))

    def test_approved_merge_failure_or_cancel_reports_possible_partial_completion(self):
        self.assertIn('var merging = request.kind == .copy && request.overwrite', NATIVE)
        self.assertIn('merging = replacement.kind == .copy', NATIVE)
        self.assertIn('if outcome.code != .cancelled || merging', NATIVE)
        self.assertIn('batch: request.sources.count > 1 || merging', NATIVE)
        self.assertIn('Some items may already have been transferred.', SOURCE)
        self.assertIn('guard outcome.code != .success else { return true }', NATIVE)


if __name__ == '__main__':
    unittest.main()
