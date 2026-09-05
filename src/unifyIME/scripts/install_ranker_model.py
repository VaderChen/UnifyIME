#!/usr/bin/env python3
import argparse
import hashlib
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TARGET = Path.home() / "Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc"
DEFAULT_COMPILE_DIR = ROOT / "artifacts" / "compiled_model_tmp"


def hash_tree(path: Path) -> str:
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
    compiled = output_parent / "CandidateRanker.mlmodelc"
    if not compiled.exists():
        raise FileNotFoundError(f"compiled model missing: {compiled}")
    return compiled


def install_model(source: Path, target: Path):
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.with_suffix(".mlmodelc.bak")
    if backup.exists():
        shutil.rmtree(backup)
    if target.exists():
        shutil.copytree(target, backup)
        shutil.rmtree(target)
    shutil.copytree(source, target)


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
