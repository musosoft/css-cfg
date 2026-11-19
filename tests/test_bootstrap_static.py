"""Static safety checks for the public PowerShell setup bootstrap."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "setup.ps1").read_text(encoding="utf-8-sig")
LAUNCHER = (ROOT / "Launch-LamaTeam.ps1").read_text(encoding="utf-8-sig")
APP = (ROOT / "LamaTeam.App.ps1").read_text(encoding="utf-8-sig")


class BootstrapTests(unittest.TestCase):
    def test_requires_power_shell_74_and_gets_consent_before_installer(self):
        self.assertIn("[version]'7.4.0'", SOURCE)
        consent = SOURCE.index("Read-Host 'Type Y to install and continue, or N to cancel'")
        installer = SOURCE.index("Start-Process -FilePath $winget.Source")
        self.assertLess(consent, installer)
        self.assertIn("if ($answer -notmatch '^(?i:y|yes)$')", SOURCE)
        self.assertIn("machine-wide and Windows may request administrator approval (UAC)", SOURCE)

    def test_pins_microsoft_power_shell_package_and_launcher_elevates_app(self):
        self.assertIn("$script:LamaWingetVersion = '7.4.22.0'", SOURCE)
        self.assertIn("'Microsoft.PowerShell', '--exact', '--source', 'winget'", SOURCE)
        self.assertIn("'--version', $script:LamaWingetVersion", SOURCE)
        self.assertIn("The LamaTeam app requests UAC elevation before opening.", SOURCE)
        self.assertIn("function Test-LamaAdministrator", LAUNCHER)
        self.assertIn("function Start-LamaElevated", LAUNCHER)
        self.assertIn("-Verb RunAs", LAUNCHER)
        self.assertIn("if (-not (Test-LamaAdministrator))", LAUNCHER)
        self.assertNotIn("-Verb RunAs", SOURCE)
        self.assertNotIn("#Requires -RunAsAdministrator", SOURCE)

    def test_handoff_uses_commit_pinned_verified_launcher(self):
        self.assertIn("$entry.sha", SOURCE)
        self.assertIn("Launch-LamaTeam.ps1", SOURCE)
        self.assertIn("Get-LamaGitBlobHash $bytes", SOURCE)
        self.assertIn("-File', $Launcher.Path", SOURCE)
        self.assertNotIn("Invoke-WebRequest -Uri 'https://lamateam.eu/setup'", SOURCE)

    def test_app_bypass_is_child_only_for_both_bootstrap_paths(self):
        import re
        self.assertIn("'-ExecutionPolicy', 'Bypass', '-File', $Launcher.Path", SOURCE)
        self.assertEqual(SOURCE.count("Invoke-LamaLauncher -Launcher $launcher -PowerShellExe $pwsh"), 2)
        self.assertNotRegex(SOURCE + LAUNCHER, re.compile(r"(?i)\b(?:Set-ExecutionPolicy|Unblock-File)\b"))
        self.assertNotIn("& $launcher.Path", SOURCE)
        self.assertIn("Get-LamaLauncher -LocalRoot $LocalRoot", SOURCE)
        self.assertIn("Install-LamaPowerShell7 -LocalRoot $localRoot", SOURCE)
        self.assertIn("if ($launcher -and $launcher.Temporary) { Remove-Item", SOURCE)

    def test_winuishell_dependency_is_pinned_and_per_user(self):
        self.assertIn("$script:LamaModuleVersion = '0.14.0'", LAUNCHER)
        self.assertIn("-Scope CurrentUser", LAUNCHER)
        self.assertIn("PowerShell Gallery", LAUNCHER)
        self.assertIn("No fallback framework was used.", LAUNCHER)

    def test_remote_code_is_commit_and_blob_verified(self):
        self.assertIn("https://api.github.com/repos/musosoft/css-cfg", SOURCE + LAUNCHER)
        self.assertIn("https://raw.githubusercontent.com/musosoft/css-cfg", SOURCE + LAUNCHER)
        self.assertIn("Get-LamaGitBlobHash", SOURCE)
        self.assertIn("launcher failed GitHub commit-tree integrity validation", SOURCE)
        self.assertIn("truncated", SOURCE)
        self.assertIn("$_.type -ceq 'blob'", SOURCE)

    def test_ui_does_not_assign_powershell_home_automatic_variable(self):
        import re
        self.assertIsNone(re.search(r"(?im)^\s*\$home\s*=", APP))


if __name__ == "__main__":
    unittest.main()
