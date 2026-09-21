#!/usr/bin/env python3
"""隔離驗證模型交易與特徵契約，不寫入使用者的模型或偏好。"""
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import install_ranker_model as installer
from ranker_feature_contract import (
    BOUNDED, LEGACY, METADATA_KEY, dataset_contract, require_checkpoint_contract,
    stamp_coreml_contract,
)


class ModelInstallSmoke(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="unifyime-install-smoke-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.source = self.root / "source.mlmodelc"
        self.target = self.root / "CandidateRanker.mlmodelc"
        self.backup = self.target.with_suffix(".mlmodelc.bak")
        for path, content in [(self.source, "new"), (self.target, "active"), (self.backup, "previous")]:
            path.mkdir()
            (path / "model").write_text(content)

    def assert_preserved(self):
        self.assertEqual((self.target / "model").read_text(), "active")
        self.assertEqual((self.backup / "model").read_text(), "previous")

    def test_missing_source_retries_preserve_models(self):
        for _ in range(2):
            with self.assertRaises(ValueError):
                installer.install_model(self.root / "missing.mlmodelc", self.target)
            self.assert_preserved()
        with self.assertRaises(FileNotFoundError):
            installer.hash_tree(self.root / "missing.mlmodelc")

    def test_copy_and_validation_failures_preserve_models(self):
        for function in ["copytree", "validate_compiled_model"]:
            owner = installer.shutil if function == "copytree" else installer
            with patch.object(owner, function, side_effect=OSError("injected failure")):
                for _ in range(2):
                    with self.assertRaises(OSError):
                        installer.install_model(self.source, self.target)
                    self.assert_preserved()

    def test_switch_and_backup_failures_roll_back(self):
        swap = installer.swap_paths
        for failing_destination in [self.target, self.backup]:
            def fail_once(first, second):
                if second == failing_destination:
                    raise OSError("injected swap failure")
                return swap(first, second)
            with patch.object(installer, "validate_compiled_model"), patch.object(installer, "swap_paths", fail_once):
                with self.assertRaises(OSError):
                    installer.install_model(self.source, self.target)
            self.assert_preserved()

    def test_failed_rollback_keeps_recovery_data(self):
        swap = installer.swap_paths
        calls = 0
        def fail_after_install(first, second):
            nonlocal calls
            calls += 1
            if calls > 1:
                raise OSError("persistent filesystem failure")
            return swap(first, second)
        with patch.object(installer, "validate_compiled_model"), patch.object(installer, "swap_paths", fail_after_install):
            with self.assertRaises(RuntimeError):
                installer.install_model(self.source, self.target)
        self.assertEqual((self.target / "model").read_text(), "new")
        self.assertEqual((self.backup / "model").read_text(), "previous")
        recovery = list(self.root.glob(".*.install-*/new.mlmodelc/model"))
        self.assertEqual([path.read_text() for path in recovery], ["active"])

    def test_success_retains_previous_active_version(self):
        with patch.object(installer, "validate_compiled_model") as validate:
            installer.install_model(self.source, self.target)
        self.assertEqual(validate.call_count, 1)
        self.assertEqual((self.target / "model").read_text(), "new")
        self.assertEqual((self.backup / "model").read_text(), "active")

    def test_install_cannot_copy_source_into_itself(self):
        with self.assertRaises(ValueError):
            installer.install_model(self.source, self.source / "nested.mlmodelc")
        self.assert_preserved()


class FeatureContractSmoke(unittest.TestCase):
    def test_legacy_and_bounded_datasets(self):
        self.assertEqual(dataset_contract([{}], untagged_contract=LEGACY), LEGACY)
        self.assertEqual(dataset_contract([{"feature_contract": BOUNDED}], []), BOUNDED)

    def test_mixed_and_unknown_contracts_fail(self):
        for rows in [[{}], [{"feature_contract": LEGACY}, {"feature_contract": BOUNDED}], [{"feature_contract": "future"}], []]:
            with self.assertRaises(ValueError):
                dataset_contract(rows)

    def test_checkpoint_must_match_dataset(self):
        require_checkpoint_contract({}, LEGACY)
        require_checkpoint_contract({"feature_contract": BOUNDED}, BOUNDED)
        with self.assertRaises(ValueError):
            require_checkpoint_contract({}, BOUNDED)

    def test_export_preserves_weight_contract(self):
        for original, expected in [(SimpleNamespace(), LEGACY), (SimpleNamespace(unifyime_feature_contract=BOUNDED), BOUNDED)]:
            exported = SimpleNamespace(user_defined_metadata={})
            stamp_coreml_contract(exported, original)
            self.assertEqual(exported.user_defined_metadata[METADATA_KEY], expected)


if __name__ == "__main__":
    unittest.main()
