#!/usr/bin/env python3
import argparse
import ctypes
import fcntl
import os
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TARGET = Path.home() / "Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc"
DEFAULT_COMPILE_DIR = ROOT / "artifacts" / "compiled_model_tmp"


def hash_tree(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(path)
    digest = hashlib.sha256()
    if path.is_file():
        digest.update(path.name.encode("utf-8"))
        digest.update(path.read_bytes())
        return digest.hexdigest()

    for child in sorted(path.rglob("*")):
        if child.is_dir():
            continue
        digest.update(str(child.relative_to(path)).encode("utf-8"))
        digest.update(child.read_bytes())
    return digest.hexdigest()


def compile_mlmodel(mlmodel_path: Path, output_parent: Path) -> Path:
    output_parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "coremlc", "compile", str(mlmodel_path), str(output_parent)],
        check=True,
        cwd=ROOT,
    )
    compiled = output_parent / (mlmodel_path.stem + ".mlmodelc")
    if not compiled.exists():
        raise FileNotFoundError(f"compiled model missing: {compiled}")
    return compiled


def validate_compiled_model(path: Path):
    """在切換正式路徑前，用執行階段的 Core ML 載入器驗證暫存模型。"""
    subprocess.run([
        "swift", "-e",
        "import CoreML; import Foundation; "
        "let config = MLModelConfiguration(); config.computeUnits = .cpuOnly; "
        "_ = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: config)",
        str(path),
    ], check=True, capture_output=True, text=True)


def swap_paths(first: Path, second: Path):
    """macOS 原子交換同磁碟的兩個目錄，正式路徑不會暫時消失。"""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(second))


def install_model(source: Path, target: Path):
    source = source.expanduser().resolve()
    target = target.expanduser().absolute()
    if not source.is_dir() or source.suffix != ".mlmodelc":
        raise ValueError(f"compiled model directory missing: {source}")
    if target.parent.resolve() == source or source in target.parent.resolve().parents:
        raise ValueError("模型安裝位置不可位於來源模型內")
    if target.exists() and not target.is_dir():
        raise ValueError(f"模型目標不是目錄：{target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.with_suffix(".mlmodelc.bak")
    # 固定鎖檔不能在解鎖後刪除，否則同時重試可能鎖到不同 inode。
    with (target.parent / ("." + target.name + ".install.lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        work = Path(tempfile.mkdtemp(prefix="." + target.name + ".install-", dir=target.parent))
        cleanup = True
        try:
            staged = work / "new.mlmodelc"
            shutil.copytree(source, staged)
            validate_compiled_model(staged)
            # 複製或驗證失敗時，不動正式模型及備份；切換本身也是原子的。
            if target.exists():
                swap_paths(staged, target)
                try:
                    if backup.exists():
                        swap_paths(staged, backup)
                    else:
                        staged.rename(backup)
                except BaseException:
                    try:
                        swap_paths(staged, target)
                    except BaseException as rollback_error:
                        cleanup = False
                        raise RuntimeError(f"安裝／還原失敗，舊模型保留於：{staged}") from rollback_error
                    raise
            else:
                staged.rename(target)
        finally:
            # 還原也失敗時保留復原資料，禁止自動刪除唯一舊版本。
            if cleanup:
                shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help=".mlmodel, .mlpackage, or .mlmodelc path")
    parser.add_argument("--target", default=str(DEFAULT_TARGET))
    parser.add_argument("--compile-dir", default=str(DEFAULT_COMPILE_DIR))
    args = parser.parse_args()

    source = Path(args.source).expanduser().resolve()
    target = Path(args.target).expanduser()
    compiled_source = source

    if source.suffix in {".mlmodel", ".mlpackage"}:
        compiled_source = compile_mlmodel(source, Path(args.compile_dir))
    elif source.suffix == ".mlmodelc" or source.name.endswith(".mlmodelc"):
        compiled_source = source
    else:
        raise SystemExit("source must be .mlmodel, .mlpackage, or .mlmodelc")

    if target.exists() and hash_tree(compiled_source) == hash_tree(target):
        print("status=already_latest")
        print(f"source_model={source}")
        print(f"installed_model={target}")
        return

    install_model(compiled_source, target)
    print("status=installed")
    print(f"source_model={source}")
    print(f"installed_model={target}")


if __name__ == "__main__":
    main()
