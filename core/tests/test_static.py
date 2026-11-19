"""Built-in-only safety checks; supplements, does not replace, PowerShell execution."""
from pathlib import Path
import re
import hashlib
import subprocess
import unittest

CORE = Path(__file__).resolve().parents[1]
SOURCE = (CORE / "CssCfg.Core.psm1").read_text()
PROCESS = (CORE / "CssCfg.Process.ps1").read_text()
FACADE = (CORE / "LamaTeam.Api.ps1").read_text()
NETWORK = (CORE / "CssCfg.Network.ps1").read_text()
CLEANUP = (CORE / "CssCfg.Cleanup.ps1").read_text()
MEDIA = (CORE / "CssCfg.Media.ps1").read_text()
ALL_SOURCE = "\n".join(p.read_text() for p in sorted(CORE.iterdir()) if p.suffix in (".ps1", ".psm1"))


class CoreSafetyTests(unittest.TestCase):
    def test_no_forbidden_system_actions(self):
        forbidden = (
            r"\bStop-Process\b", r"\btaskkill\b", r"\bpowercfg\b", r"\breg\.exe\b",
            r"\bSet-Service\b", r"\bSet-ItemProperty\b", r"\bRemove-ItemProperty\b",
            r"\bStop-ScheduledTask\b", r"\bUnregister-ScheduledTask\b",
            r"\.Kill\s*\(", r"\bTerminateProcess\b", r"\bRestart-Process\b",
        )
        for pattern in forbidden:
            self.assertIsNone(re.search(pattern, ALL_SOURCE, re.I), pattern)

    def test_only_required_https_origin(self):
        urls = re.findall(r"https?://[^'\s]+", ALL_SOURCE)
        self.assertTrue(urls)
        approved = {
            "https://fastdl.lamateam.eu/", "https://fastdl.lamateam.eu/maps/",
            "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://docs.google.com/spreadsheets/d/e/2PACX-1vTufS4N6N-30qHu47IuYFnR8CqjM9iTTWQLQ9d4w0SxpmdI984EcnbG8D4ZAerbtKzuxtTHAlHrZpHQ/pub?output=csv",
        }
        self.assertTrue(set(urls) <= approved)
        self.assertIn("$handler.AllowAutoRedirect = $false", NETWORK)
        self.assertIn("$code -ne 200", NETWORK)
        self.assertIn("$total -gt $MaxBytes", NETWORK)

    def test_video_conversion_preserves_decoded_frames_and_uses_vorbis(self):
        self.assertIn("-fps_mode passthrough", MEDIA)
        self.assertIn("-pix_fmt yuv420p", MEDIA)
        self.assertIn("-c:v libvpx-vp9 -lossless 1 -b:v 0 -crf 0", MEDIA)
        self.assertIn("-c:a libvorbis -q:a 10 -ar 44100 -ac 2", MEDIA)
        self.assertNotIn("libopus", MEDIA)
        self.assertIn("binkvideo", MEDIA)
        self.assertIn("libvorbis", MEDIA)

    def test_explicit_profiles_and_selection(self):
        self.assertIn("[ValidateSet('Modern','Legacy')]", SOURCE)
        self.assertIn("HistoricalAssetIntegrity", SOURCE)
        self.assertIn("ReviewRequired: preview the entire historical preset", SOURCE)
        self.assertIn("[string[]]$SelectedKeys = @()", FACADE)
        self.assertIn("[string[]]$SelectedKeys = @()", CLEANUP)
        self.assertIn("if (-not $Restore -and $SelectedKeys.Count -eq 0) { return }", CLEANUP)
        self.assertIn("Selected = $false", FACADE)
        self.assertIn("[switch]$OptIn", MEDIA)

    def test_manifest_exports_defined_functions(self):
        manifest = (CORE / "CssCfg.Core.psd1").read_text()
        exports = re.findall(r"'([A-Za-z]+-(?:Css|LamaTeam)[A-Za-z]+)'", manifest)
        functions = set(re.findall(r"^function ([\w-]+)", ALL_SOURCE, re.M))
        self.assertEqual(len(exports), 31)
        self.assertEqual(len(exports), len(set(exports)), "Duplicate manifest exports")
        self.assertFalse(set(exports) - functions, f"Undefined exports: {set(exports) - functions}")
        for name in re.findall(r"Join-Path \$PSScriptRoot '([^']+\.ps1)'", SOURCE):
            self.assertTrue((CORE / name).is_file(), f"Missing dot-source: {name}")

    def test_powershell_tests_are_isolated(self):
        tests = (CORE / "tests/Invoke-CoreTests.ps1").read_text()
        self.assertIn("-Adapter $adapter", tests)
        self.assertIn("-Downloader $downloader", tests)
        self.assertNotRegex(tests, r"(?im)^\s*(Stop-Service|Start-Service|Disable-ScheduledTask|Enable-ScheduledTask)\b")

    def test_process_close_is_graceful_and_not_restorable(self):
        self.assertEqual(PROCESS.count("$process.CloseMainWindow()"), 1)
        self.assertIn("Restorable = $false", PROCESS)
        self.assertIn("RestoreStatus = 'NOT RESTORABLE'", PROCESS)
        self.assertIn("[switch]$AcknowledgeNotRestorable", PROCESS)
        self.assertLess(PROCESS.index("Write-Warning $warningText"), PROCESS.index("& $Adapter.Close"))
        self.assertIn("$current.StartTimeUtcTicks -ne $Item.StartTimeUtcTicks", PROCESS)
        self.assertIn("-not $current.Path.Equals($Item.Path", PROCESS)
        self.assertNotIn("Save-CssState", PROCESS)
        self.assertNotIn("Start-Process", PROCESS)
        self.assertNotIn("Invoke-CssCleanup", PROCESS)

    def test_process_tests_use_only_fake_actions(self):
        tests = (CORE / "tests/Invoke-ProcessTests.ps1").read_text()
        calls = [line for line in tests.splitlines() if re.search(r"(?:Get-CssProcessInspection|Invoke-CssProcessClose)\s+-", line)]
        self.assertGreater(len(calls), 10)
        self.assertTrue(all("-Adapter $adapter" in line for line in calls))
        self.assertNotIn("CloseMainWindow()", tests)

    def test_legacy_asset_is_verbatim_audited_data(self):
        asset = (CORE / "assets/Legacy-2016/autoexec.cfg").read_bytes()
        self.assertEqual(hashlib.sha256(asset).hexdigest(), "a846b241f7ccfc26fdbaf805f015ba96102cbc316c120f4cb74d4f80da7a2aa1")
        historical = subprocess.check_output(["git", "show", "22604b7:autoexec.cfg"], cwd=CORE)
        self.assertEqual(asset, historical)
        self.assertFalse(asset.endswith(b"\n"))
        self.assertEqual(len(list((CORE / "assets").rglob("*.cfg"))), 1)

    def test_public_facade_remains_ui_independent(self):
        self.assertNotIn("WinUIShell", FACADE)
        self.assertNotIn("Activate()", FACADE)
        self.assertIn("[string]$FastDlDirectory = 'maps'", FACADE)
        self.assertIn("[ValidateSet('Modern','Legacy')]", FACADE)
        self.assertIn("ReviewSha256 = $plan.ReviewSha256", FACADE)
        self.assertIn("Text = $text -join", FACADE)
        self.assertIn("param($Game, $Paths", FACADE)
        self.assertIn("[Alias('RecoveryPath')]", FACADE)

    def test_maps_and_video_use_validated_atomic_install(self):
        self.assertIn(".bsp.bz2", SOURCE)
        self.assertIn("'-so'", NETWORK)
        self.assertIn("$info.RedirectStandardOutput = $true", NETWORK)
        self.assertIn("Test-CssBsp $bsp", NETWORK)
        self.assertIn("[IO.File]::Move($bsp, $target", NETWORK)
        self.assertIn("-xerror", MEDIA)
        self.assertIn("-f webm -i $temp", MEDIA)
        self.assertIn("[switch]$BackupExisting", MEDIA)

    def test_cleanup_requires_original_and_current_state(self):
        self.assertIn("Save-CssState $JournalPath $journal # Write-ahead intent", CLEANUP)
        self.assertIn("$originallyEligible", CLEANUP)
        self.assertIn("$stillChanged", CLEANUP)
        self.assertIn("RestoreConflict", CLEANUP)
        self.assertIn("$entry.Status = 'RestoreFailed'", CLEANUP)
        self.assertIn("$journal.Version -ne 2", CLEANUP)

    def test_cleanup_reporting_contract(self):
        self.assertIn("Items=$rows.ToArray(); Subsystems=$subsystems.ToArray()", FACADE)
        self.assertIn("function Get-LamaTeamCleanupRecovery", FACADE)
        recovery = FACADE.split("function Get-LamaTeamCleanupRecovery", 1)[1].split("function Convert-LamaTeamIntroVideo", 1)[0]
        for action in ("Save-CssState ", "CreateDirectory(", "Get-CssCleanupAdapter", "Resolve-LamaTeamRoot"):
            self.assertNotIn(action, recovery)
        self.assertLess(CLEANUP.index("throw 'Unresolved cleanup journal"), CLEANUP.index("& $Adapter.Change"))
        self.assertIn("-OutcomeBuffer $results", FACADE)
        self.assertNotIn("if ($failed) { throw", FACADE)


if __name__ == "__main__":
    unittest.main()
