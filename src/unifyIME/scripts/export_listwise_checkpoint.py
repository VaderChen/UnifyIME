#!/usr/bin/env python3
"""Export a trusted listwise PyTorch checkpoint as a Core ML package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from train_listwise_transformer import (
    ListwiseTransformerRanker,
    ModelConfig,
    export_coreml,
    model_parameter_count,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", help="listwise_checkpoint.pt path")
    parser.add_argument("--output", required=True, help="output directory")
    args = parser.parse_args()

    checkpoint_path = Path(args.checkpoint).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    payload = torch.load(checkpoint_path, map_location="cpu", weights_only=False)

    config = ModelConfig(**payload["config"])
    model = ListwiseTransformerRanker(config)
    model.load_state_dict(payload["model_state"], strict=True)
    model.eval()
    package_path = export_coreml(model, output)

    metadata = {
        "schema": "listwise_checkpoint_export_v1",
        "checkpoint": str(checkpoint_path),
        "package": str(package_path),
        "architecture": str(payload.get("architecture", "")),
        "best_epoch": int(payload.get("best_epoch", 0)),
        "parameter_count": model_parameter_count(model),
        "config": payload["config"],
        "metrics": payload.get("metrics", {}),
    }
    metadata_path = output / "export_metadata.json"
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
