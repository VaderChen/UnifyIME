#!/usr/bin/env python3
"""Train a compact character-level listwise residual ranker and export Core ML.

The model evaluates the whole candidate set in one forward pass.  It encodes
left context, candidate surface, reading, and right-context readings with a
small character Transformer, then applies a second Transformer across the
candidate set.  The output is a bounded correction added to the existing
heuristic score.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import html
import json
import math
import random
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset

try:
    import coremltools as ct
except Exception:  # pragma: no cover - export is optional during smoke tests
    ct = None


PROJECT_ROOT = Path(__file__).resolve().parents[3]


PAD_ID = 0
BOS_ID = 1
LEFT_ID = 2
CANDIDATE_ID = 3
READING_ID = 4
RIGHT_ID = 5
END_ID = 6
HASH_OFFSET = 8

TYPE_PAD = 0
TYPE_SPECIAL = 1
TYPE_LEFT = 2
TYPE_CANDIDATE = 3
TYPE_READING = 4
TYPE_RIGHT = 5
TYPE_COUNT = 6

MIXED_CONTEXT_WORDS = (
    "project",
    "everybody",
    "feature flag",
    "input token",
    "machine learning",
    "writing tools",
    "data model",
    "user interface",
)


@dataclass(frozen=True)
class ModelConfig:
    vocab_size: int = 16_384
    sequence_length: int = 48
    max_candidates: int = 20
    numeric_dimension: int = 8
    model_dimension: int = 256
    attention_heads: int = 8
    feedforward_dimension: int = 768
    sequence_layers: int = 6
    set_layers: int = 3
    dropout: float = 0.1
    residual_bound: float = 120.0


def stable_fraction(text: str, seed: int) -> float:
    digest = hashlib.sha256(f"{seed}:{text}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(2**64)


def scalar_hash(value: str) -> int:
    result = 2_166_136_261
    for character in value:
        result ^= ord(character)
        result = (result * 16_777_619) & 0xFFFF_FFFF
    return result


def character_id(character: str, vocab_size: int) -> int:
    return HASH_OFFSET + scalar_hash(character) % (vocab_size - HASH_OFFSET)


def is_han(character: str) -> bool:
    value = ord(character)
    return (
        0x3400 <= value <= 0x4DBF
        or 0x4E00 <= value <= 0x9FFF
        or 0xF900 <= value <= 0xFAFF
        or 0x20000 <= value <= 0x2FA1F
    )


def ratios(value: str) -> tuple[float, float]:
    if not value:
        return 0.0, 0.0
    han = sum(is_han(character) for character in value)
    latin = sum(character.isascii() and character.isalpha() for character in value)
    size = max(1, len(value))
    return han / size, latin / size


def encode_text(
    row: dict[str, Any],
    config: ModelConfig,
    mixed_prefix: str = "",
) -> tuple[np.ndarray, np.ndarray]:
    left = "".join(str(value) for value in row.get("preceding_values", []))
    if mixed_prefix:
        left = f"{left} {mixed_prefix} "
    left = left[-14:]
    candidate = str(row.get("candidate_surface", ""))[:8]
    reading = str(row.get("combined_token", ""))[:12]
    right = "".join(str(value) for value in row.get("following_tokens", []))[:8]

    token_ids: list[int] = [BOS_ID, LEFT_ID]
    token_types: list[int] = [TYPE_SPECIAL, TYPE_SPECIAL]

    def append_text(value: str, token_type: int) -> None:
        for character in value:
            token_ids.append(character_id(character, config.vocab_size))
            token_types.append(token_type)

    append_text(left, TYPE_LEFT)
    token_ids.append(CANDIDATE_ID)
    token_types.append(TYPE_SPECIAL)
    append_text(candidate, TYPE_CANDIDATE)
    token_ids.append(READING_ID)
    token_types.append(TYPE_SPECIAL)
    append_text(reading, TYPE_READING)
    token_ids.append(RIGHT_ID)
    token_types.append(TYPE_SPECIAL)
    append_text(right, TYPE_RIGHT)
    token_ids.append(END_ID)
    token_types.append(TYPE_SPECIAL)

    token_ids = token_ids[: config.sequence_length]
    token_types = token_types[: config.sequence_length]
    if token_ids[-1] != END_ID:
        token_ids[-1] = END_ID
        token_types[-1] = TYPE_SPECIAL
    padding = config.sequence_length - len(token_ids)
    if padding > 0:
        token_ids.extend([PAD_ID] * padding)
        token_types.extend([TYPE_PAD] * padding)
    return np.asarray(token_ids, dtype=np.int32), np.asarray(token_types, dtype=np.int32)


def numeric_features(row: dict[str, Any]) -> np.ndarray:
    surface = str(row.get("candidate_surface", ""))
    preceding = "".join(str(value) for value in row.get("preceding_values", []))
    han_ratio, latin_ratio = ratios(surface)
    return np.asarray(
        [
            min(max(float(row.get("base_rank", 0.0)), 0.0), 19.0) / 19.0,
            min(max(float(row.get("span_length", 1.0)), 1.0), 8.0) / 8.0,
            min(len(surface), 8) / 8.0,
            min(len(preceding), 24) / 24.0,
            min(len(row.get("following_tokens", [])), 12) / 12.0,
            han_ratio,
            latin_ratio,
            1.0 if row.get("language_id") == "zh-Hant" else 0.0,
        ],
        dtype=np.float32,
    )


def heuristic_score(row: dict[str, Any]) -> float:
    surface = str(row.get("candidate_surface", ""))
    combined = str(row.get("combined_token", ""))
    preceding = row.get("preceding_values", [])
    rank_penalty = float(row.get("base_rank", 0)) * 40.0
    phrase_bonus = 120.0 if len(surface) > 1 else 0.0
    exact_reading_penalty = 200.0 if surface == combined else 0.0
    context_bonus = min(max(len(surface) - 1, 0) * 25.0, 75.0) if preceding else 0.0
    language_bias = 20.0 if row.get("language_id") == "zh-Hant" else 0.0
    han_bias = 10.0 if surface and all(is_han(character) for character in surface) else 0.0
    return phrase_bonus + context_bonus + language_bias + han_bias - rank_penalty - exact_reading_penalty


def group_fingerprint(rows: list[dict[str, Any]]) -> str:
    positive = next((row for row in rows if float(row.get("label", 0)) > 0), rows[0])
    return "|".join(
        [
            "".join(str(value) for value in positive.get("preceding_values", [])),
            str(positive.get("combined_token", "")),
            str(positive.get("candidate_surface", "")),
            "".join(str(value) for value in positive.get("following_tokens", [])),
        ]
    )


def group_tags(rows: list[dict[str, Any]]) -> set[str]:
    return {
        str(tag)
        for row in rows
        for tag in row.get("tags", [])
        if str(tag)
    }


def load_groups(paths: Iterable[Path]) -> list[list[dict[str, Any]]]:
    grouped: dict[tuple[str, Any, Any], list[dict[str, Any]]] = defaultdict(list)
    for path in paths:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                source_key = str(path.resolve())
                grouped[(source_key, row.get("case_id"), row.get("step_id"))].append(row)
    result = []
    for rows in grouped.values():
        positives = [row for row in rows if float(row.get("label", 0)) > 0]
        if len(rows) > 1 and len(positives) == 1:
            result.append(sorted(rows, key=lambda row: int(row.get("base_rank", 999))))
    return result


def sample_extra_groups(
    groups: list[list[dict[str, Any]]],
    limit: int,
    excluded_fingerprints: set[str],
    seed: int,
) -> list[list[dict[str, Any]]]:
    filtered = [group for group in groups if group_fingerprint(group) not in excluded_fingerprints]
    hard = [group for group in filtered if int(next(row for row in group if row.get("label", 0) > 0).get("base_rank", 0)) > 0]
    easy = [group for group in filtered if group not in hard]
    hard.sort(key=lambda group: stable_fraction(group_fingerprint(group), seed))
    easy.sort(key=lambda group: stable_fraction(group_fingerprint(group), seed))
    if limit <= 0 or len(filtered) <= limit:
        return hard + easy
    hard_limit = min(len(hard), max(1, limit // 4))
    return hard[:hard_limit] + easy[: max(0, limit - hard_limit)]


class CandidateGroupDataset(Dataset):
    def __init__(
        self,
        groups: list[list[dict[str, Any]]],
        config: ModelConfig,
        training: bool,
        mixed_augment_probability: float,
        seed: int,
    ) -> None:
        self.groups = groups
        self.config = config
        self.training = training
        self.mixed_augment_probability = mixed_augment_probability
        self.seed = seed
        self.real_selection_indices = [
            index
            for index, group in enumerate(groups)
            if "real_user_selection" in group_tags(group)
        ]
        real_selection_set = set(self.real_selection_indices)
        self.non_real_selection_indices = [
            index for index in range(len(groups)) if index not in real_selection_set
        ]

    def __len__(self) -> int:
        return len(self.groups)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        rows = self.groups[index]
        positive_index = next(i for i, row in enumerate(rows) if float(row.get("label", 0)) > 0)
        if positive_index >= self.config.max_candidates:
            rows = rows[: self.config.max_candidates - 1] + [rows[positive_index]]
            rows = sorted(rows, key=lambda row: int(row.get("base_rank", 999)))
            positive_index = next(i for i, row in enumerate(rows) if float(row.get("label", 0)) > 0)
        else:
            rows = rows[: self.config.max_candidates]

        mixed_prefix = ""
        if self.training:
            fraction = stable_fraction(group_fingerprint(rows), self.seed)
            if fraction < self.mixed_augment_probability:
                mixed_prefix = MIXED_CONTEXT_WORDS[int(fraction * 10_000) % len(MIXED_CONTEXT_WORDS)]

        token_ids = np.zeros(
            (self.config.max_candidates, self.config.sequence_length), dtype=np.int32
        )
        token_types = np.zeros_like(token_ids)
        numeric = np.zeros(
            (self.config.max_candidates, self.config.numeric_dimension), dtype=np.float32
        )
        base_scores = np.full((self.config.max_candidates,), -10_000.0, dtype=np.float32)
        candidate_mask = np.zeros((self.config.max_candidates,), dtype=np.float32)

        for candidate_index, row in enumerate(rows):
            ids, types = encode_text(row, self.config, mixed_prefix=mixed_prefix)
            token_ids[candidate_index] = ids
            token_types[candidate_index] = types
            numeric[candidate_index] = numeric_features(row)
            base_scores[candidate_index] = heuristic_score(row)
            candidate_mask[candidate_index] = 1.0

        positive_rank = int(rows[positive_index].get("base_rank", positive_index))
        hard = positive_rank > 0
        tags = group_tags(rows)
        return {
            "token_ids": torch.from_numpy(token_ids),
            "token_types": torch.from_numpy(token_types),
            "numeric_features": torch.from_numpy(numeric),
            "candidate_mask": torch.from_numpy(candidate_mask),
            "base_scores": torch.from_numpy(base_scores),
            "target": torch.tensor(positive_index, dtype=torch.long),
            "hard": torch.tensor(1.0 if hard else 0.0, dtype=torch.float32),
            "real_selection": torch.tensor(
                1.0 if "real_user_selection" in tags else 0.0,
                dtype=torch.float32,
            ),
            "weak_article": torch.tensor(
                1.0 if "weak_article_label" in tags else 0.0,
                dtype=torch.float32,
            ),
            "mixed_context": torch.tensor(
                1.0
                if "mixed_context" in tags or bool(rows[0].get("mixed_context"))
                else 0.0,
                dtype=torch.float32,
            ),
        }


class StratifiedSelectionBatchSampler:
    def __init__(
        self,
        real_selection_indices: list[int],
        non_real_selection_indices: list[int],
        batch_size: int,
        real_selection_fraction: float,
        seed: int,
    ) -> None:
        if batch_size < 2:
            raise ValueError("stratified batch size must be at least 2")
        if not real_selection_indices or not non_real_selection_indices:
            raise ValueError("stratified batches require both real and non-real groups")
        if not 0.0 < real_selection_fraction < 1.0:
            raise ValueError("real selection batch fraction must be between 0 and 1")
        self.real_selection_indices = list(real_selection_indices)
        self.non_real_selection_indices = list(non_real_selection_indices)
        self.batch_size = batch_size
        self.real_per_batch = min(
            batch_size - 1,
            max(1, round(batch_size * real_selection_fraction)),
        )
        self.non_real_per_batch = batch_size - self.real_per_batch
        self.seed = seed
        self.iteration = 0
        self.batch_count = math.ceil(
            (len(real_selection_indices) + len(non_real_selection_indices)) / batch_size
        )

    def __len__(self) -> int:
        return self.batch_count

    def __iter__(self) -> Iterator[list[int]]:
        rng = random.Random(self.seed + self.iteration * 1_000_003)
        self.iteration += 1
        real_pool = list(self.real_selection_indices)
        non_real_pool = list(self.non_real_selection_indices)
        rng.shuffle(real_pool)
        rng.shuffle(non_real_pool)
        real_cursor = 0
        non_real_cursor = 0

        def draw(pool: list[int], cursor: int, count: int) -> tuple[list[int], int]:
            selected: list[int] = []
            for _ in range(count):
                if cursor >= len(pool):
                    rng.shuffle(pool)
                    cursor = 0
                selected.append(pool[cursor])
                cursor += 1
            return selected, cursor

        for _ in range(self.batch_count):
            real_batch, real_cursor = draw(
                real_pool,
                real_cursor,
                self.real_per_batch,
            )
            non_real_batch, non_real_cursor = draw(
                non_real_pool,
                non_real_cursor,
                self.non_real_per_batch,
            )
            batch = real_batch + non_real_batch
            rng.shuffle(batch)
            yield batch


class SelfAttentionBlock(nn.Module):
    def __init__(self, dimension: int, heads: int, feedforward: int, dropout: float) -> None:
        super().__init__()
        if dimension % heads != 0:
            raise ValueError("model dimension must be divisible by attention heads")
        self.dimension = dimension
        self.heads = heads
        self.head_dimension = dimension // heads
        self.scale = self.head_dimension**-0.5
        self.norm1 = nn.LayerNorm(dimension)
        self.qkv = nn.Linear(dimension, dimension * 3)
        self.projection = nn.Linear(dimension, dimension)
        self.norm2 = nn.LayerNorm(dimension)
        self.feedforward = nn.Sequential(
            nn.Linear(dimension, feedforward),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(feedforward, dimension),
        )
        self.dropout = nn.Dropout(dropout)

    def forward(self, values: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        batch, length, _ = values.shape
        normalized = self.norm1(values)
        qkv = self.qkv(normalized).reshape(batch, length, 3, self.heads, self.head_dimension)
        query = qkv[:, :, 0].permute(0, 2, 1, 3)
        key = qkv[:, :, 1].permute(0, 2, 1, 3)
        value = qkv[:, :, 2].permute(0, 2, 1, 3)
        attention = torch.matmul(query, key.transpose(-2, -1)) * self.scale
        attention = attention.masked_fill(mask[:, None, None, :] <= 0, -10_000.0)
        attention = torch.softmax(attention, dim=-1)
        attended = torch.matmul(attention, value)
        attended = attended.permute(0, 2, 1, 3).reshape(batch, length, self.dimension)
        values = values + self.dropout(self.projection(attended))
        values = values + self.dropout(self.feedforward(self.norm2(values)))
        return values * mask.unsqueeze(-1)


class ListwiseTransformerRanker(nn.Module):
    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.config = config
        dimension = config.model_dimension
        self.token_embedding = nn.Embedding(config.vocab_size, dimension, padding_idx=PAD_ID)
        self.type_embedding = nn.Embedding(TYPE_COUNT, dimension, padding_idx=TYPE_PAD)
        self.position_embedding = nn.Parameter(
            torch.zeros(1, config.sequence_length, dimension)
        )
        self.sequence_blocks = nn.ModuleList(
            [
                SelfAttentionBlock(
                    dimension,
                    config.attention_heads,
                    config.feedforward_dimension,
                    config.dropout,
                )
                for _ in range(config.sequence_layers)
            ]
        )
        self.numeric_projection = nn.Sequential(
            nn.Linear(config.numeric_dimension, dimension),
            nn.GELU(),
            nn.Linear(dimension, dimension),
        )
        self.set_position_embedding = nn.Parameter(
            torch.zeros(1, config.max_candidates, dimension)
        )
        self.set_blocks = nn.ModuleList(
            [
                SelfAttentionBlock(
                    dimension,
                    config.attention_heads,
                    config.feedforward_dimension,
                    config.dropout,
                )
                for _ in range(config.set_layers)
            ]
        )
        self.output_norm = nn.LayerNorm(dimension)
        self.output = nn.Linear(dimension, 1)
        nn.init.normal_(self.position_embedding, std=0.02)
        nn.init.normal_(self.set_position_embedding, std=0.02)
        nn.init.zeros_(self.output.weight)
        nn.init.zeros_(self.output.bias)

    def forward(
        self,
        token_ids: torch.Tensor,
        token_types: torch.Tensor,
        numeric_features_tensor: torch.Tensor,
        candidate_mask: torch.Tensor,
    ) -> torch.Tensor:
        batch, candidates, sequence_length = token_ids.shape
        flat_ids = token_ids.reshape(batch * candidates, sequence_length).long()
        flat_types = token_types.reshape(batch * candidates, sequence_length).long()
        token_mask = (flat_ids != PAD_ID).float()
        values = (
            self.token_embedding(flat_ids)
            + self.type_embedding(flat_types)
            + self.position_embedding[:, :sequence_length]
        )
        values = values * token_mask.unsqueeze(-1)
        for block in self.sequence_blocks:
            values = block(values, token_mask)
        candidate_values = (values * token_mask.unsqueeze(-1)).sum(dim=1)
        candidate_values = candidate_values / token_mask.sum(dim=1, keepdim=True).clamp(min=1.0)
        candidate_values = candidate_values.reshape(batch, candidates, self.config.model_dimension)
        candidate_values = (
            candidate_values
            + self.numeric_projection(numeric_features_tensor)
            + self.set_position_embedding[:, :candidates]
        )
        candidate_values = candidate_values * candidate_mask.unsqueeze(-1)
        for block in self.set_blocks:
            candidate_values = block(candidate_values, candidate_mask)
        raw = self.output(self.output_norm(candidate_values)).squeeze(-1)
        residual = torch.tanh(raw) * self.config.residual_bound
        return residual * candidate_mask


def model_parameter_count(model: nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters())


def move_batch(batch: dict[str, torch.Tensor], device: str) -> dict[str, torch.Tensor]:
    return {key: value.to(device) for key, value in batch.items()}


def ranking_metrics(
    model: nn.Module,
    loader: DataLoader,
    device: str,
    residual_scale: float = 1.0,
) -> dict[str, Any]:
    model.eval()
    cohort_counts: dict[str, dict[str, float]] = {
        name: defaultdict(float)
        for name in ("overall", "real_selection", "open_article", "mixed_context")
    }
    with torch.no_grad():
        for raw_batch in loader:
            batch = move_batch(raw_batch, device)
            residual = model(
                batch["token_ids"],
                batch["token_types"],
                batch["numeric_features"],
                batch["candidate_mask"],
            )
            mask = batch["candidate_mask"]
            base_scores = batch["base_scores"].masked_fill(mask <= 0, -10_000.0)
            scaled_residual = residual * residual_scale
            combined_scores = (base_scores + scaled_residual).masked_fill(mask <= 0, -10_000.0)
            pure_scores = residual.masked_fill(mask <= 0, -10_000.0)
            baseline = base_scores.argmax(dim=1)
            combined = combined_scores.argmax(dim=1)
            pure = pure_scores.argmax(dim=1)
            target = batch["target"]
            hard = batch["hard"] > 0.5
            baseline_ok = baseline == target
            combined_ok = combined == target
            pure_ok = pure == target
            cohort_masks = {
                "overall": torch.ones_like(hard, dtype=torch.bool),
                "real_selection": batch["real_selection"] > 0.5,
                "open_article": batch["weak_article"] > 0.5,
                "mixed_context": batch["mixed_context"] > 0.5,
            }
            for name, selected in cohort_masks.items():
                counts = cohort_counts[name]
                selected_hard = selected & hard
                selected_candidates = mask * selected.unsqueeze(1)
                counts["groups"] += float(selected.sum().item())
                counts["baseline_correct"] += float((selected & baseline_ok).sum().item())
                counts["combined_correct"] += float((selected & combined_ok).sum().item())
                counts["pure_correct"] += float((selected & pure_ok).sum().item())
                counts["hard_groups"] += float(selected_hard.sum().item())
                counts["hard_combined_correct"] += float(
                    (selected_hard & combined_ok).sum().item()
                )
                counts["hard_pure_correct"] += float(
                    (selected_hard & pure_ok).sum().item()
                )
                counts["improved"] += float(
                    (selected & (~baseline_ok) & combined_ok).sum().item()
                )
                counts["harmed"] += float(
                    (selected & baseline_ok & (~combined_ok)).sum().item()
                )
                counts["changed"] += float((selected & (baseline != combined)).sum().item())
                counts["residual_abs"] += float(
                    (scaled_residual.abs() * selected_candidates).sum().item()
                )
                counts["residual_count"] += float(selected_candidates.sum().item())

    def finalize(counts: dict[str, float]) -> dict[str, float | int]:
        groups = int(counts["groups"])
        hard_groups = int(counts["hard_groups"])
        improved = int(counts["improved"])
        harmed = int(counts["harmed"])
        return {
            "groups": groups,
            "hard_groups": hard_groups,
            "baseline_top1": counts["baseline_correct"] / max(groups, 1),
            "combined_top1": counts["combined_correct"] / max(groups, 1),
            "pure_top1": counts["pure_correct"] / max(groups, 1),
            "hard_combined_top1": counts["hard_combined_correct"] / max(hard_groups, 1),
            "hard_pure_top1": counts["hard_pure_correct"] / max(hard_groups, 1),
            "improved": improved,
            "harmed": harmed,
            "net_lift": improved - harmed,
            "changed": int(counts["changed"]),
            "mean_abs_residual": counts["residual_abs"] / max(counts["residual_count"], 1.0),
        }

    finalized = {name: finalize(counts) for name, counts in cohort_counts.items()}
    overall: dict[str, Any] = dict(finalized.pop("overall"))
    overall["cohorts"] = finalized
    return overall


def export_coreml(model: ListwiseTransformerRanker, output: Path) -> Path:
    if ct is None:
        raise RuntimeError("coremltools is unavailable")
    config = model.config
    model_cpu = copy.deepcopy(model).cpu().eval()
    examples = (
        torch.zeros(
            1, config.max_candidates, config.sequence_length, dtype=torch.int32
        ),
        torch.zeros(
            1, config.max_candidates, config.sequence_length, dtype=torch.int32
        ),
        torch.zeros(
            1, config.max_candidates, config.numeric_dimension, dtype=torch.float32
        ),
        torch.ones(1, config.max_candidates, dtype=torch.float32),
    )
    traced = torch.jit.trace(model_cpu, examples)
    package_path = output / "ListwiseCandidateRanker.mlpackage"
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(
                name="token_ids",
                shape=examples[0].shape,
                dtype=np.int32,
            ),
            ct.TensorType(
                name="token_types",
                shape=examples[1].shape,
                dtype=np.int32,
            ),
            ct.TensorType(
                name="numeric_features",
                shape=examples[2].shape,
                dtype=np.float32,
            ),
            ct.TensorType(
                name="candidate_mask",
                shape=examples[3].shape,
                dtype=np.float32,
            ),
        ],
        outputs=[ct.TensorType(name="residual_scores")],
    )
    mlmodel.author = "FastChIME"
    mlmodel.short_description = "Character-level listwise candidate residual ranker"
    mlmodel.user_defined_metadata.update(
        {
            "architecture": "char_listwise_transformer_v1",
            "score_semantics": "bounded_residual_points_v1",
            "max_candidates": str(config.max_candidates),
            "sequence_length": str(config.sequence_length),
            "vocab_size": str(config.vocab_size),
            "parameter_count": str(model_parameter_count(model_cpu)),
        }
    )
    mlmodel.save(package_path)
    return package_path


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


GRADIENT_GROUPS = (
    "embeddings",
    "sequence_transformer",
    "candidate_set_transformer",
    "output_head",
    "other",
)


def gradient_group_name(parameter_name: str) -> str:
    if parameter_name.startswith(("token_embedding", "type_embedding", "position_embedding")):
        return "embeddings"
    if parameter_name.startswith("sequence_blocks"):
        return "sequence_transformer"
    if parameter_name.startswith(("numeric_projection", "set_position_embedding", "set_blocks")):
        return "candidate_set_transformer"
    if parameter_name.startswith(("output_norm", "output")):
        return "output_head"
    return "other"


def gradient_group_norms(model: nn.Module) -> dict[str, float]:
    squared: dict[str, torch.Tensor | None] = {name: None for name in GRADIENT_GROUPS}
    for parameter_name, parameter in model.named_parameters():
        if parameter.grad is None:
            continue
        group = gradient_group_name(parameter_name)
        value = parameter.grad.detach().float().square().sum()
        squared[group] = value if squared[group] is None else squared[group] + value
    return {
        name: math.sqrt(max(0.0, float(value.item()))) if value is not None else 0.0
        for name, value in squared.items()
    }


def write_gradient_artifacts(
    output: Path,
    records: list[dict[str, Any]],
    gradient_clip: float,
    dashboard: Path | None = None,
    total_epochs: int | None = None,
) -> tuple[Path, Path]:
    history_path = output / "gradient_history.jsonl"
    history_path.write_text(
        "".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records),
        encoding="utf-8",
    )
    svg_path = output / "gradient_norms.svg"
    width, height = 1200, 720
    left, right, top, bottom = 105, 35, 70, 85
    plot_width = width - left - right
    plot_height = height - top - bottom
    series = [
        "total_preclip",
        "epoch_mean_total_preclip",
        "mean_clip_ratio",
    ]
    series_labels = {
        "total_preclip": "50-step mean gradient",
        "epoch_mean_total_preclip": "epoch mean gradient",
        "mean_clip_ratio": "mean clip ratio",
    }
    colors = {
        "total_preclip": "#111827",
        "epoch_mean_total_preclip": "#2563eb",
        "mean_clip_ratio": "#db2777",
    }

    def series_value(record: dict[str, Any], name: str) -> float:
        raw = record.get(name)
        if name == "mean_clip_ratio" and raw is None:
            mean_gradient = float(record.get("total_preclip", 0.0))
            clip_threshold = float(record.get("clip_threshold", gradient_clip))
            return min(1.0, clip_threshold / max(mean_gradient, 1e-12))
        return float(raw or 0.0)

    def raw_display(name: str, value: float) -> str:
        return f'{value * 100.0:.3f}%' if name == "mean_clip_ratio" else f'{value:.6f}'

    plot_records = [
        record for record in records if int(record.get("global_step", 0)) > 1
    ] or records
    normalizers: dict[str, float] = {}
    for name in series:
        normalizers[name] = next(
            (
                series_value(record, name)
                for record in plot_records
                if math.isfinite(series_value(record, name))
                and series_value(record, name) > 0
            ),
            1.0,
        )
    normalized_values = [
        series_value(record, name) / max(normalizers[name], 1e-12)
        for record in plot_records
        for name in series
        if math.isfinite(series_value(record, name)) and series_value(record, name) > 0
    ]
    normalized_max = max(normalized_values, default=1.0)
    y_max = max(1.2, math.ceil(normalized_max * 5.0) / 5.0)
    max_step = max(
        (int(record.get("global_step", 0)) for record in plot_records),
        default=1,
    )

    def x_position(step: int) -> float:
        return left + plot_width * step / max(1, max_step)

    def y_position(value: float) -> float:
        fraction = min(1.0, max(0.0, value / max(y_max, 1e-12)))
        return top + plot_height * (1.0 - fraction)

    def smooth_path(points: list[tuple[float, float]]) -> str:
        if not points:
            return ""
        if len(points) == 1:
            return f'M {points[0][0]:.2f},{points[0][1]:.2f}'
        intervals = [
            max(1e-12, points[index + 1][0] - points[index][0])
            for index in range(len(points) - 1)
        ]
        slopes = [
            (points[index + 1][1] - points[index][1]) / intervals[index]
            for index in range(len(points) - 1)
        ]
        tangents = [0.0] * len(points)
        tangents[0] = slopes[0]
        tangents[-1] = slopes[-1]
        for index in range(1, len(points) - 1):
            previous_slope = slopes[index - 1]
            next_slope = slopes[index]
            if previous_slope * next_slope <= 0.0:
                tangents[index] = 0.0
                continue
            previous_interval = intervals[index - 1]
            next_interval = intervals[index]
            previous_weight = 2.0 * next_interval + previous_interval
            next_weight = next_interval + 2.0 * previous_interval
            tangents[index] = (previous_weight + next_weight) / (
                previous_weight / previous_slope + next_weight / next_slope
            )
        commands = [f'M {points[0][0]:.2f},{points[0][1]:.2f}']
        for index, interval in enumerate(intervals):
            x0, y0 = points[index]
            x1, y1 = points[index + 1]
            control1_x = x0 + interval / 3.0
            control1_y = y0 + tangents[index] * interval / 3.0
            control2_x = x1 - interval / 3.0
            control2_y = y1 - tangents[index + 1] * interval / 3.0
            commands.append(
                f'C {control1_x:.2f},{control1_y:.2f} '
                f'{control2_x:.2f},{control2_y:.2f} {x1:.2f},{y1:.2f}'
            )
        return " ".join(commands)

    def popup_values(record: dict[str, Any]) -> dict[str, tuple[str, str]]:
        values: dict[str, tuple[str, str]] = {}
        for name in series:
            raw = series_value(record, name)
            normalized = raw / max(normalizers[name], 1e-12)
            values[name] = (f'{normalized:.4f}×', raw_display(name, raw))
        return values

    latest = records[-1] if records else {}
    live_status = {
        "type": "fastchime-gradient-status",
        "turn": int(latest.get("epoch", 0)),
        "turns_total": int(total_epochs or 0),
        "global_step": int(latest.get("global_step", 0)),
        "total_preclip": float(latest.get("total_preclip", 0.0)),
        "mean_clip_ratio": float(latest.get("mean_clip_ratio", 0.0)),
        "learning_rate": float(latest.get("learning_rate", 0.0)),
    }
    live_status_json = json.dumps(
        live_status,
        ensure_ascii=False,
        separators=(",", ":"),
    )

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<title>Listwise Transformer Mean Gradients</title>',
        '<desc>Move across the plot to inspect all normalized values at the nearest optimizer step.</desc>',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<style>text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;fill:#1f2937}.small{font-size:13px}.axis{stroke:#9ca3af;stroke-width:1}.grid{stroke:#e5e7eb;stroke-width:1}.step-target{fill:transparent;pointer-events:all;cursor:crosshair}.step-target:focus{outline:none}.hover-guide{stroke:#6b7280;stroke-width:1.5;stroke-dasharray:6 5}.tooltip-box{fill:#111827;fill-opacity:.96;stroke:#4b5563;stroke-width:1}.tooltip-title{fill:#fff;font-size:15px;font-weight:600}.tooltip-value{fill:#e5e7eb;font-size:13px}</style>',
        '<text x="105" y="36" font-size="24" font-weight="700">Listwise Transformer Mean Gradients</text>',
        f'<text x="1165" y="36" text-anchor="end" font-size="16" font-weight="600">turn {live_status["turn"]}/{live_status["turns_total"]} · step {live_status["global_step"]}</text>',
        '<text x="105" y="58" class="small">Exact 50-step mean + full epoch-to-date mean + mean clip ratio · normalized to first observation = 1.0×</text>',
    ]
    for tick in range(6):
        value = y_max * tick / 5.0
        y = y_position(value)
        lines.append(f'<line class="grid" x1="{left}" y1="{y:.2f}" x2="{left + plot_width}" y2="{y:.2f}"/>')
        lines.append(f'<text x="{left - 12}" y="{y + 5:.2f}" text-anchor="end" class="small">{value:.2f}×</text>')
    lines.append(f'<line class="axis" x1="{left}" y1="{top}" x2="{left}" y2="{top + plot_height}"/>')
    lines.append(f'<line class="axis" x1="{left}" y1="{top + plot_height}" x2="{left + plot_width}" y2="{top + plot_height}"/>')
    epoch_starts: dict[int, int] = {}
    for record in plot_records:
        epoch_starts.setdefault(int(record.get("epoch", 0)), int(record.get("global_step", 0)))
    for epoch, step in sorted(epoch_starts.items()):
        x = x_position(step)
        lines.append(f'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" y2="{top + plot_height}" stroke="#d1d5db" stroke-dasharray="4 5"/>')
        lines.append(f'<text x="{x + 5:.2f}" y="{top + 18}" class="small">epoch {epoch}</text>')
    for name in series:
        points: list[tuple[float, float]] = []
        for record in plot_records:
            value = series_value(record, name)
            if not math.isfinite(value) or value <= 0:
                continue
            normalized = value / max(normalizers[name], 1e-12)
            x = x_position(int(record.get("global_step", 0)))
            y = y_position(normalized)
            points.append((x, y))
        if points:
            line_width = 3.0 if name == "total_preclip" else 2.0
            lines.append(
                f'<path fill="none" stroke="{colors[name]}" '
                f'stroke-width="{line_width}" stroke-linecap="round" '
                f'stroke-linejoin="round" d="{smooth_path(points)}"/>'
            )
    legend_x = left
    legend_y = height - 42
    legend_column_width = plot_width / max(1, len(series))
    for index, name in enumerate(series):
        x = legend_x + index * legend_column_width
        lines.append(f'<line x1="{x}" y1="{legend_y}" x2="{x + 24}" y2="{legend_y}" stroke="{colors[name]}" stroke-width="3"/>')
        lines.append(f'<text x="{x + 31}" y="{legend_y + 5}" class="small">{html.escape(series_labels[name])}</text>')
    lines.append(f'<text x="{left + plot_width / 2:.2f}" y="{height - 10}" text-anchor="middle" class="small">optimizer step</text>')

    hover_records = sorted(
        plot_records,
        key=lambda record: int(record.get("global_step", 0)),
    )
    hover_positions = [
        x_position(int(record.get("global_step", 0))) for record in hover_records
    ]
    lines.append('<g id="hover-targets">')
    for index, (record, x) in enumerate(zip(hover_records, hover_positions)):
        x_start = left if index == 0 else (hover_positions[index - 1] + x) / 2.0
        x_end = (
            left + plot_width
            if index == len(hover_records) - 1
            else (x + hover_positions[index + 1]) / 2.0
        )
        epoch = int(record.get("epoch", 0))
        step = int(record.get("global_step", 0))
        values = popup_values(record)
        total_normalized = series_value(record, "total_preclip") / max(
            normalizers["total_preclip"], 1e-12
        )
        anchor_y = y_position(total_normalized)
        tooltip_text = f'epoch {epoch}｜step {step}｜' + '｜'.join(
            f'{series_labels[name]} 正規化 {values[name][0]} 原始值 {values[name][1]}'
            for name in series
        )
        lines.append(
            f'<rect class="step-target" x="{x_start:.2f}" y="{top}" '
            f'width="{max(0.1, x_end - x_start):.2f}" height="{plot_height}" '
            f'tabindex="0" role="img" aria-label="{html.escape(tooltip_text, quote=True)}" '
            f'data-x="{x:.2f}" data-anchor-y="{anchor_y:.2f}" '
            f'data-total-normalized="{values["total_preclip"][0]}" '
            f'data-total-raw="{values["total_preclip"][1]}" '
            f'data-epoch-normalized="{values["epoch_mean_total_preclip"][0]}" '
            f'data-epoch-raw="{values["epoch_mean_total_preclip"][1]}" '
            f'data-clip-normalized="{values["mean_clip_ratio"][0]}" '
            f'data-clip-raw="{values["mean_clip_ratio"][1]}" '
            f'data-epoch="{epoch}" data-step="{step}"/>'
        )
    lines.append('</g>')
    lines.extend(
        [
            f'<line id="hover-guide" class="hover-guide" y1="{top}" y2="{top + plot_height}" visibility="hidden" pointer-events="none"/>',
            '<g id="point-tooltip" visibility="hidden" pointer-events="none">',
            '<rect class="tooltip-box" width="500" height="116" rx="8"/>',
            '<text id="tooltip-title" class="tooltip-title" x="14" y="24"></text>',
            f'<circle cx="17" cy="49" r="4" fill="{colors["total_preclip"]}"/>',
            '<text id="tooltip-total" class="tooltip-value" x="30" y="53"></text>',
            f'<circle cx="17" cy="76" r="4" fill="{colors["epoch_mean_total_preclip"]}"/>',
            '<text id="tooltip-epoch" class="tooltip-value" x="30" y="80"></text>',
            f'<circle cx="17" cy="103" r="4" fill="{colors["mean_clip_ratio"]}"/>',
            '<text id="tooltip-clip" class="tooltip-value" x="30" y="107"></text>',
            '</g>',
            f'''<script><![CDATA[
if (window.parent && window.parent !== window) {{
  window.parent.postMessage({live_status_json}, '*');
}}
]]></script>''',
            '''<script><![CDATA[
(() => {
  const svg = document.documentElement;
  const tip = document.getElementById('point-tooltip');
  const guide = document.getElementById('hover-guide');
  const title = document.getElementById('tooltip-title');
  const total = document.getElementById('tooltip-total');
  const epochMean = document.getElementById('tooltip-epoch');
  const clip = document.getElementById('tooltip-clip');
  const hoverTargets = document.getElementById('hover-targets');
  const boxWidth = 500;
  const boxHeight = 116;
  const show = (target) => {
    title.textContent = `epoch ${target.dataset.epoch} · global step ${target.dataset.step}`;
    total.textContent = `50-step mean gradient  ${target.dataset.totalNormalized} · 原始 ${target.dataset.totalRaw}`;
    epochMean.textContent = `epoch mean gradient  ${target.dataset.epochNormalized} · 原始 ${target.dataset.epochRaw}`;
    clip.textContent = `mean clip ratio  ${target.dataset.clipNormalized} · 原始 ${target.dataset.clipRaw}`;
    const cx = Number(target.dataset.x);
    const cy = Number(target.dataset.anchorY);
    guide.setAttribute('x1', cx);
    guide.setAttribute('x2', cx);
    guide.setAttribute('visibility', 'visible');
    let x = cx + 12;
    let y = cy - boxHeight - 12;
    if (x + boxWidth > 1192) x = cx - boxWidth - 12;
    if (y < 8) y = cy + 12;
    x = Math.max(8, Math.min(x, 1192 - boxWidth));
    y = Math.max(8, Math.min(y, 712 - boxHeight));
    tip.setAttribute('transform', `translate(${x} ${y})`);
    tip.setAttribute('visibility', 'visible');
    tip.parentNode.appendChild(tip);
  };
  const hide = () => {
    tip.setAttribute('visibility', 'hidden');
    guide.setAttribute('visibility', 'hidden');
  };
  document.querySelectorAll('.step-target').forEach((target) => {
    target.addEventListener('mouseenter', () => show(target));
    target.addEventListener('focus', () => show(target));
    target.addEventListener('blur', hide);
  });
  hoverTargets.addEventListener('mouseleave', hide);
  svg.addEventListener('mouseleave', hide);
})();
]]></script>''',
        ]
    )
    lines.append('</svg>')
    svg_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if dashboard is not None:
        dashboard.mkdir(parents=True, exist_ok=True)
        shutil.copy2(svg_path, dashboard / "gradient_norms.svg")
        shutil.copy2(history_path, dashboard / "gradient_history.jsonl")
        write_json(
            dashboard / "active_run.json",
            {
                "run": str(output),
                "epoch": int(latest.get("epoch", 0)),
                "epochs_total": int(total_epochs or 0),
                "global_step": int(latest.get("global_step", 0)),
                "total_preclip": float(latest.get("total_preclip", 0.0)),
                "instant_total_preclip": float(
                    latest.get("instant_total_preclip", latest.get("total_preclip", 0.0))
                ),
                "effective_update_norm": float(latest.get("effective_update_norm", 0.0)),
                "mean_clip_ratio": float(latest.get("mean_clip_ratio", 0.0)),
                "learning_rate": float(latest.get("learning_rate", 0.0)),
                "hard_fraction": float(latest.get("hard_fraction", 0.0)),
                "weak_article_fraction": float(latest.get("weak_article_fraction", 0.0)),
                "updated_at": time.time(),
            },
        )
    return history_path, svg_path


def write_gradient_live_html(output: Path) -> Path:
    path = output / "gradient_live.html"
    path.write_text(
        """<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FastChIME 訓練梯度</title>
  <style>
    html,body{margin:0;background:#f3f4f6;color:#111827;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    header{display:flex;align-items:center;justify-content:space-between;padding:14px 20px;background:#111827;color:white}
    header strong{font-size:17px}.status{font-size:13px;color:#a7f3d0}
    main{padding:14px}.panel{background:white;border-radius:14px;box-shadow:0 8px 24px #0002;overflow:hidden}
    object{display:block;width:100%;height:calc(100vh - 90px)}
  </style>
</head>
<body>
  <header><strong>FastChIME · Listwise Transformer 即時梯度</strong><span class="status" id="status">載入訓練狀態…</span></header>
  <main><div class="panel" id="panel"><object id="chart" type="image/svg+xml" data="gradient_norms.svg" aria-label="gradient norms"><p>無法顯示梯度圖。</p></object></div></main>
  <script>
    const chart=document.getElementById('chart'), panel=document.getElementById('panel'), status=document.getElementById('status');
    let hovering=false;
    panel.addEventListener('mouseenter',()=>{hovering=true});
    panel.addEventListener('mouseleave',()=>{hovering=false});
    window.addEventListener('message',(event)=>{
      const s=event.data;if(!s||s.type!=='fastchime-gradient-status')return;
      const total=Number(s.turns_total)||20;
      status.textContent=`turn ${s.turn}/${total} · step ${s.global_step} · grad μ ${Number(s.total_preclip).toFixed(3)} · clip μ ${(100*Number(s.mean_clip_ratio)).toFixed(1)}% · lr ${Number(s.learning_rate).toExponential(1)}`;
    });
    function refresh(){
      const now=new Date();if(!hovering)chart.data='gradient_norms.svg?t='+now.getTime();
    }
    refresh();setInterval(refresh,5000);
  </script>
</body>
</html>
""",
        encoding="utf-8",
    )
    return path


def open_gradient_window(path: Path) -> None:
    if sys.platform != "darwin":
        return
    marker = path.parent / ".window_opened"
    if marker.exists():
        return
    marker.touch()
    subprocess.Popen(
        ["open", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def train(args: argparse.Namespace) -> int:
    if args.minimum_epochs < 1 or args.minimum_epochs > args.epochs:
        raise ValueError("minimum_epochs must be between 1 and epochs")
    if args.early_stopping_patience < 0:
        raise ValueError("early_stopping_patience must be non-negative")
    if args.stop_after_epoch < 0 or args.stop_after_epoch > args.epochs:
        raise ValueError("stop_after_epoch must be between 0 and epochs")
    training_residual_scale = float(
        args.evaluation_residual_scale
        if args.training_residual_scale is None
        else args.training_residual_scale
    )
    if training_residual_scale <= 0.0:
        raise ValueError("training residual scale must be positive")
    if args.no_harm_weight < 0.0 or args.checkpoint_anchor_weight < 0.0:
        raise ValueError("loss component weights must be non-negative")
    if args.no_harm_margin < 0.0:
        raise ValueError("no harm margin must be non-negative")
    if args.teacher_margin_tolerance < 0.0:
        raise ValueError("teacher margin tolerance must be non-negative")
    if args.harm_cost < 1.0 or args.improvement_gain <= 0.0:
        raise ValueError("business utility weights must be positive and harm cost >= 1")
    if (
        args.real_selection_preservation_weight < 1.0
        or args.real_selection_business_weight < 1.0
    ):
        raise ValueError("real selection weights must be at least 1")
    if args.checkpoint_top_k < 0:
        raise ValueError("checkpoint top-k must be non-negative")
    if not 0.0 <= args.real_selection_batch_fraction < 1.0:
        raise ValueError("real selection batch fraction must be in [0, 1)")
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)
    config = ModelConfig(
        vocab_size=args.vocab_size,
        sequence_length=args.sequence_length,
        max_candidates=args.max_candidates,
        model_dimension=args.model_dimension,
        attention_heads=args.attention_heads,
        feedforward_dimension=args.feedforward_dimension,
        sequence_layers=args.sequence_layers,
        set_layers=args.set_layers,
        dropout=args.dropout,
        residual_bound=args.residual_bound,
    )
    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    gradient_dashboard = Path(args.gradient_dashboard_dir).expanduser()
    gradient_dashboard.mkdir(parents=True, exist_ok=True)
    gradient_live_path = write_gradient_live_html(gradient_dashboard)
    if args.show_gradient_window:
        open_gradient_window(gradient_live_path)

    train_groups = load_groups([Path(args.train)])
    valid_groups = load_groups([Path(args.valid)])
    test_groups = load_groups([Path(args.test)]) if args.test else []
    excluded = {group_fingerprint(group) for group in valid_groups + test_groups}
    extra_groups = load_groups([Path(path) for path in args.extra_train]) if args.extra_train else []
    extra_groups = sample_extra_groups(
        extra_groups,
        args.max_extra_groups,
        excluded,
        args.seed,
    )
    train_groups = train_groups + extra_groups
    train_groups.sort(key=lambda group: stable_fraction(group_fingerprint(group), args.seed))

    train_dataset = CandidateGroupDataset(
        train_groups,
        config,
        training=True,
        mixed_augment_probability=args.mixed_augment_probability,
        seed=args.seed,
    )
    valid_dataset = CandidateGroupDataset(valid_groups, config, False, 0.0, args.seed)
    test_dataset = CandidateGroupDataset(test_groups, config, False, 0.0, args.seed)
    if (
        args.real_selection_batch_fraction > 0.0
        and train_dataset.real_selection_indices
        and train_dataset.non_real_selection_indices
    ):
        train_batch_sampler = StratifiedSelectionBatchSampler(
            train_dataset.real_selection_indices,
            train_dataset.non_real_selection_indices,
            args.batch_size,
            args.real_selection_batch_fraction,
            args.seed,
        )
        train_loader = DataLoader(
            train_dataset,
            batch_sampler=train_batch_sampler,
            num_workers=0,
        )
        print(
            f"stratified_batches=true batches={len(train_batch_sampler)} "
            f"real_per_batch={train_batch_sampler.real_per_batch} "
            f"non_real_per_batch={train_batch_sampler.non_real_per_batch}",
            flush=True,
        )
    else:
        generator = torch.Generator().manual_seed(args.seed)
        train_loader = DataLoader(
            train_dataset,
            batch_size=args.batch_size,
            shuffle=True,
            num_workers=0,
            generator=generator,
        )
        print("stratified_batches=false", flush=True)
    valid_loader = DataLoader(valid_dataset, batch_size=args.eval_batch_size, shuffle=False)
    test_loader = DataLoader(test_dataset, batch_size=args.eval_batch_size, shuffle=False)

    device = "mps" if torch.backends.mps.is_available() and not args.cpu else "cpu"
    model = ListwiseTransformerRanker(config).to(device)
    initial_checkpoint_payload: dict[str, Any] | None = None
    if args.initial_checkpoint:
        initial_checkpoint_path = Path(args.initial_checkpoint).expanduser().resolve()
        initial_checkpoint_payload = torch.load(
            initial_checkpoint_path,
            map_location="cpu",
            weights_only=False,
        )
        if initial_checkpoint_payload.get("config") != asdict(config):
            raise ValueError("initial checkpoint model config does not match requested config")
        model.load_state_dict(initial_checkpoint_payload["model_state"], strict=True)
        model = model.to(device)
        print(f"initial_checkpoint={initial_checkpoint_path}", flush=True)
    anchor_model: ListwiseTransformerRanker | None = None
    if initial_checkpoint_payload is not None and args.checkpoint_anchor_weight > 0.0:
        anchor_model = copy.deepcopy(model).to(device).eval()
        for parameter in anchor_model.parameters():
            parameter.requires_grad_(False)
        print(
            f"checkpoint_anchor=true weight={args.checkpoint_anchor_weight}",
            flush=True,
        )
    if args.trainable_scope == "output-head":
        for parameter_name, parameter in model.named_parameters():
            parameter.requires_grad_(
                parameter_name.startswith(("output_norm", "output"))
            )
    parameter_count = model_parameter_count(model)
    trainable_parameter_count = sum(
        parameter.numel() for parameter in model.parameters() if parameter.requires_grad
    )
    print(
        f"architecture=char_listwise_transformer_v1 parameters={parameter_count} "
        f"trainable_parameters={trainable_parameter_count} "
        f"train_groups={len(train_groups)} extra_groups={len(extra_groups)} "
        f"valid_groups={len(valid_groups)} test_groups={len(test_groups)} device={device} "
        f"training_residual_scale={training_residual_scale}",
        flush=True,
    )
    optimizer = torch.optim.AdamW(
        (parameter for parameter in model.parameters() if parameter.requires_grad),
        lr=args.learning_rate,
        weight_decay=args.weight_decay,
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=max(1, args.epochs), eta_min=args.learning_rate * 0.1
    )

    best_key: tuple[float, ...] | None = None
    best_state: dict[str, torch.Tensor] | None = None
    best_epoch = 0
    top_checkpoints: list[dict[str, Any]] = []

    def maybe_save_top_checkpoint(
        epoch: int,
        selection_key: tuple[float, ...],
        state: dict[str, torch.Tensor],
    ) -> None:
        if args.checkpoint_top_k <= 0:
            return
        if (
            len(top_checkpoints) >= args.checkpoint_top_k
            and selection_key <= top_checkpoints[-1]["selection_key"]
        ):
            return
        path = output / f"top_checkpoint_epoch_{epoch:02d}.pt"
        torch.save(
            {
                "model_state": state,
                "config": asdict(config),
                "architecture": "char_listwise_transformer_v1",
                "epoch": epoch,
                "selection_key": list(selection_key),
                "initial_checkpoint": str(args.initial_checkpoint or ""),
            },
            path,
        )
        top_checkpoints.append(
            {
                "epoch": epoch,
                "path": str(path),
                "selection_key": selection_key,
            }
        )
        top_checkpoints.sort(key=lambda item: item["selection_key"], reverse=True)
        while len(top_checkpoints) > args.checkpoint_top_k:
            removed = top_checkpoints.pop()
            Path(removed["path"]).unlink(missing_ok=True)

    history: list[dict[str, Any]] = []
    gradient_records: list[dict[str, Any]] = []
    gradient_window_sum: torch.Tensor | None = None
    gradient_window_update_sum: torch.Tensor | None = None
    gradient_window_clip_ratio_sum: torch.Tensor | None = None
    gradient_window_count = 0
    global_step = 0
    last_improved_epoch = 0
    stopped_early = False
    initial_valid_metrics: dict[str, Any] | None = None
    if initial_checkpoint_payload is not None:
        initial_valid_metrics = ranking_metrics(
            model,
            valid_loader,
            device,
            residual_scale=args.evaluation_residual_scale,
        )
        initial_selection = initial_valid_metrics["cohorts"]["real_selection"]
        initial_policy = (
            initial_selection
            if int(initial_selection["groups"]) > 0
            else initial_valid_metrics
        )
        initial_harm_rate = float(initial_policy["harmed"]) / max(
            1, int(initial_policy["groups"])
        )
        initial_changed = max(1, int(initial_policy["changed"]))
        best_key = (
            1.0 if initial_harm_rate <= args.max_valid_harm_rate else 0.0,
            1.0 if float(initial_policy["net_lift"]) > 0 else 0.0,
            -float(initial_policy["harmed"]),
            float(initial_policy["net_lift"]),
            float(initial_policy["improved"]) / initial_changed,
            -float(initial_policy["mean_abs_residual"]),
        )
        best_state = {
            name: value.detach().cpu().clone()
            for name, value in model.state_dict().items()
        }
        best_epoch = 0
        torch.save(
            {
                "model_state": best_state,
                "config": asdict(config),
                "architecture": "char_listwise_transformer_v1",
                "best_epoch": best_epoch,
                "initial_checkpoint": str(args.initial_checkpoint),
            },
            output / "best_checkpoint.pt",
        )
        maybe_save_top_checkpoint(best_epoch, best_key, best_state)
    started = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
        model.train()
        if args.disable_training_dropout:
            for module in model.modules():
                if isinstance(module, nn.Dropout):
                    module.eval()
        epoch_loss = 0.0
        epoch_ranking_loss = 0.0
        epoch_no_harm_loss = 0.0
        epoch_anchor_loss = 0.0
        epoch_preservation_loss = 0.0
        epoch_protected_correct = 0
        epoch_no_harm_violations = 0
        epoch_groups = 0
        epoch_gradient_sum: torch.Tensor | None = None
        epoch_gradient_count = 0
        for batch_index, raw_batch in enumerate(train_loader, start=1):
            global_step += 1
            batch = move_batch(raw_batch, device)
            residual = model(
                batch["token_ids"],
                batch["token_types"],
                batch["numeric_features"],
                batch["candidate_mask"],
            )
            mask = batch["candidate_mask"]
            base_scores = batch["base_scores"].masked_fill(mask <= 0, -10_000.0)
            scaled_residual = residual * training_residual_scale
            final_scores = (base_scores + scaled_residual).masked_fill(
                mask <= 0,
                -10_000.0,
            )
            per_group_loss = nn.functional.cross_entropy(
                final_scores / args.loss_temperature,
                batch["target"],
                reduction="none",
            )
            difficulty_weight = 1.0 + batch["hard"] * (args.hard_weight - 1.0)
            source_weight = torch.where(
                batch["weak_article"] > 0.5,
                torch.full_like(batch["weak_article"], args.weak_article_weight),
                torch.ones_like(batch["weak_article"]),
            )
            group_weight = difficulty_weight * source_weight

            target_indices = batch["target"].unsqueeze(1)
            target_scores = final_scores.gather(1, target_indices).squeeze(1)
            competitor_scores = final_scores.clone()
            competitor_scores.scatter_(1, target_indices, -10_000.0)
            strongest_competitor = competitor_scores.max(dim=1).values
            student_margin = (target_scores - strongest_competitor) / args.loss_temperature
            baseline_correct = (base_scores.argmax(dim=1) == batch["target"]).float()
            protected_correct = baseline_correct
            required_margin = torch.full_like(student_margin, args.no_harm_margin)
            preservation_base_priority = 1.0 + batch["real_selection"] * (
                args.real_selection_preservation_weight - 1.0
            )
            preservation_priority = source_weight * preservation_base_priority
            anchor_loss = residual.new_zeros(())
            if anchor_model is not None:
                with torch.no_grad():
                    anchor_residual = anchor_model(
                        batch["token_ids"],
                        batch["token_types"],
                        batch["numeric_features"],
                        batch["candidate_mask"],
                    )
                    teacher_scores = (
                        base_scores + anchor_residual * training_residual_scale
                    ).masked_fill(mask <= 0, -10_000.0)
                    teacher_target_scores = teacher_scores.gather(
                        1,
                        target_indices,
                    ).squeeze(1)
                    teacher_competitor_scores = teacher_scores.clone()
                    teacher_competitor_scores.scatter_(1, target_indices, -10_000.0)
                    teacher_margin = (
                        teacher_target_scores - teacher_competitor_scores.max(dim=1).values
                    ) / args.loss_temperature
                    protected_correct = (
                        teacher_scores.argmax(dim=1) == batch["target"]
                    ).float()
                    required_margin = torch.clamp(
                        teacher_margin - args.teacher_margin_tolerance,
                        min=0.0,
                    )
                    teacher_probabilities = torch.softmax(
                        teacher_scores / args.loss_temperature,
                        dim=1,
                    )
                    teacher_log_probabilities = torch.log_softmax(
                        teacher_scores / args.loss_temperature,
                        dim=1,
                    )
                student_log_probabilities = torch.log_softmax(
                    final_scores / args.loss_temperature,
                    dim=1,
                )
                anchor_per_group = (
                    teacher_probabilities
                    * (teacher_log_probabilities - student_log_probabilities)
                ).sum(dim=1)
                anchor_loss = (
                    anchor_per_group * preservation_priority
                ).sum() / preservation_base_priority.sum().clamp(min=1.0)
            # LambdaLoss-style business weighting: changing a teacher-correct
            # decision into an error has a much larger utility delta than an
            # ordinary missed improvement.  Keep weak-source weights absolute;
            # do not divide by group_weight, which would cancel them.
            business_cost = torch.where(
                protected_correct > 0.5,
                torch.full_like(protected_correct, args.harm_cost),
                torch.full_like(protected_correct, args.improvement_gain),
            )
            real_business_priority = 1.0 + batch["real_selection"] * (
                args.real_selection_business_weight - 1.0
            )
            ranking_loss = (
                per_group_loss
                * group_weight
                * business_cost
                * real_business_priority
            ).sum() / (
                difficulty_weight * business_cost * real_business_priority
            ).sum().clamp(min=1.0)
            margin_erosion = nn.functional.relu(required_margin - student_margin)
            no_harm_penalty = nn.functional.smooth_l1_loss(
                margin_erosion,
                torch.zeros_like(margin_erosion),
                reduction="none",
            )
            no_harm_loss = (
                no_harm_penalty * protected_correct * preservation_priority
            ).sum() / (
                protected_correct * preservation_base_priority
            ).sum().clamp(min=1.0)

            easy_mask = (
                (1.0 - batch["hard"]).unsqueeze(1)
                * mask
            )
            preservation = (
                scaled_residual.square()
                * easy_mask
                * source_weight.unsqueeze(1)
            ).sum() / easy_mask.sum().clamp(min=1.0)
            loss = (
                ranking_loss
                + args.no_harm_weight * no_harm_loss
                + args.checkpoint_anchor_weight * anchor_loss
                + args.easy_residual_penalty * preservation
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            should_log_gradient = args.gradient_log_interval > 0 and (
                global_step == 1
                or global_step % args.gradient_log_interval == 0
                or batch_index == len(train_loader)
            )
            grouped_gradient_norms = (
                gradient_group_norms(model) if should_log_gradient else {}
            )
            preclip_norm = nn.utils.clip_grad_norm_(
                model.parameters(),
                args.gradient_clip,
                error_if_nonfinite=True,
            )
            detached_preclip = preclip_norm.detach()
            gradient_window_sum = (
                detached_preclip
                if gradient_window_sum is None
                else gradient_window_sum + detached_preclip
            )
            gradient_window_count += 1
            epoch_gradient_sum = (
                detached_preclip
                if epoch_gradient_sum is None
                else epoch_gradient_sum + detached_preclip
            )
            epoch_gradient_count += 1
            learning_rate = float(optimizer.param_groups[0]["lr"])
            effective_update_tensor = (
                torch.clamp(detached_preclip, max=float(args.gradient_clip))
                * learning_rate
            )
            clip_ratio_tensor = torch.clamp(
                float(args.gradient_clip) / detached_preclip.clamp(min=1e-12),
                max=1.0,
            )
            gradient_window_update_sum = (
                effective_update_tensor
                if gradient_window_update_sum is None
                else gradient_window_update_sum + effective_update_tensor
            )
            gradient_window_clip_ratio_sum = (
                clip_ratio_tensor
                if gradient_window_clip_ratio_sum is None
                else gradient_window_clip_ratio_sum + clip_ratio_tensor
            )
            if should_log_gradient:
                instant_total_preclip = float(detached_preclip.item())
                total_preclip = float(
                    (gradient_window_sum / max(1, gradient_window_count)).item()
                )
                epoch_mean_total_preclip = float(
                    (epoch_gradient_sum / max(1, epoch_gradient_count)).item()
                )
                effective_update_norm = float(
                    (
                        gradient_window_update_sum
                        / max(1, gradient_window_count)
                    ).item()
                )
                mean_clip_ratio = float(
                    (
                        gradient_window_clip_ratio_sum
                        / max(1, gradient_window_count)
                    ).item()
                )
                gradient_records.append(
                    {
                        "epoch": epoch,
                        "global_step": global_step,
                        "loss": float(loss.item()),
                        "ranking_loss": float(ranking_loss.item()),
                        "no_harm_loss": float(no_harm_loss.item()),
                        "anchor_loss": float(anchor_loss.item()),
                        "preservation_loss": float(preservation.item()),
                        "business_cost_mean": float(business_cost.mean().item()),
                        "baseline_correct_fraction": float(baseline_correct.mean().item()),
                        "protected_correct_fraction": float(protected_correct.mean().item()),
                        "no_harm_violation_fraction": float(
                            ((margin_erosion > 0.0).float() * protected_correct).mean().item()
                        ),
                        "learning_rate": learning_rate,
                        "total_preclip": total_preclip,
                        "epoch_mean_total_preclip": epoch_mean_total_preclip,
                        "instant_total_preclip": instant_total_preclip,
                        "clip_threshold": float(args.gradient_clip),
                        "clip_ratio": min(
                            1.0,
                            float(args.gradient_clip) / max(instant_total_preclip, 1e-12),
                        ),
                        "effective_update_norm": effective_update_norm,
                        "mean_clip_ratio": mean_clip_ratio,
                        "hard_fraction": float(batch["hard"].mean().item()),
                        "weak_article_fraction": float(
                            batch["weak_article"].mean().item()
                        ),
                        **grouped_gradient_norms,
                    }
                )
                gradient_window_sum = None
                gradient_window_update_sum = None
                gradient_window_clip_ratio_sum = None
                gradient_window_count = 0
                live_history_path, live_svg_path = write_gradient_artifacts(
                    output,
                    gradient_records,
                    args.gradient_clip,
                    total_epochs=args.epochs,
                    dashboard=gradient_dashboard,
                )
                print(
                    f"gradient_live step={global_step} mean={total_preclip:.6f} "
                    f"instant={instant_total_preclip:.6f} "
                    f"plot={live_svg_path} history={live_history_path}",
                    flush=True,
                )
            optimizer.step()
            batch_groups = batch["target"].numel()
            epoch_loss += float(loss.item()) * batch_groups
            epoch_ranking_loss += float(ranking_loss.item()) * batch_groups
            epoch_no_harm_loss += float(no_harm_loss.item()) * batch_groups
            epoch_anchor_loss += float(anchor_loss.item()) * batch_groups
            epoch_preservation_loss += float(preservation.item()) * batch_groups
            epoch_protected_correct += int(protected_correct.sum().item())
            epoch_no_harm_violations += int(
                (((margin_erosion > 0.0).float() * protected_correct).sum()).item()
            )
            epoch_groups += batch_groups
        scheduler.step()

        valid_metrics = ranking_metrics(
            model,
            valid_loader,
            device,
            residual_scale=args.evaluation_residual_scale,
        )
        row = {
            "epoch": epoch,
            "train_loss": epoch_loss / max(epoch_groups, 1),
            "train_ranking_loss": epoch_ranking_loss / max(epoch_groups, 1),
            "train_no_harm_loss": epoch_no_harm_loss / max(epoch_groups, 1),
            "train_anchor_loss": epoch_anchor_loss / max(epoch_groups, 1),
            "train_preservation_loss": epoch_preservation_loss / max(epoch_groups, 1),
            "train_no_harm_violation_rate": epoch_no_harm_violations
            / max(epoch_protected_correct, 1),
            "valid": valid_metrics,
            "learning_rate": optimizer.param_groups[0]["lr"],
        }
        history.append(row)
        selection_metrics = valid_metrics["cohorts"]["real_selection"]
        policy_metrics = (
            selection_metrics if int(selection_metrics["groups"]) > 0 else valid_metrics
        )
        row["checkpoint_policy_cohort"] = (
            "real_selection" if int(selection_metrics["groups"]) > 0 else "overall"
        )
        print(
            f"epoch={epoch} loss={row['train_loss']:.5f} "
            f"valid_base={valid_metrics['baseline_top1']:.4f} "
            f"valid_combined={valid_metrics['combined_top1']:.4f} "
            f"selection_base={selection_metrics['baseline_top1']:.4f} "
            f"selection_combined={selection_metrics['combined_top1']:.4f} "
            f"selection_improved={selection_metrics['improved']} "
            f"selection_harmed={selection_metrics['harmed']} "
            f"selection_net={selection_metrics['net_lift']}",
            flush=True,
        )
        harm_rate = float(policy_metrics["harmed"]) / max(1, int(policy_metrics["groups"]))
        safe = harm_rate <= args.max_valid_harm_rate
        positive_lift = float(policy_metrics["net_lift"]) > 0
        changed = max(1, int(policy_metrics["changed"]))
        correction_precision = float(policy_metrics["improved"]) / changed
        # Conservative deep-training selection: safety and positive real-user
        # lift remain mandatory.  A later epoch may replace an earlier safe
        # checkpoint only when it reduces harm or raises net lift.
        key = (
            1.0 if safe else 0.0,
            1.0 if positive_lift else 0.0,
            -float(policy_metrics["harmed"]),
            float(policy_metrics["net_lift"]),
            correction_precision,
            -float(policy_metrics["mean_abs_residual"]),
        )
        current_state = {
            name: value.detach().cpu().clone()
            for name, value in model.state_dict().items()
        }
        maybe_save_top_checkpoint(epoch, key, current_state)
        should_update = best_key is None or key > best_key
        if should_update:
            best_key = key
            best_epoch = epoch
            last_improved_epoch = epoch
            best_state = current_state
            torch.save(
                {
                    "model_state": best_state,
                    "config": asdict(config),
                    "architecture": "char_listwise_transformer_v1",
                    "best_epoch": best_epoch,
                    "initial_checkpoint": str(args.initial_checkpoint or ""),
                },
                output / "best_checkpoint.pt",
            )
        write_json(
            output / "epoch_history.json",
            {
                "initial_valid": initial_valid_metrics,
                "history": history,
                "best_epoch": best_epoch,
                "top_checkpoints": [
                    {
                        "epoch": int(item["epoch"]),
                        "path": str(item["path"]),
                        "selection_key": list(item["selection_key"]),
                    }
                    for item in top_checkpoints
                ],
                "loss_contract": {
                    "training_residual_scale": training_residual_scale,
                    "evaluation_residual_scale": args.evaluation_residual_scale,
                    "harm_cost": args.harm_cost,
                    "improvement_gain": args.improvement_gain,
                    "no_harm_weight": args.no_harm_weight,
                    "checkpoint_anchor_weight": args.checkpoint_anchor_weight,
                },
            },
        )
        gradient_history_path, gradient_svg_path = write_gradient_artifacts(
            output,
            gradient_records,
            args.gradient_clip,
            total_epochs=args.epochs,
            dashboard=gradient_dashboard,
        )
        latest_gradient = gradient_records[-1] if gradient_records else {}
        print(
            f"gradient_plot={gradient_svg_path} records={len(gradient_records)} "
            f"latest_total={float(latest_gradient.get('total_preclip', 0.0)):.6f}",
            flush=True,
        )
        if (
            args.early_stopping_patience > 0
            and epoch >= args.minimum_epochs
            and epoch - last_improved_epoch >= args.early_stopping_patience
        ):
            stopped_early = True
            print(
                f"early_stop epoch={epoch} best_epoch={best_epoch} "
                f"patience={args.early_stopping_patience}",
                flush=True,
            )
            break
        if args.stop_after_epoch > 0 and epoch >= args.stop_after_epoch:
            print(
                f"requested_stop epoch={epoch} best_epoch={best_epoch}",
                flush=True,
            )
            break

    if best_state is None:
        raise RuntimeError("training produced no checkpoint")
    model.load_state_dict(best_state)
    model = model.to(device).eval()
    gradient_history_path, gradient_svg_path = write_gradient_artifacts(
        output,
        gradient_records,
        args.gradient_clip,
        total_epochs=args.epochs,
        dashboard=gradient_dashboard,
    )
    gradient_totals = [float(record["total_preclip"]) for record in gradient_records]
    train_eval_loader = DataLoader(train_dataset, batch_size=args.eval_batch_size, shuffle=False)
    metrics = {
        "architecture": "char_listwise_transformer_v1",
        "parameter_count": parameter_count,
        "trainable_parameter_count": trainable_parameter_count,
        "model_size_millions": parameter_count / 1_000_000.0,
        "config": asdict(config),
        "best_epoch": best_epoch,
        "configured_epochs": args.epochs,
        "completed_epochs": len(history),
        "minimum_epochs": args.minimum_epochs,
        "early_stopping_patience": args.early_stopping_patience,
        "stopped_early": stopped_early,
        "stop_after_epoch": args.stop_after_epoch,
        "initial_checkpoint": str(args.initial_checkpoint or ""),
        "initial_checkpoint_best_epoch": int(
            initial_checkpoint_payload.get("best_epoch", 0)
            if initial_checkpoint_payload is not None
            else 0
        ),
        "initial_valid": initial_valid_metrics,
        "train_groups": len(train_groups),
        "extra_groups": len(extra_groups),
        "valid_groups": len(valid_groups),
        "test_groups": len(test_groups),
        "training_residual_scale": training_residual_scale,
        "evaluation_residual_scale": args.evaluation_residual_scale,
        "real_selection_batch_fraction": args.real_selection_batch_fraction,
        "harm_cost": args.harm_cost,
        "improvement_gain": args.improvement_gain,
        "real_selection_business_weight": args.real_selection_business_weight,
        "real_selection_preservation_weight": args.real_selection_preservation_weight,
        "no_harm_weight": args.no_harm_weight,
        "no_harm_margin": args.no_harm_margin,
        "teacher_margin_tolerance": args.teacher_margin_tolerance,
        "checkpoint_anchor_weight": args.checkpoint_anchor_weight,
        "disable_training_dropout": args.disable_training_dropout,
        "trainable_scope": args.trainable_scope,
        "max_valid_harm_rate": args.max_valid_harm_rate,
        "validation_policy_cohort": "real_selection",
        "weak_article_weight": args.weak_article_weight,
        "selection_policy": "best_safe_real_selection_checkpoint",
        "top_checkpoints": [
            {
                "epoch": int(item["epoch"]),
                "path": str(item["path"]),
                "selection_key": list(item["selection_key"]),
            }
            for item in top_checkpoints
        ],
        "gradient_diagnostics": {
            "log_interval": args.gradient_log_interval,
            "records": len(gradient_records),
            "history": str(gradient_history_path),
            "plot": str(gradient_svg_path),
            "live_window": str(gradient_live_path),
            "minimum_total_preclip": min(gradient_totals) if gradient_totals else 0.0,
            "maximum_total_preclip": max(gradient_totals) if gradient_totals else 0.0,
            "last_total_preclip": gradient_totals[-1] if gradient_totals else 0.0,
            "all_finite": all(math.isfinite(value) for value in gradient_totals),
        },
        "train": ranking_metrics(model, train_eval_loader, device, args.evaluation_residual_scale),
        "valid": ranking_metrics(model, valid_loader, device, args.evaluation_residual_scale),
        "test": ranking_metrics(model, test_loader, device, args.evaluation_residual_scale) if test_groups else None,
        "history": history,
        "elapsed_seconds": time.perf_counter() - started,
    }
    checkpoint_path = output / "listwise_checkpoint.pt"
    torch.save(
        {
            "model_state": best_state,
            "config": asdict(config),
            "architecture": "char_listwise_transformer_v1",
            "best_epoch": best_epoch,
            "metrics": metrics,
        },
        checkpoint_path,
    )
    write_json(output / "metrics.json", metrics)
    write_json(output / "train_config.json", vars(args))
    print(json.dumps({key: metrics[key] for key in ("best_epoch", "train", "valid", "test")}, ensure_ascii=False, indent=2))

    if not args.skip_export:
        package_path = export_coreml(model, output)
        print(f"saved_model={package_path}")
    print(f"saved_metrics={output / 'metrics.json'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--test")
    parser.add_argument("--extra-train", action="append", default=[])
    parser.add_argument("--max-extra-groups", type=int, default=5_000)
    parser.add_argument("--output", required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--minimum-epochs", type=int, default=1)
    parser.add_argument("--early-stopping-patience", type=int, default=0)
    parser.add_argument("--stop-after-epoch", type=int, default=0)
    parser.add_argument("--initial-checkpoint")
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--eval-batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--gradient-clip", type=float, default=1.0)
    parser.add_argument("--gradient-log-interval", type=int, default=100)
    parser.add_argument(
        "--gradient-dashboard-dir",
        default=str(PROJECT_ROOT / "artifacts/training/gradient_live_dashboard"),
    )
    parser.add_argument(
        "--show-gradient-window",
        dest="show_gradient_window",
        action="store_true",
        default=True,
    )
    parser.add_argument(
        "--no-gradient-window",
        dest="show_gradient_window",
        action="store_false",
    )
    parser.add_argument("--loss-temperature", type=float, default=20.0)
    parser.add_argument("--hard-weight", type=float, default=8.0)
    parser.add_argument("--weak-article-weight", type=float, default=0.1)
    parser.add_argument("--real-selection-batch-fraction", type=float, default=0.25)
    parser.add_argument("--harm-cost", type=float, default=8.0)
    parser.add_argument("--improvement-gain", type=float, default=1.0)
    parser.add_argument("--real-selection-business-weight", type=float, default=2.0)
    parser.add_argument("--real-selection-preservation-weight", type=float, default=4.0)
    parser.add_argument("--easy-residual-penalty", type=float, default=1e-4)
    parser.add_argument("--training-residual-scale", type=float)
    parser.add_argument("--evaluation-residual-scale", type=float, default=0.5)
    parser.add_argument("--no-harm-weight", type=float, default=8.0)
    parser.add_argument("--no-harm-margin", type=float, default=0.25)
    parser.add_argument("--teacher-margin-tolerance", type=float, default=0.0)
    parser.add_argument("--checkpoint-anchor-weight", type=float, default=4.0)
    parser.add_argument("--checkpoint-top-k", type=int, default=3)
    parser.add_argument("--disable-training-dropout", action="store_true")
    parser.add_argument(
        "--trainable-scope",
        choices=("all", "output-head"),
        default="all",
    )
    parser.add_argument("--max-valid-harm-rate", type=float, default=0.01)
    parser.add_argument("--mixed-augment-probability", type=float, default=0.15)
    parser.add_argument("--residual-bound", type=float, default=120.0)
    parser.add_argument("--vocab-size", type=int, default=16_384)
    parser.add_argument("--sequence-length", type=int, default=48)
    parser.add_argument("--max-candidates", type=int, default=20)
    parser.add_argument("--model-dimension", type=int, default=256)
    parser.add_argument("--attention-heads", type=int, default=8)
    parser.add_argument("--feedforward-dimension", type=int, default=768)
    parser.add_argument("--sequence-layers", type=int, default=6)
    parser.add_argument("--set-layers", type=int, default=3)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--cpu", action="store_true")
    parser.add_argument("--skip-export", action="store_true")
    return parser


if __name__ == "__main__":
    raise SystemExit(train(build_parser().parse_args()))
