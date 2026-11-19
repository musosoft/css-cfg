"""Contracts for the compact, single-window launcher surface."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "LamaTeam.App.ps1").read_text()
PROCESS = (ROOT / "core/CssCfg.Process.ps1").read_text()
CLEANUP = (ROOT / "core/CssCfg.Cleanup.ps1").read_text()


class LauncherUiContracts(unittest.TestCase):
    def test_single_window_has_no_sidebar_history_about_or_manual_path_form(self):
        self.assertNotIn("[NavigationView]::new()", APP)
        self.assertNotIn("New-LTPage 'History'", APP)
        self.assertNotIn("New-LTPage 'About'", APP)
        self.assertNotIn("Enter folder manually", APP)
        self.assertIn("$win.Title = 'CS:S Launcher'", APP)
        self.assertIn("$script:LTUi.Root = $root", APP)
        self.assertNotIn("'Browse…' 'Browse'", APP)
        self.assertNotIn("'Review' 'PreviewConfig'", APP)
        self.assertNotIn("'Check now' 'Integrity'", APP)
        self.assertNotIn("'Refresh' 'ScanCleanup'", APP)

    def test_discovery_is_automatic_but_only_fresh_eligible_rows_are_selectable(self):
        detect = APP.split("'Detect' {", 1)[1].split("{ $_ -in @('PreviewConfig'", 1)[0]
        self.assertIn("Get-LamaTeamCleanupCandidates", detect)
        self.assertIn("Show-LTCleanupRows", detect)
        self.assertIn("$check.IsEnabled = ($row.Eligible -eq $true", APP)
        self.assertIn("Get-LTCandidatePreferenceKey", APP)
        self.assertIn("$script:LTUi.Preferences.Cleanup", APP)
        for label in ("Running processes", "Running services", "Ready tasks"):
            self.assertNotIn(f"'{label}'", APP)
        self.assertNotIn("'CS:S detected · ready'", APP)
        self.assertNotIn("New-LTText 'Ready'", APP)
        self.assertIn("CloseMainWindow", PROCESS)
        self.assertNotRegex(PROCESS, re.compile(r"\bStop-Process\b|taskkill", re.I))
        self.assertIn("Stop-Service", CLEANUP)
        self.assertIn("Disable-ScheduledTask", CLEANUP)

    def test_preferences_are_persisted_outside_game_files(self):
        self.assertIn("launcher-preferences.json", APP)
        self.assertIn("Save-CssState -Path $script:LTUi.PreferencePath", APP)
        for field in ("GamePath", "ProfileIndex", "UseConfig", "Connect", "VideoOptIn", "AutoMaps", "Tweaks", "ValidateIntegrity", "StartupOptions", "Cleanup"):
            self.assertRegex(APP, rf"(?m)^\s*{field}\s*=")
        self.assertNotIn("TweakEnabled", APP)
        self.assertIn("steam://validate/240", APP)
        self.assertIn("Set-CssSteamLaunchOptions", APP)
        self.assertIn("Get-CssSteamLaunchOptions", APP)
        self.assertIn("UseLamaStartupOptions", APP)
        self.assertIn("MonitorMaxRefreshRate", APP)
        self.assertIn("Get-LTCandidatePreferenceKey", APP)
        self.assertIn("@('Process', $Row.Name, $Row.Path)", APP)
        self.assertIn("@($Row.Kind, $Row.TaskPath, $Row.Name, $Row.Path)", APP)

    def test_apply_play_runs_selected_work_then_steam_with_one_confirmation(self):
        play = APP.split("'Play' {", 1)[1].split("'Detect' {", 1)[0]
        self.assertIn("Confirm-LTAction 'Apply and play?'", play)
        self.assertIn("Set-LamaTeamPlayerConfig", play)
        self.assertIn("Add-LamaTeamConnect", play)
        self.assertIn("Apply-LamaTeamCleanup", play)
        self.assertIn("Convert-LamaTeamIntroVideo", play)
        self.assertIn("Sync-LamaTeamMaps", play)
        self.assertIn("Start-Process 'steam://connect/82.208.17.101:27516'", play)
        self.assertLess(play.index("Sync-LamaTeamMaps"), play.index("steam://connect/82.208.17.101:27516"))
        self.assertIn("AcknowledgeNotRestorable", play)
        self.assertIn("$result.Status -notin @('Succeeded', 'NoOp')", play)

    def test_preserved_features_share_the_window_and_keep_write_safety(self):
        start = APP.split("function Start-LamaTeamApp {", 1)[1]
        for text in ("Fix Intro video", "Add LamaTeam connect to menu", "LamaTeam Modern PC", "Rivals.cz Legacy PC", "Automatically download $count missing maps", "Validate game integrity", "Current Steam launch options", "Restore"):
            self.assertIn(text, start + APP)
        self.assertIn("$formScroll.Content = $content", start)
        self.assertIn("$script:LTUi.ConfigEditor = [RichEditBox]::new()", start)
        self.assertIn("Set-LTConfigSyntaxHighlight", APP)
        self.assertIn("Invoke-LTConfigHistory", APP)
        self.assertIn("Save-LamaTeamConfigText", APP)
        self.assertIn("ConfigBackupCreated", APP)
        self.assertNotIn("$rightContent", start)
        self.assertIn("BackupExisting = $true; BackupPath = $backup", APP)
        self.assertIn("$dialog.DefaultButton = 'Close'", APP)
        self.assertIn("[Grid]::SetRow($footer, 1)", start)
        self.assertNotIn("$nav = [NavigationView]::new()", start)

    def test_preview_is_config_only_and_obsolete_weapon_tweaks_are_gone(self):
        self.assertIn("$text = @($plan.Files | ForEach-Object Content) -join", (ROOT / "core/LamaTeam.Api.ps1").read_text())
        self.assertNotIn("Modern PC`n", APP)
        self.assertNotIn("Files:", APP)
        self.assertNotIn("SHA-256:", APP)
        self.assertNotIn("hud_fastswitch", APP)
        self.assertNotIn("cl_autowepswitch_off", APP)


if __name__ == "__main__":
    unittest.main()
