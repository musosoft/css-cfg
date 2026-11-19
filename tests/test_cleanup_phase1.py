"""Contracts for autoloaded compact cleanup candidates."""
from pathlib import Path
import unittest

APP = (Path(__file__).resolve().parents[1] / "LamaTeam.App.ps1").read_text()


class CleanupLauncherContracts(unittest.TestCase):
    def test_all_candidate_kinds_render_together_as_compact_checkbox_rows(self):
        self.assertIn("$script:LTUi.CleanupRows = [StackPanel]::new()", APP)
        self.assertIn('$check = Add-LTCheck $script:LTUi.CleanupRows $name', APP)
        self.assertIn("$selected = @($script:LTUi.Candidates | Where-Object", APP)
        self.assertNotIn("$Row.Kind -eq $kind", APP)
        self.assertIn("Get-LamaTeamCleanupCandidates", APP)
        self.assertIn("$basicOptions.Children.Add($script:LTUi.CleanupRows)", APP)
        for heading in ("Running processes", "Running services", "Ready tasks"):
            self.assertNotIn(f"'{heading}'", APP)
        self.assertNotIn("CleanupCount", APP)

    def test_selection_is_saved_and_refreshed_before_mutation(self):
        self.assertIn("Save-LTPreferences", APP)
        self.assertIn("Invalidate-LTCleanupCandidates", APP)
        self.assertIn("$candidate.Check.IsEnabled = $false", APP)
        self.assertIn("$script:LTUi.CleanupNeedsScan = $true", APP)
        self.assertNotIn("Refresh' 'ScanCleanup", APP)
        self.assertIn("Invoke-LTAction 'ScanCleanup'", APP)
        self.assertIn("$script:LTUi.Preferences.Cleanup", APP)

    def test_restore_is_still_available_without_history_page(self):
        self.assertIn("Get-LamaTeamCleanupRecovery", APP)
        self.assertIn("Restore-LamaTeamCleanup", APP)
        self.assertIn("Add-LTAction $recoveryRow 'Restore' 'Restore'", APP)
        self.assertNotIn("New-LTPage 'History'", APP)


if __name__ == "__main__":
    unittest.main()
