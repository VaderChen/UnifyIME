#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import multiprocessing
import threading
import time
from collections import defaultdict

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import log_loss

try:
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader, TensorDataset
except Exception:
    torch = None
    nn = None
    DataLoader = None
    TensorDataset = None


EXPECTED_DIM = 88
MODEL_ARCHITECTURE = "dense_mlp_v2"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHRASE_MAP_PATH = os.path.join(ROOT, "Resources", "phrase_map.tsv")
COMMON_MAP_PATH = os.path.join(ROOT, "Resources", "common_map.tsv")
PHRASE_SURFACE_WEIGHTS = {}
READING_CANDIDATE_COUNTS = {}
READING_BEST_LENGTHS = {}
BUILTIN_READING_SURFACES = defaultdict(set)
BOPOMOFO_KEY_ROWS = [
    list("1234567890-"),
    list("qwertyuiop"),
    list("asdfghjkl;"),
    list("zxcvbnm,./"),
]
BOPOMOFO_KEY_TO_SYMBOL = {
    "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
    "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
    "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
    "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
    "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
    "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
    "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
    "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
    "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
    "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
    "-": "ㄦ",
    "3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙",
}
SYMBOL_TO_NEIGHBORS = {}


def load_phrase_context_stats():
    if not os.path.exists(PHRASE_MAP_PATH):
        return
    with open(PHRASE_MAP_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            reading = parts[0]
            phrase = parts[1]
            if not reading or not phrase:
                continue
            weight = 1.0
            if len(parts) >= 3:
                try:
                    weight = max(float(parts[2]), 1.0)
                except ValueError:
                    weight = 1.0
            PHRASE_SURFACE_WEIGHTS[phrase] = max(PHRASE_SURFACE_WEIGHTS.get(phrase, 0.0), weight)
            READING_CANDIDATE_COUNTS[reading] = READING_CANDIDATE_COUNTS.get(reading, 0) + 1
            READING_BEST_LENGTHS[reading] = max(READING_BEST_LENGTHS.get(reading, 0), len(phrase))
            BUILTIN_READING_SURFACES[reading].add(phrase)


def load_common_map_stats():
    if not os.path.exists(COMMON_MAP_PATH):
        return
    with open(COMMON_MAP_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) != 2:
                continue
            reading, surface = parts
            if reading and surface:
                BUILTIN_READING_SURFACES[reading].add(surface)


load_phrase_context_stats()
load_common_map_stats()


def build_symbol_neighbors():
    positions = {}
    for row_index, row in enumerate(BOPOMOFO_KEY_ROWS):
        for col_index, key in enumerate(row):
            positions[key] = (row_index, col_index)

    for key, symbol in BOPOMOFO_KEY_TO_SYMBOL.items():
        row_index, col_index = positions[key]
        neighbors = []
        for delta_row in (-1, 0, 1):
            for delta_col in (-1, 0, 1):
                if delta_row == 0 and delta_col == 0:
                    continue
                other_pos = (row_index + delta_row, col_index + delta_col)
                other_key = next((candidate for candidate, pos in positions.items() if pos == other_pos), None)
                if other_key is None:
                    continue
                other_symbol = BOPOMOFO_KEY_TO_SYMBOL.get(other_key)
                if other_symbol and other_symbol not in neighbors:
                    neighbors.append(other_symbol)
        SYMBOL_TO_NEIGHBORS[symbol] = neighbors


build_symbol_neighbors()


def resolve_backend(requested_backend: str) -> str:
    if requested_backend != "mlp":
        return requested_backend
    try:
        if torch is None:
            raise RuntimeError("torch unavailable")
        return "mlp"
    except Exception:
        print("backend=mlp requested but torch is unavailable; falling back to backend=tree", flush=True)
        return "tree"


def is_tone_mark(ch: str) -> bool:
    return ch in "ˇˋˊ˙"


def normalize_token(text: str) -> str:
    return "".join(ch for ch in text if not is_tone_mark(ch))


def is_han(ch: str) -> bool:
    if not ch:
        return False
    code = ord(ch)
    return 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF


def script_class(text: str) -> int:
    if not text:
        return 4
    has_han = has_latin = has_kana = has_other = False
    for ch in text:
        code = ord(ch)
        if is_han(ch):
            has_han = True
        elif ch.isascii() and ch.isalpha():
            has_latin = True
        elif 0x3040 <= code <= 0x309F or 0x30A0 <= code <= 0x30FF:
            has_kana = True
        else:
            has_other = True
    active = sum([has_han, has_latin, has_kana, has_other])
    if active > 1:
        return 3
    if has_han:
        return 0
    if has_latin:
        return 1
    if has_kana:
        return 2
    return 4


def one_hot(index: int, count: int):
    return [1.0 if i == index else 0.0 for i in range(count)]


def language_bucket(language_id: str) -> int:
    if language_id == "zh-Hant":
        return 0
    if language_id == "en":
        return 1
    if language_id == "ja":
        return 2
    return 3


def aggregate_context(values):
    recent = values[-3:]
    total_chars = sum(len(v) for v in recent)
    han_count = sum(sum(1 for ch in v if is_han(ch)) for v in recent)
    mixed_count = sum(1 for v in recent if script_class(v) == 3)
    return [float(len(recent)), float(total_chars), float(han_count), float(mixed_count)]


def aggregate_following(tokens):
    recent = tokens[:3]
    total_chars = sum(len(v) for v in recent)
    zh_count = sum(1 for v in recent if script_class(v) == 0)
    latin_count = sum(1 for v in recent if script_class(v) == 1)
    return [float(len(recent)), float(total_chars), float(zh_count), float(latin_count)]


def stable_hash_feature(text):
    if not text:
        return 0.0
    value = 5381
    for ch in text:
        value = ((value << 5) + value + ord(ch)) & 0xFFFFFFFFFFFFFFFF
    return float(value % 4096) / 4095.0


def stable_hash_bucket(text, count):
    if not text or count <= 0:
        return -1
    value = 5381
    for ch in text:
        value = ((value << 5) + value + ord(ch)) & 0xFFFFFFFFFFFFFFFF
    return int(value % count)


def han_ratio(text):
    if not text:
        return 0.0
    count = sum(1 for ch in text if is_han(ch))
    return float(count) / max(len(text), 1)


def char_overlap_ratio(lhs, rhs):
    if not lhs or not rhs:
        return 0.0
    left = set(lhs)
    right = set(rhs)
    overlap = len(left.intersection(right))
    return float(overlap) / max(min(len(left), len(right)), 1)


def boundary_match_score(prev, candidate, next_token):
    score = 0.0
    if prev and candidate and prev[-1] == candidate[0]:
        score += 0.5
    if candidate and next_token and candidate[-1] == next_token[0]:
        score += 0.5
    return score


def phrase_log_weight(surface):
    weight = PHRASE_SURFACE_WEIGHTS.get(surface, 0.0)
    if weight <= 0:
        return 0.0
    return math.log1p(weight) / 10.0


def normalized_reading_count(reading):
    if not reading:
        return 0.0
    return min(math.log1p(float(READING_CANDIDATE_COUNTS.get(reading, 0))) / 6.0, 1.0)


def normalized_best_phrase_length(reading):
    if not reading:
        return 0.0
    return min(float(READING_BEST_LENGTHS.get(reading, 0)) / 8.0, 1.0)


def encode_feature(obj):
    language_id = obj["language_id"]
    candidate_surface = obj["candidate_surface"]
    candidate_token = obj["candidate_reading_or_token"]
    combined = obj["combined_token"]
    focused = obj["focused_token"]
    all_tokens = obj["all_tokens"]
    preceding = obj["preceding_values"]
    following = obj["following_tokens"]
    script = script_class(candidate_surface)

    features = [
        # Base/provider rank already lives in the heuristic score. The NN is
        # trained as a residual correctness signal instead of a rank copier.
        0.0,
        0.0,
        float(obj["span_length"]),
        float(len(candidate_surface)),
        float(len(candidate_token)),
        float(len(preceding)),
        float(len(following)),
        1.0 if candidate_surface == combined else 0.0,
        1.0 if language_id == obj["language_id"] else 0.0,
        1.0 if len(candidate_surface) > 1 else 0.0,
        1.0 if any(is_tone_mark(ch) for ch in combined) else 0.0,
        1.0 if normalize_token(candidate_token) == normalize_token(combined) else 0.0,
        float(obj["span_start"]),
        float(len(focused)),
        float(len(all_tokens)),
    ]
    features.extend(one_hot(script, 5))
    features.extend(one_hot(language_bucket(language_id), 4))
    features.extend(aggregate_context(preceding))
    features.extend(aggregate_following(following))
    prev1 = preceding[-1] if preceding else ""
    prev2 = preceding[-2] if len(preceding) >= 2 else ""
    next1 = following[0] if following else ""
    next2 = following[1] if len(following) >= 2 else ""
    prev_tail = prev1[-1:] if prev1 else ""
    combined_plus_next = combined + next1
    features.extend([
        float(len(prev1)),
        han_ratio(prev1),
        stable_hash_feature(prev1),
        stable_hash_feature(prev2),
        float(len(next1)),
        han_ratio(next1),
        stable_hash_feature(next1),
        stable_hash_feature(next2),
        char_overlap_ratio(prev1, candidate_surface),
        char_overlap_ratio(candidate_surface, next1),
        stable_hash_feature(prev1 + "|" + focused),
        stable_hash_feature(focused + "|" + next1),
        stable_hash_feature("|".join(preceding[-3:])),
        stable_hash_feature("|".join(following[:3])),
        float(len(preceding) - len(following)),
        boundary_match_score(prev1, candidate_surface, next1),
        phrase_log_weight(candidate_surface),
        phrase_log_weight(prev1 + candidate_surface),
        phrase_log_weight(prev_tail + candidate_surface),
        normalized_reading_count(combined),
        normalized_best_phrase_length(combined),
        normalized_reading_count(combined_plus_next),
        normalized_best_phrase_length(combined_plus_next),
        1.0 if (prev1 + candidate_surface) in PHRASE_SURFACE_WEIGHTS else 0.0,
    ])
    identity_signatures = [
        candidate_surface,
        prev1 + "|" + candidate_surface,
        candidate_surface + "|" + next1,
        prev1 + "|" + candidate_surface + "|" + next1,
    ]
    for signature in identity_signatures:
        features.extend(one_hot(stable_hash_bucket(signature, 8), 8))

    if len(features) < EXPECTED_DIM:
        features.extend([0.0] * (EXPECTED_DIM - len(features)))
    if len(features) > EXPECTED_DIM:
        features = features[:EXPECTED_DIM]
    return features


def load_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def count_jsonl_rows(path):
    count = 0
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                count += 1
    return count


def load_jsonl_with_progress(path, progress_callback=None, chunk_size=20000):
    rows = []
    total = count_jsonl_rows(path)
    loaded = 0
    if progress_callback is not None:
        progress_callback(loaded, total)
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
            loaded += 1
            if progress_callback is not None and (loaded % chunk_size == 0 or loaded == total):
                progress_callback(loaded, total)
    return rows


def build_arrays(rows):
    x = np.asarray([encode_feature(r) for r in rows], dtype=np.float32)
    y = np.asarray([int(r["label"] > 0) for r in rows], dtype=np.int64)
    w = np.asarray([float(r.get("sample_weight", 1.0)) for r in rows], dtype=np.float32)
    return x, y, w


def encode_rows_chunk(rows):
    features = []
    labels = []
    weights = []
    for row in rows:
        features.append(encode_feature(row))
        labels.append(int(row["label"] > 0))
        weights.append(float(row.get("sample_weight", 1.0)))
    return (
        np.asarray(features, dtype=np.float32),
        np.asarray(labels, dtype=np.int64),
        np.asarray(weights, dtype=np.float32),
    )


def build_arrays_with_progress(rows, progress_callback=None, chunk_size=20000):
    total = len(rows)
    if total == 0:
        if progress_callback is not None:
            progress_callback(0, 0)
        return (
            np.empty((0, EXPECTED_DIM), dtype=np.float32),
            np.empty((0,), dtype=np.int64),
            np.empty((0,), dtype=np.float32),
        )

    chunk_size = max(1, int(chunk_size))
    worker_count = max(1, int(os.environ.get("FASTCHIME_TRAIN_WORKERS", str(max(1, min(8, (os.cpu_count() or 1) - 1))))))
    use_parallel = worker_count > 1 and total >= chunk_size * 2
    feature_chunks = []
    label_chunks = []
    weight_chunks = []
    if progress_callback is not None:
        progress_callback(0, total)

    if use_parallel:
        row_chunks = [rows[start:start + chunk_size] for start in range(0, total, chunk_size)]
        processed = 0
        with multiprocessing.get_context("spawn").Pool(processes=worker_count) as pool:
            for x_chunk, y_chunk, w_chunk in pool.imap(encode_rows_chunk, row_chunks, chunksize=1):
                feature_chunks.append(x_chunk)
                label_chunks.append(y_chunk)
                weight_chunks.append(w_chunk)
                processed += len(y_chunk)
                if progress_callback is not None:
                    progress_callback(processed, total)
    else:
        for start in range(0, total, chunk_size):
            chunk = rows[start:start + chunk_size]
            x_chunk, y_chunk, w_chunk = encode_rows_chunk(chunk)
            feature_chunks.append(x_chunk)
            label_chunks.append(y_chunk)
            weight_chunks.append(w_chunk)
            if progress_callback is not None:
                progress_callback(min(start + len(chunk), total), total)

    return (
        np.concatenate(feature_chunks, axis=0),
        np.concatenate(label_chunks, axis=0),
        np.concatenate(weight_chunks, axis=0),
    )


def file_fingerprint(path):
    stat = os.stat(path)
    return {
        "path": os.path.abspath(path),
        "size": int(stat.st_size),
        "mtime_ns": int(getattr(stat, "st_mtime_ns", int(stat.st_mtime * 1_000_000_000))),
    }


def feature_cache_key(split_name, source_path, args, preprocessing_kind):
    payload = {
        "split": split_name,
        "source": file_fingerprint(source_path),
        "expected_dim": EXPECTED_DIM,
        "preprocessing_kind": preprocessing_kind,
        "seed": int(args.seed),
        "pairwise_top_k": int(args.pairwise_top_k),
        "pairwise_boost": float(args.pairwise_boost),
        "neighbor_noise_weight": float(args.neighbor_noise_weight),
        "builtin_positive_boost": float(args.builtin_positive_boost),
        "builtin_negative_boost": float(args.builtin_negative_boost),
        "script_mtime_ns": int(getattr(os.stat(__file__), "st_mtime_ns", int(os.stat(__file__).st_mtime * 1_000_000_000))),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha1(encoded).hexdigest()[:16]


def cache_npz_path(cache_dir, split_name, key):
    return os.path.join(cache_dir, f"{split_name}.{key}.npz")


def load_cached_arrays(cache_path):
    data = np.load(cache_path)
    return data["x"], data["y"], data["w"]


def save_cached_arrays(cache_path, x, y, w):
    tmp_path = f"{cache_path}.tmp"
    with open(tmp_path, "wb") as handle:
        np.savez_compressed(handle, x=x, y=y, w=w)
    os.replace(tmp_path, cache_path)


def normalize_train_chunk_size(total_rows, requested_chunk_size):
    requested = int(requested_chunk_size or 0)
    if requested <= 0 or requested >= int(total_rows):
        return 0
    return requested


def train_chunk_cache_key(source_path, args, chunk_id):
    payload = {
        "source": file_fingerprint(source_path),
        "chunk_id": chunk_id,
        "seed": int(args.seed),
        "pairwise_top_k": int(args.pairwise_top_k),
        "pairwise_boost": float(args.pairwise_boost),
        "neighbor_noise_weight": float(args.neighbor_noise_weight),
        "builtin_positive_boost": float(args.builtin_positive_boost),
        "builtin_negative_boost": float(args.builtin_negative_boost),
        "script_mtime_ns": int(getattr(os.stat(__file__), "st_mtime_ns", int(os.stat(__file__).st_mtime * 1_000_000_000))),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha1(encoded).hexdigest()[:16]


class TrainChunkSampler:
    def __init__(self, total_rows, chunk_size, seed, sampling_weights=None):
        self.total_rows = int(total_rows)
        self.chunk_size = normalize_train_chunk_size(total_rows, chunk_size)
        self.seed = int(seed)
        self.sampling_weights = None
        if sampling_weights is not None and len(sampling_weights) == self.total_rows:
            weights = np.asarray(sampling_weights, dtype=np.float64)
            weights = np.maximum(weights, 1e-9)
            if float(weights.sum()) > 0:
                self.sampling_weights = weights
        self.last_cycle = None
        self.last_order = None
        self.cycle_size = 1 if self.chunk_size <= 0 else max(1, math.ceil(self.total_rows / self.chunk_size))

    def is_enabled(self):
        return self.chunk_size > 0 and self.total_rows > self.chunk_size

    def chunk_length_for_epoch(self, epoch):
        if not self.is_enabled():
            return self.total_rows
        position = (int(epoch) - 1) % self.cycle_size
        start = position * self.chunk_size
        end = min(start + self.chunk_size, self.total_rows)
        return max(0, end - start)

    def total_batches_for_epochs(self, epochs, batch_size):
        safe_batch = max(1, int(batch_size))
        return sum(max(1, math.ceil(self.chunk_length_for_epoch(epoch) / safe_batch)) for epoch in range(1, int(epochs) + 1))

    def sample(self, rows, epoch):
        if not self.is_enabled():
            return rows, {
                "chunk_id": "full",
                "cycle": 1,
                "cycle_size": 1,
                "position": 1,
                "start": 0,
                "end": len(rows),
                "length": len(rows),
            }

        cycle = (int(epoch) - 1) // self.cycle_size
        position = (int(epoch) - 1) % self.cycle_size
        if self.last_cycle != cycle or self.last_order is None:
            rng = np.random.default_rng(self.seed + cycle)
            if self.sampling_weights is None:
                self.last_order = rng.permutation(self.total_rows)
            else:
                keys = rng.random(self.total_rows) ** (1.0 / self.sampling_weights)
                self.last_order = np.argsort(-keys)
            self.last_cycle = cycle

        start = position * self.chunk_size
        end = min(start + self.chunk_size, self.total_rows)
        indexes = self.last_order[start:end].tolist()
        chunk_rows = [rows[idx] for idx in indexes]
        return chunk_rows, {
            "chunk_id": f"c{cycle + 1:03d}_p{position + 1:03d}_of_{self.cycle_size:03d}",
            "cycle": cycle + 1,
            "cycle_size": self.cycle_size,
            "position": position + 1,
            "start": start,
            "end": end,
            "length": len(chunk_rows),
        }


def rows_cache_path(cache_dir, split_name, key):
    return os.path.join(cache_dir, f"{split_name}.{key}.rows.jsonl")


def save_rows_jsonl(path, rows):
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            f.write("\n")
    os.replace(tmp_path, path)


def load_rows_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def rows_cache_key(split_name, source_path, args, pipeline_tag):
    payload = {
        "split": split_name,
        "source": file_fingerprint(source_path),
        "pipeline_tag": pipeline_tag,
        "seed": int(args.seed),
        "pairwise_top_k": int(args.pairwise_top_k),
        "pairwise_boost": float(args.pairwise_boost),
        "neighbor_noise_weight": float(args.neighbor_noise_weight),
        "builtin_positive_boost": float(args.builtin_positive_boost),
        "builtin_negative_boost": float(args.builtin_negative_boost),
        "script_mtime_ns": int(getattr(os.stat(__file__), "st_mtime_ns", int(os.stat(__file__).st_mtime * 1_000_000_000))),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha1(encoded).hexdigest()[:16]


def build_sampling_weights(rows):
    if not rows:
        return np.empty((0,), dtype=np.float32)
    weights = np.asarray([max(float(row.get("sample_weight", 1.0)), 1e-6) for row in rows], dtype=np.float32)
    if float(weights.sum()) <= 0:
        return np.ones((len(rows),), dtype=np.float32)
    return weights


def prepare_rows_for_training(rows, seed):
    prepared = list(rows)
    if len(prepared) <= 1:
        return prepared
    rng = np.random.default_rng(seed)
    order = rng.permutation(len(prepared))
    return [prepared[index] for index in order]


def iter_group_rows(rows):
    if not rows:
        return
    previous_key = None
    monotonic = True
    for row in rows:
        key = (row["case_id"], row["step_id"])
        if previous_key is not None and key < previous_key:
            monotonic = False
            break
        previous_key = key

    iterable = rows if monotonic else sorted(rows, key=lambda item: (item["case_id"], item["step_id"]))
    current_key = None
    bucket = []
    for row in iterable:
        key = (row["case_id"], row["step_id"])
        if current_key is None:
            current_key = key
        if key != current_key:
            yield current_key, bucket
            current_key = key
            bucket = []
        bucket.append(row)
    if bucket:
        yield current_key, bucket


def group_rows(rows):
    return {key: group for key, group in iter_group_rows(rows)}


def apply_pairwise_hard_negative_boost(rows, top_k=3, boost=2.0):
    boosted = []
    for _, group in iter_group_rows(rows):
        positives = [dict(item) for item in group if item.get("label", 0) > 0]
        negatives = [dict(item) for item in group if item.get("label", 0) <= 0]
        boosted.extend(positives)
        boosted.extend(negatives)
        if not positives or not negatives or boost <= 1.0:
            continue

        positives.sort(key=lambda item: (item.get("base_rank", 999999), -float(item.get("sample_weight", 1.0))))
        negatives.sort(key=lambda item: (item.get("base_rank", 999999), -float(item.get("provider_score", -999999))))
        anchor = positives[0]

        for index, negative in enumerate(negatives[:top_k], start=1):
            pos_clone = dict(anchor)
            pos_clone["sample_id"] = f"{anchor['sample_id']}:pairpos{index}"
            pos_clone["sample_weight"] = float(anchor.get("sample_weight", 1.0)) * boost

            neg_clone = dict(negative)
            neg_clone["sample_id"] = f"{negative['sample_id']}:pairneg{index}"
            neg_clone["sample_weight"] = float(negative.get("sample_weight", 1.0)) * boost

            boosted.append(pos_clone)
            boosted.append(neg_clone)
    return boosted


def mutate_bopomofo_neighbor(text):
    if not text:
        return None
    chars = list(text)
    for index, ch in enumerate(chars):
        neighbors = SYMBOL_TO_NEIGHBORS.get(ch)
        if neighbors:
            mutated = list(chars)
            mutated[index] = neighbors[0]
            candidate = "".join(mutated)
            if candidate != text:
                return candidate
    return None


def apply_neighbor_key_noise(rows, weight_scale=0.35):
    if weight_scale <= 0:
        return list(rows)
    augmented = []
    for row in rows:
        augmented.append(row)
        noisy_combined = mutate_bopomofo_neighbor(row.get("combined_token", ""))
        noisy_focused = mutate_bopomofo_neighbor(row.get("focused_token", ""))
        if not noisy_combined and not noisy_focused:
            continue

        noisy = dict(row)
        noisy["sample_id"] = f"{row['sample_id']}:neighbor"
        noisy["combined_token"] = noisy_combined or row.get("combined_token", "")
        noisy["focused_token"] = noisy_focused or row.get("focused_token", "")
        noisy["all_tokens"] = [
            noisy["focused_token"] if token == row.get("focused_token", "") else mutate_bopomofo_neighbor(token) or token
            for token in row.get("all_tokens", [])
        ]
        noisy["following_tokens"] = [mutate_bopomofo_neighbor(token) or token for token in row.get("following_tokens", [])]
        noisy["sample_weight"] = float(row.get("sample_weight", 1.0)) * weight_scale
        tags = list(row.get("tags", []))
        if "neighbor_noise" not in tags:
            tags.append("neighbor_noise")
        noisy["tags"] = tags
        augmented.append(noisy)
    return augmented


def apply_builtin_lexicon_boost(rows, positive_boost=2.5, negative_boost=1.15):
    boosted = []
    for row in rows:
        updated = dict(row)
        reading = updated.get("combined_token", "")
        surface = updated.get("candidate_surface", "")
        builtin_surfaces = BUILTIN_READING_SURFACES.get(reading, set())
        if surface in builtin_surfaces:
            weight = float(updated.get("sample_weight", 1.0))
            if float(updated.get("label", 0.0)) > 0:
                updated["sample_weight"] = weight * positive_boost
            else:
                updated["sample_weight"] = weight * negative_boost
            tags = list(updated.get("tags", []))
            if "builtin_lexicon" not in tags:
                tags.append("builtin_lexicon")
            updated["tags"] = tags
        boosted.append(updated)
    return boosted


def evaluate(model, rows):
    x, y, _ = build_arrays(rows)
    probs = np.clip(predict_probabilities(model, x), 1e-6, 1 - 1e-6)
    loss = log_loss(y, probs, labels=[0, 1])

    grouped = group_rows(rows)
    top1 = 0
    mrr_total = 0.0
    count = 0

    for key, group in grouped.items():
        scored = []
        for item in group:
            p = float(np.clip(predict_probabilities(model, np.asarray([encode_feature(item)], dtype=np.float32))[0], 1e-6, 1 - 1e-6))
            scored.append((p, item))
        scored.sort(key=lambda x: x[0], reverse=True)
        count += 1
        if scored and scored[0][1]["label"] > 0:
            top1 += 1
        for idx, (_, item) in enumerate(scored, start=1):
            if item["label"] > 0:
                mrr_total += 1.0 / idx
                break

    return {
        "loss": float(loss),
        "top1": float(top1 / max(count, 1)),
        "mrr": float(mrr_total / max(count, 1)),
    }


def hard_case_rows(rows):
    hard = []
    for group in group_rows(rows).values():
        if any(float(item.get("label", 0)) > 0 and int(item.get("base_rank", 0)) > 0 for item in group):
            hard.extend(group)
    return hard


def base_rank_metrics(rows):
    top1 = 0
    mrr_total = 0.0
    count = 0
    for group in group_rows(rows).values():
        ordered = sorted(group, key=lambda item: int(item.get("base_rank", 999999)))
        if not any(float(item.get("label", 0)) > 0 for item in ordered):
            continue
        count += 1
        if ordered and float(ordered[0].get("label", 0)) > 0:
            top1 += 1
        for index, item in enumerate(ordered, start=1):
            if float(item.get("label", 0)) > 0:
                mrr_total += 1.0 / index
                break
    return {
        "top1": float(top1 / max(count, 1)),
        "mrr": float(mrr_total / max(count, 1)),
        "groups": count,
    }


def evaluate_with_arrays(model, rows, x):
    if len(rows) == 0:
        return {"loss": 0.0, "top1": 0.0, "mrr": 0.0}
    probs = np.clip(predict_probabilities(model, x), 1e-6, 1 - 1e-6)
    return evaluate_probs(rows, probs)


def save_torch_checkpoint(checkpoint_path, model, optimizer, best_stage, best, hidden_sizes, tag):
    torch.save({
        "model_state": {k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
        "optimizer_state": optimizer.state_dict(),
        "best_epoch": best_stage,
        "best_score": best,
        "hidden_sizes": hidden_sizes,
        "expected_dim": EXPECTED_DIM,
        "architecture": MODEL_ARCHITECTURE,
        "tag": tag,
    }, checkpoint_path)


def predict_probabilities(model, x):
    if torch is not None and isinstance(model, nn.Module):
        model.eval()
        device = next(model.parameters()).device
        with torch.no_grad():
            tensor = torch.tensor(x, dtype=torch.float32, device=device)
            logits = model(tensor).cpu().numpy().reshape(-1)
        return 1.0 / (1.0 + np.exp(-logits))
    return model.predict(x)


def write_json(path, payload):
    directory = os.path.dirname(path) or "."
    tmp_path = os.path.join(
        directory,
        f".{os.path.basename(path)}.{os.getpid()}.{threading.get_ident()}.tmp",
    )
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)


class StopRequested(Exception):
    def __init__(self, action):
        super().__init__(action)
        self.action = action


def control_file_path(output_dir):
    return os.path.join(output_dir, "training_control.json")


def read_training_control(output_dir):
    path = control_file_path(output_dir)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
        action = payload.get("action")
        if action in {"pause", "stop"}:
            return action
    except Exception:
        return None
    return None


def clear_training_control(output_dir):
    path = control_file_path(output_dir)
    try:
        if os.path.exists(path):
            os.unlink(path)
    except Exception:
        pass


def ensure_not_stopped(output_dir):
    action = read_training_control(output_dir)
    if action:
        raise StopRequested(action)


def write_training_progress(
    output_dir,
    completed_units,
    total_units,
    batch_size,
    best_epoch,
    last_valid_top1,
    last_valid_mrr,
    device=None,
    phase=None,
    phase_message=None,
    status=None,
):
    total_units = max(int(total_units), 1)
    completed_units = max(0, min(int(completed_units), total_units))
    progress_percent = (float(completed_units) * 100.0) / float(total_units)
    payload = {
        "trained_estimators": completed_units,
        "target_estimators": total_units,
        "progress_percent": progress_percent,
        "progress_segments": 100,
        "batch_size": batch_size,
        "best_epoch": best_epoch,
        "last_valid_top1": last_valid_top1,
        "last_valid_mrr": last_valid_mrr,
    }
    if device is not None:
        payload["device"] = device
    if phase is not None:
        payload["phase"] = phase
    if phase_message is not None:
        payload["phase_message"] = phase_message
    if status is not None:
        payload["status"] = status
    write_json(os.path.join(output_dir, "training_progress.json"), payload)


class PhaseHeartbeat:
    def __init__(
        self,
        output_dir,
        phase,
        base_message,
        completed_units,
        total_units,
        batch_size,
        best_epoch=0,
        last_valid_top1=0.0,
        last_valid_mrr=0.0,
        device=None,
        interval=5.0,
    ):
        self.output_dir = output_dir
        self.phase = phase
        self.base_message = base_message
        self.completed_units = completed_units
        self.total_units = total_units
        self.batch_size = batch_size
        self.best_epoch = best_epoch
        self.last_valid_top1 = last_valid_top1
        self.last_valid_mrr = last_valid_mrr
        self.device = device
        self.interval = interval
        self._stop = threading.Event()
        self._thread = None
        self._started_at = None
        self.status = "running"

    def _message(self):
        elapsed = int(time.time() - self._started_at)
        return f"{self.base_message} (已執行 {elapsed}s)"

    def _run(self):
        while not self._stop.wait(self.interval):
            write_training_progress(
                output_dir=self.output_dir,
                completed_units=self.completed_units,
                total_units=self.total_units,
                batch_size=self.batch_size,
                best_epoch=self.best_epoch,
                last_valid_top1=self.last_valid_top1,
                last_valid_mrr=self.last_valid_mrr,
                device=self.device,
                phase=self.phase,
                phase_message=self._message(),
                status=self.status,
            )

    def __enter__(self):
        self._started_at = time.time()
        write_training_progress(
            output_dir=self.output_dir,
            completed_units=self.completed_units,
            total_units=self.total_units,
            batch_size=self.batch_size,
            best_epoch=self.best_epoch,
            last_valid_top1=self.last_valid_top1,
            last_valid_mrr=self.last_valid_mrr,
            device=self.device,
            phase=self.phase,
            phase_message=self._message(),
            status=self.status,
        )
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=0.2)


class PhaseReporter:
    def __init__(
        self,
        output_dir,
        phase,
        phase_index,
        phase_count,
        batch_size,
        *,
        best_epoch=0,
        last_valid_top1=0.0,
        last_valid_mrr=0.0,
        device=None,
    ):
        self.output_dir = output_dir
        self.phase = phase
        self.phase_index = phase_index
        self.phase_count = phase_count
        self.batch_size = batch_size
        self.best_epoch = best_epoch
        self.last_valid_top1 = last_valid_top1
        self.last_valid_mrr = last_valid_mrr
        self.device = device
        self.status = "running"

    def update_fraction(self, fraction, message):
        fraction = max(0.0, min(1.0, float(fraction)))
        completed_units = self.phase_index + fraction
        total_units = max(float(self.phase_count), 1.0)
        progress_percent = (completed_units * 100.0) / total_units
        payload = {
            "trained_estimators": completed_units,
            "target_estimators": self.phase_count,
            "progress_percent": progress_percent,
            "progress_segments": 100,
            "batch_size": self.batch_size,
            "best_epoch": self.best_epoch,
            "last_valid_top1": self.last_valid_top1,
            "last_valid_mrr": self.last_valid_mrr,
            "phase": self.phase,
            "phase_message": message,
            "status": self.status,
        }
        if self.device is not None:
            payload["device"] = self.device
        write_json(os.path.join(self.output_dir, "training_progress.json"), payload)

    def update_counts(self, current, total, message):
        safe_total = max(int(total), 1)
        safe_current = max(0, min(int(current), safe_total))
        self.update_fraction(float(safe_current) / float(safe_total), f"{message} {safe_current}/{safe_total}")


def write_phase_progress(
    output_dir,
    phase,
    phase_message,
    phase_index,
    phase_count,
    batch_size,
    best_epoch=0,
    last_valid_top1=0.0,
    last_valid_mrr=0.0,
    device=None,
    status="running",
):
    write_training_progress(
        output_dir=output_dir,
        completed_units=phase_index,
        total_units=phase_count,
        batch_size=batch_size,
        best_epoch=best_epoch,
        last_valid_top1=last_valid_top1,
        last_valid_mrr=last_valid_mrr,
        device=device,
        phase=phase,
        phase_message=phase_message,
        status=status,
    )


class RankerMLP(nn.Module):
    def __init__(self, input_dim, hidden_sizes):
        super().__init__()
        self.input_dim = input_dim
        layers = []
        current = input_dim
        for hidden in hidden_sizes:
            layers.append(nn.Linear(current, hidden))
            layers.append(nn.ReLU())
            current = hidden
        layers.append(nn.Linear(current, 1))
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)


def parse_hidden_sizes(raw):
    return [int(part.strip()) for part in raw.split(",") if part.strip()]


def train(args):
    effective_backend = resolve_backend(args.backend)
    preprocessing_steps = 8
    preprocessing_batch_size = max(1, int(args.batch_size))
    cache_dir = args.feature_cache_dir or os.path.join(args.output, "feature_cache")
    os.makedirs(cache_dir, exist_ok=True)
    clear_training_control(args.output)
    write_phase_progress(args.output, "loading", "讀取 train/valid/test", 0, preprocessing_steps, preprocessing_batch_size)

    loading_reporter = PhaseReporter(args.output, "loading", 0, preprocessing_steps, preprocessing_batch_size)
    with PhaseHeartbeat(args.output, "loading", "讀取 train/valid/test", 0, preprocessing_steps, preprocessing_batch_size):
        train_rows = load_jsonl_with_progress(
            args.train,
            progress_callback=lambda current, total: (loading_reporter.update_counts(current, total, "讀取 train"), ensure_not_stopped(args.output)),
        )
        valid_rows = load_jsonl_with_progress(
            args.valid,
            progress_callback=lambda current, total: (loading_reporter.update_counts(current, total, "讀取 valid"), ensure_not_stopped(args.output)),
        )
        test_rows = load_jsonl_with_progress(
            args.test,
            progress_callback=lambda current, total: (loading_reporter.update_counts(current, total, "讀取 test"), ensure_not_stopped(args.output)),
        ) if args.test else []
    write_phase_progress(
        args.output,
        "loading",
        f"已讀取 train={len(train_rows)} valid={len(valid_rows)} test={len(test_rows)}",
        1,
        preprocessing_steps,
        preprocessing_batch_size,
    )
    train_builtin_cache = rows_cache_path(cache_dir, "train_builtin_rows", rows_cache_key("train_builtin_rows", args.train, args, "builtin"))
    valid_builtin_cache = rows_cache_path(cache_dir, "valid_builtin_rows", rows_cache_key("valid_builtin_rows", args.valid, args, "builtin"))
    test_builtin_cache = rows_cache_path(cache_dir, "test_builtin_rows", rows_cache_key("test_builtin_rows", args.test, args, "builtin")) if args.test else None
    train_neighbor_cache = rows_cache_path(cache_dir, "train_neighbor_rows", rows_cache_key("train_neighbor_rows", args.train, args, "builtin-neighbor"))
    valid_neighbor_cache = rows_cache_path(cache_dir, "valid_neighbor_rows", rows_cache_key("valid_neighbor_rows", args.valid, args, "builtin-neighbor"))
    test_neighbor_cache = rows_cache_path(cache_dir, "test_neighbor_rows", rows_cache_key("test_neighbor_rows", args.test, args, "builtin-neighbor")) if args.test else None
    train_pairwise_cache = rows_cache_path(cache_dir, "train_pairwise_rows", rows_cache_key("train_pairwise_rows", args.train, args, "builtin-neighbor-pairwise"))
    valid_pairwise_cache = rows_cache_path(cache_dir, "valid_pairwise_rows", rows_cache_key("valid_pairwise_rows", args.valid, args, "builtin-neighbor-pairwise"))
    test_pairwise_cache = rows_cache_path(cache_dir, "test_pairwise_rows", rows_cache_key("test_pairwise_rows", args.test, args, "builtin-neighbor-pairwise")) if args.test else None
    train_rows_cache = rows_cache_path(cache_dir, "train_rows", rows_cache_key("train_rows", args.train, args, "prepared-train"))

    augment_reporter = PhaseReporter(args.output, "augmenting", 1, preprocessing_steps, preprocessing_batch_size)
    if os.path.exists(train_builtin_cache) and os.path.exists(valid_builtin_cache) and (not args.test or (test_builtin_cache and os.path.exists(test_builtin_cache))):
        augment_reporter.update_fraction(0.0, "載入 lexicon boost rows 快取")
        train_rows = load_rows_jsonl(train_builtin_cache)
        augment_reporter.update_fraction(0.34, "載入 train lexicon boost 快取完成")
        valid_rows = load_rows_jsonl(valid_builtin_cache)
        augment_reporter.update_fraction(0.67, "載入 valid lexicon boost 快取完成")
        test_rows = load_rows_jsonl(test_builtin_cache) if test_builtin_cache else []
        augment_reporter.update_fraction(1.0, "載入 lexicon boost rows 快取完成")
    else:
        with PhaseHeartbeat(args.output, "augmenting", "套用 lexicon boost", 1, preprocessing_steps, preprocessing_batch_size):
            augment_reporter.update_fraction(0.0, "套用 lexicon boost train")
            train_rows = apply_builtin_lexicon_boost(
                train_rows,
                positive_boost=args.builtin_positive_boost,
                negative_boost=args.builtin_negative_boost,
            )
            augment_reporter.update_fraction(0.34, "套用 lexicon boost valid")
            valid_rows = apply_builtin_lexicon_boost(
                valid_rows,
                positive_boost=max(1.0, min(args.builtin_positive_boost, 1.5)),
                negative_boost=max(1.0, min(args.builtin_negative_boost, 1.1)),
            )
            augment_reporter.update_fraction(0.67, "套用 lexicon boost test")
            test_rows = apply_builtin_lexicon_boost(
                test_rows,
                positive_boost=max(1.0, min(args.builtin_positive_boost, 1.5)),
                negative_boost=max(1.0, min(args.builtin_negative_boost, 1.1)),
            )
            augment_reporter.update_fraction(1.0, "套用 lexicon boost 完成")
        save_rows_jsonl(train_builtin_cache, train_rows)
        save_rows_jsonl(valid_builtin_cache, valid_rows)
        if test_builtin_cache:
            save_rows_jsonl(test_builtin_cache, test_rows)
    write_phase_progress(args.output, "augmenting", "套用 lexicon boost", 2, preprocessing_steps, preprocessing_batch_size)

    neighbor_reporter = PhaseReporter(args.output, "augmenting", 2, preprocessing_steps, preprocessing_batch_size)
    if os.path.exists(train_neighbor_cache) and os.path.exists(valid_neighbor_cache) and (not args.test or (test_neighbor_cache and os.path.exists(test_neighbor_cache))):
        neighbor_reporter.update_fraction(0.0, "載入 neighbor noise rows 快取")
        train_rows = load_rows_jsonl(train_neighbor_cache)
        neighbor_reporter.update_fraction(0.34, "載入 train neighbor 快取完成")
        valid_rows = load_rows_jsonl(valid_neighbor_cache)
        neighbor_reporter.update_fraction(0.67, "載入 valid neighbor 快取完成")
        test_rows = load_rows_jsonl(test_neighbor_cache) if test_neighbor_cache else []
        neighbor_reporter.update_fraction(1.0, "載入 neighbor noise rows 快取完成")
    else:
        with PhaseHeartbeat(args.output, "augmenting", "加入 neighbor key noise", 2, preprocessing_steps, preprocessing_batch_size):
            neighbor_reporter.update_fraction(0.0, "加入 neighbor key noise train")
            train_rows = apply_neighbor_key_noise(train_rows, weight_scale=args.neighbor_noise_weight)
            neighbor_reporter.update_fraction(0.34, "加入 neighbor key noise valid")
            valid_rows = apply_neighbor_key_noise(valid_rows, weight_scale=min(args.neighbor_noise_weight, 0.5))
            neighbor_reporter.update_fraction(0.67, "加入 neighbor key noise test")
            test_rows = apply_neighbor_key_noise(test_rows, weight_scale=min(args.neighbor_noise_weight, 0.5))
            neighbor_reporter.update_fraction(1.0, "加入 neighbor key noise 完成")
        save_rows_jsonl(train_neighbor_cache, train_rows)
        save_rows_jsonl(valid_neighbor_cache, valid_rows)
        if test_neighbor_cache:
            save_rows_jsonl(test_neighbor_cache, test_rows)
    write_phase_progress(args.output, "augmenting", "加入 neighbor key noise", 3, preprocessing_steps, preprocessing_batch_size)

    pairwise_reporter = PhaseReporter(args.output, "augmenting", 3, preprocessing_steps, preprocessing_batch_size)
    if os.path.exists(train_pairwise_cache) and os.path.exists(valid_pairwise_cache) and (not args.test or (test_pairwise_cache and os.path.exists(test_pairwise_cache))):
        pairwise_reporter.update_fraction(0.0, "載入 pairwise rows 快取")
        train_rows = load_rows_jsonl(train_pairwise_cache)
        pairwise_reporter.update_fraction(0.34, "載入 train pairwise 快取完成")
        valid_rows = load_rows_jsonl(valid_pairwise_cache)
        pairwise_reporter.update_fraction(0.67, "載入 valid pairwise 快取完成")
        test_rows = load_rows_jsonl(test_pairwise_cache) if test_pairwise_cache else []
        pairwise_reporter.update_fraction(1.0, "載入 pairwise rows 快取完成")
    else:
        with PhaseHeartbeat(args.output, "augmenting", "加入 pairwise hard negatives", 3, preprocessing_steps, preprocessing_batch_size):
            pairwise_reporter.update_fraction(0.0, "加入 pairwise hard negatives train")
            train_rows = apply_pairwise_hard_negative_boost(
                train_rows,
                top_k=args.pairwise_top_k,
                boost=args.pairwise_boost,
            )
            pairwise_reporter.update_fraction(0.34, "加入 pairwise hard negatives valid")
            valid_rows = apply_pairwise_hard_negative_boost(
                valid_rows,
                top_k=max(1, min(args.pairwise_top_k, 2)),
                boost=1.0,
            )
            pairwise_reporter.update_fraction(0.67, "加入 pairwise hard negatives test")
            test_rows = apply_pairwise_hard_negative_boost(
                test_rows,
                top_k=max(1, min(args.pairwise_top_k, 2)),
                boost=1.0,
            )
            pairwise_reporter.update_fraction(1.0, "加入 pairwise hard negatives 完成")
        save_rows_jsonl(train_pairwise_cache, train_rows)
        save_rows_jsonl(valid_pairwise_cache, valid_rows)
        if test_pairwise_cache:
            save_rows_jsonl(test_pairwise_cache, test_rows)
    write_phase_progress(args.output, "augmenting", "加入 pairwise hard negatives", 4, preprocessing_steps, preprocessing_batch_size)

    resampling_reporter = PhaseReporter(args.output, "resampling", 4, preprocessing_steps, preprocessing_batch_size)
    train_sampling_weights = build_sampling_weights(train_rows)
    if os.path.exists(train_rows_cache):
        resampling_reporter.update_fraction(0.0, "載入 prepared train rows 快取")
        train_rows = load_rows_jsonl(train_rows_cache)
        train_sampling_weights = build_sampling_weights(train_rows)
        resampling_reporter.update_fraction(1.0, "載入 prepared train rows 快取完成")
    else:
        with PhaseHeartbeat(args.output, "resampling", "準備 train sampling order", 4, preprocessing_steps, preprocessing_batch_size):
            resampling_reporter.update_fraction(0.0, "依 sample_weight 建立抽樣順序")
            train_rows = prepare_rows_for_training(train_rows, args.seed)
            train_sampling_weights = build_sampling_weights(train_rows)
            resampling_reporter.update_fraction(0.67, "寫入 prepared train rows 快取")
            save_rows_jsonl(train_rows_cache, train_rows)
            resampling_reporter.update_fraction(1.0, "準備 train sampling order 完成")
    write_phase_progress(
        args.output,
        "resampling",
        f"抽樣準備完成 train={len(train_rows)}",
        5,
        preprocessing_steps,
        preprocessing_batch_size,
    )
    train_eval_rows = train_rows
    if args.train_eval_sample_limit and len(train_rows) > args.train_eval_sample_limit:
        train_eval_rows = train_rows[:args.train_eval_sample_limit]
    train_chunk_sampler = TrainChunkSampler(len(train_rows), args.train_chunk_size, args.seed, train_sampling_weights)

    train_eval_reporter = PhaseReporter(args.output, "tensorizing", 5, preprocessing_steps, preprocessing_batch_size)
    train_eval_cache_path = cache_npz_path(cache_dir, "train_eval", feature_cache_key("train_eval", args.train, args, "train-eval"))
    if os.path.exists(train_eval_cache_path):
        train_eval_reporter.update_fraction(1.0, f"載入 train_eval 特徵快取 {os.path.basename(train_eval_cache_path)}")
        x_train_eval, y_train_eval, w_train_eval = load_cached_arrays(train_eval_cache_path)
    else:
        with PhaseHeartbeat(args.output, "tensorizing", "建立 train_eval 特徵矩陣", 5, preprocessing_steps, preprocessing_batch_size):
            x_train_eval, y_train_eval, w_train_eval = build_arrays_with_progress(
                train_eval_rows,
                progress_callback=lambda current, total: (train_eval_reporter.update_counts(current, total, "建立 train_eval 特徵矩陣"), ensure_not_stopped(args.output)),
            )
        train_eval_reporter.update_fraction(1.0, f"儲存 train_eval 特徵快取 {os.path.basename(train_eval_cache_path)}")
        save_cached_arrays(train_eval_cache_path, x_train_eval, y_train_eval, w_train_eval)

    train_tensor_reporter = PhaseReporter(args.output, "tensorizing", 5, preprocessing_steps, preprocessing_batch_size)
    train_cache_path = cache_npz_path(cache_dir, "train", feature_cache_key("train", args.train, args, "resampled-train"))
    if train_chunk_sampler.is_enabled():
        x_train = y_train = w_train = None
        train_tensor_reporter.update_fraction(1.0, f"啟用 train chunk 模式 size={train_chunk_sampler.chunk_size}")
    elif os.path.exists(train_cache_path):
        train_tensor_reporter.update_fraction(1.0, f"載入 train 特徵快取 {os.path.basename(train_cache_path)}")
        x_train, y_train, w_train = load_cached_arrays(train_cache_path)
    else:
        with PhaseHeartbeat(args.output, "tensorizing", "建立 train 特徵矩陣", 5, preprocessing_steps, preprocessing_batch_size):
            x_train, y_train, w_train = build_arrays_with_progress(
                train_rows,
                progress_callback=lambda current, total: (train_tensor_reporter.update_counts(current, total, "建立 train 特徵矩陣"), ensure_not_stopped(args.output)),
            )
        train_tensor_reporter.update_fraction(1.0, f"儲存 train 特徵快取 {os.path.basename(train_cache_path)}")
        save_cached_arrays(train_cache_path, x_train, y_train, w_train)
    history = []
    best = None
    best_stage = None
    model = None
    checkpoint_path = None
    hidden_sizes = None
    valid_tensor_reporter = PhaseReporter(args.output, "tensorizing", 6, preprocessing_steps, preprocessing_batch_size)
    valid_cache_path = cache_npz_path(cache_dir, "valid", feature_cache_key("valid", args.valid, args, "augmented-valid"))
    if os.path.exists(valid_cache_path):
        valid_tensor_reporter.update_fraction(1.0, f"載入 valid 特徵快取 {os.path.basename(valid_cache_path)}")
        x_valid, y_valid, w_valid = load_cached_arrays(valid_cache_path)
    else:
        with PhaseHeartbeat(args.output, "tensorizing", "建立 valid 特徵矩陣", 6, preprocessing_steps, preprocessing_batch_size):
            x_valid, y_valid, w_valid = build_arrays_with_progress(
                valid_rows,
                progress_callback=lambda current, total: (valid_tensor_reporter.update_counts(current, total, "建立 valid 特徵矩陣"), ensure_not_stopped(args.output)),
            )
        valid_tensor_reporter.update_fraction(1.0, f"儲存 valid 特徵快取 {os.path.basename(valid_cache_path)}")
        save_cached_arrays(valid_cache_path, x_valid, y_valid, w_valid)
    test_cache_path = cache_npz_path(cache_dir, "test", feature_cache_key("test", args.test, args, "augmented-test")) if args.test else None
    if args.test:
        test_tensor_reporter = PhaseReporter(args.output, "tensorizing", 6, preprocessing_steps, preprocessing_batch_size)
        if test_cache_path and os.path.exists(test_cache_path):
            test_tensor_reporter.update_fraction(1.0, f"載入 test 特徵快取 {os.path.basename(test_cache_path)}")
            x_test, y_test, w_test = load_cached_arrays(test_cache_path)
        else:
            with PhaseHeartbeat(args.output, "tensorizing", "建立 test 特徵矩陣", 6, preprocessing_steps, preprocessing_batch_size):
                x_test, y_test, w_test = build_arrays_with_progress(
                    test_rows,
                    progress_callback=lambda current, total: (test_tensor_reporter.update_counts(current, total, "建立 test 特徵矩陣"), ensure_not_stopped(args.output)),
                )
            test_tensor_reporter.update_fraction(1.0, f"儲存 test 特徵快取 {os.path.basename(test_cache_path)}")
            save_cached_arrays(test_cache_path, x_test, y_test, w_test)
    else:
        x_test = y_test = w_test = None
    write_phase_progress(
        args.output,
        "tensorizing",
        f"特徵矩陣完成 train={'chunked' if x_train is None else len(x_train)} valid={len(x_valid)}",
        6,
        preprocessing_steps,
        preprocessing_batch_size,
    )
    status = "completed"
    try:
        if effective_backend == "mlp":
            device = "mps" if torch.backends.mps.is_available() else "cpu"
            hidden_sizes = parse_hidden_sizes(args.hidden_sizes)
            model = RankerMLP(EXPECTED_DIM, hidden_sizes).to(device)
            optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
            loss_fn = nn.BCEWithLogitsLoss(reduction="none")
            checkpoint_path = os.path.join(args.output, "ranker_checkpoint.pt")
            if args.resume_checkpoint and os.path.exists(args.resume_checkpoint):
                checkpoint = torch.load(args.resume_checkpoint, map_location=device)
                checkpoint_architecture = checkpoint.get("architecture", "legacy_conv_v1")
                if checkpoint_architecture != MODEL_ARCHITECTURE:
                    raise RuntimeError(
                        f"checkpoint architecture {checkpoint_architecture} is incompatible with {MODEL_ARCHITECTURE}"
                    )
                model.load_state_dict(checkpoint["model_state"])
                if "optimizer_state" in checkpoint:
                    try:
                        optimizer.load_state_dict(checkpoint["optimizer_state"])
                    except Exception:
                        pass

            tensor_reporter = PhaseReporter(args.output, "tensorizing", 7, preprocessing_steps, preprocessing_batch_size, device=device)
            with PhaseHeartbeat(args.output, "tensorizing", f"建立 tensor 並搬到 {device}", 7, preprocessing_steps, preprocessing_batch_size, device=device):
                loader_workers = max(0, int(args.dataloader_workers))
                if train_chunk_sampler.is_enabled():
                    train_loader = None
                    x_train_t = y_train_t = w_train_t = None
                    tensor_reporter.update_fraction(0.45, f"啟用 chunk 訓練，略過全量 train tensor device={device}")
                else:
                    tensor_reporter.update_fraction(0.0, "建立 train tensor")
                    x_train_t = torch.tensor(x_train, dtype=torch.float32)
                    y_train_t = torch.tensor(y_train, dtype=torch.float32).unsqueeze(1)
                    w_train_t = torch.tensor(w_train, dtype=torch.float32).unsqueeze(1)
                    tensor_reporter.update_fraction(0.45, "建立 DataLoader")
                    dataset = TensorDataset(x_train_t, y_train_t, w_train_t)
                    train_loader = DataLoader(
                        dataset,
                        batch_size=max(1, int(args.batch_size)),
                        shuffle=True,
                        num_workers=loader_workers,
                        persistent_workers=loader_workers > 0,
                    )
                tensor_reporter.update_fraction(0.75, f"建立 valid tensor 並搬到 {device}")
                x_valid_t = torch.tensor(x_valid, dtype=torch.float32).to(device)
                tensor_reporter.update_fraction(1.0, f"建立 tensor 並搬到 {device} 完成")
            write_phase_progress(
                args.output,
                "tensorizing",
                f"Tensor 準備完成 device={device}",
                7,
                preprocessing_steps,
                preprocessing_batch_size,
                device=device,
            )
            best_state = None
            total_batches = max(1, train_chunk_sampler.total_batches_for_epochs(args.epochs, args.batch_size) if train_chunk_sampler.is_enabled() else len(train_loader) * args.epochs)
            completed_batches = 0
            next_progress_percent = 0.25
            write_phase_progress(
                args.output,
                "training",
                f"開始訓練 epochs={args.epochs} batches={'chunked' if train_chunk_sampler.is_enabled() else len(train_loader)}",
                8,
                preprocessing_steps,
                preprocessing_batch_size,
                device=device,
            )

            for epoch in range(1, args.epochs + 1):
                ensure_not_stopped(args.output)
                if train_chunk_sampler.is_enabled():
                    chunk_rows, chunk_meta = train_chunk_sampler.sample(train_rows, epoch)
                    chunk_cache = cache_npz_path(
                        cache_dir,
                        "train_chunk",
                        train_chunk_cache_key(args.train, args, chunk_meta["chunk_id"]),
                    )
                    if os.path.exists(chunk_cache):
                        x_train_chunk, y_train_chunk, w_train_chunk = load_cached_arrays(chunk_cache)
                    else:
                        chunk_reporter = PhaseReporter(args.output, "training", 7, 8, max(1, int(args.batch_size)), device=device)
                        with PhaseHeartbeat(
                            args.output,
                            "training",
                            f"建立 train chunk 特徵 {chunk_meta['position']}/{chunk_meta['cycle_size']}",
                            7,
                            8,
                            max(1, int(args.batch_size)),
                            device=device,
                        ):
                            x_train_chunk, y_train_chunk, w_train_chunk = build_arrays_with_progress(
                                chunk_rows,
                                progress_callback=lambda current, total: (
                                    chunk_reporter.update_counts(
                                        current,
                                        total,
                                        f"建立 train chunk 特徵 cycle={chunk_meta['cycle']} chunk={chunk_meta['position']}/{chunk_meta['cycle_size']}",
                                    ),
                                    ensure_not_stopped(args.output),
                                ),
                            )
                        save_cached_arrays(chunk_cache, x_train_chunk, y_train_chunk, w_train_chunk)

                    dataset = TensorDataset(
                        torch.tensor(x_train_chunk, dtype=torch.float32),
                        torch.tensor(y_train_chunk, dtype=torch.float32).unsqueeze(1),
                        torch.tensor(w_train_chunk, dtype=torch.float32).unsqueeze(1),
                    )
                    train_loader = DataLoader(
                        dataset,
                        batch_size=max(1, int(args.batch_size)),
                        shuffle=True,
                        num_workers=loader_workers,
                        persistent_workers=loader_workers > 0,
                    )
                    epoch_train_rows = train_eval_rows
                    epoch_train_x = x_train_eval
                    epoch_message = (
                        f"訓練中 epoch={epoch}/{args.epochs} "
                        f"cycle={chunk_meta['cycle']} chunk={chunk_meta['position']}/{chunk_meta['cycle_size']}"
                    )
                else:
                    epoch_train_rows = train_eval_rows
                    epoch_train_x = x_train_eval
                    epoch_message = f"訓練中 epoch={epoch}/{args.epochs}"

                model.train()
                for batch_x, batch_y, batch_w in train_loader:
                    ensure_not_stopped(args.output)
                    batch_x = batch_x.to(device)
                    batch_y = batch_y.to(device)
                    batch_w = batch_w.to(device)
                    optimizer.zero_grad()
                    logits = model(batch_x)
                    loss = (loss_fn(logits, batch_y) * batch_w).mean()
                    loss.backward()
                    optimizer.step()
                    completed_batches += 1
                    current_percent = (float(completed_batches) * 100.0) / float(total_batches)
                    if current_percent >= float(next_progress_percent):
                        write_training_progress(
                            args.output,
                            completed_batches,
                            total_batches,
                            max(1, int(args.batch_size)),
                            best_stage,
                            0.0 if best is None else best[0],
                            0.0 if best is None else best[1],
                            device=device,
                            phase="training",
                            phase_message=f"{epoch_message} batch={completed_batches}/{total_batches}",
                            status="running",
                        )
                        next_progress_percent = min(100.0, float(next_progress_percent) + 0.25)

                model.eval()
                with torch.no_grad():
                    train_probs = torch.sigmoid(model(torch.tensor(epoch_train_x, dtype=torch.float32, device=device))).cpu().numpy().reshape(-1)
                    valid_probs = torch.sigmoid(model(x_valid_t)).cpu().numpy().reshape(-1)

                train_metrics = evaluate_probs(epoch_train_rows, np.clip(train_probs, 1e-6, 1 - 1e-6))
                valid_metrics = evaluate_probs(valid_rows, np.clip(valid_probs, 1e-6, 1 - 1e-6))
                valid_hard_rows = hard_case_rows(valid_rows)
                valid_hard_metrics = evaluate(model, valid_hard_rows) if valid_hard_rows else valid_metrics
                epoch_row = {
                    "epoch": epoch,
                    "train": train_metrics,
                    "valid": valid_metrics,
                    "valid_hard": valid_hard_metrics,
                }
                if train_chunk_sampler.is_enabled():
                    epoch_row["train_chunk"] = {
                        "cycle": chunk_meta["cycle"],
                        "position": chunk_meta["position"],
                        "cycle_size": chunk_meta["cycle_size"],
                        "length": chunk_meta["length"],
                    }
                history.append(epoch_row)
                print(
                    f"epoch={epoch} "
                    f"train_loss={train_metrics['loss']:.4f} train_top1={train_metrics['top1']:.4f} train_mrr={train_metrics['mrr']:.4f} "
                    f"valid_loss={valid_metrics['loss']:.4f} valid_top1={valid_metrics['top1']:.4f} valid_mrr={valid_metrics['mrr']:.4f} "
                    f"valid_hard_top1={valid_hard_metrics['top1']:.4f} valid_hard_mrr={valid_hard_metrics['mrr']:.4f}",
                    flush=True,
                )
                score = (
                    valid_hard_metrics["top1"],
                    valid_metrics["top1"],
                    valid_metrics["mrr"],
                    -valid_metrics["loss"],
                )
                if best is None or score > best:
                    best = score
                    best_stage = epoch
                    best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
                    save_torch_checkpoint(checkpoint_path, model, optimizer, best_stage, best, hidden_sizes, "best")
                elif epoch % max(1, int(args.checkpoint_interval)) == 0:
                    save_torch_checkpoint(checkpoint_path, model, optimizer, best_stage, best, hidden_sizes, f"epoch-{epoch}")

                partial_payload = {
                    "backend_requested": args.backend,
                    "backend_effective": effective_backend,
                    "train": train_metrics,
                    "valid": valid_metrics,
                    "test": None,
                    "best_epoch": best_stage,
                    "epochs": history,
                    "status": "running",
                }
                write_json(os.path.join(args.output, "metrics.partial.json"), partial_payload)
                write_training_progress(
                    args.output,
                    completed_batches,
                    total_batches,
                    max(1, int(args.batch_size)),
                    best_stage,
                    valid_metrics["top1"],
                    valid_metrics["mrr"],
                    device=device,
                    phase="training",
                    phase_message=f"完成 epoch={epoch}/{args.epochs}",
                    status="running",
                )

            if best_state is not None:
                model.load_state_dict(best_state)
                save_torch_checkpoint(checkpoint_path, model, optimizer, best_stage, best, hidden_sizes, "final-best")
            model.eval()
        else:
            estimator_batch_size = max(1, int(args.batch_size))
            model = GradientBoostingRegressor(
                n_estimators=estimator_batch_size,
                learning_rate=args.learning_rate,
                max_depth=args.max_depth,
                random_state=args.seed,
                warm_start=True,
            )

            trained_estimators = 0
            while trained_estimators < args.epochs:
                ensure_not_stopped(args.output)
                trained_estimators = min(args.epochs, trained_estimators + estimator_batch_size)
                model.n_estimators = trained_estimators
                model.fit(x_train, y_train)

                train_probs = np.clip(model.predict(x_train), 1e-6, 1 - 1e-6)
                valid_probs = np.clip(model.predict(x_valid), 1e-6, 1 - 1e-6)
                train_metrics = evaluate_probs(train_rows, train_probs)
                valid_metrics = evaluate_probs(valid_rows, valid_probs)
                epoch_row = {
                    "epoch": trained_estimators,
                    "train": train_metrics,
                    "valid": valid_metrics,
                }
                history.append(epoch_row)
                print(
                    f"epoch={trained_estimators} "
                    f"train_loss={train_metrics['loss']:.4f} train_top1={train_metrics['top1']:.4f} train_mrr={train_metrics['mrr']:.4f} "
                    f"valid_loss={valid_metrics['loss']:.4f} valid_top1={valid_metrics['top1']:.4f} valid_mrr={valid_metrics['mrr']:.4f}",
                    flush=True,
                )
                score = (valid_metrics["top1"], valid_metrics["mrr"], -valid_metrics["loss"])
                if best is None or score > best:
                    best = score
                    best_stage = trained_estimators

                partial_payload = {
                    "backend_requested": args.backend,
                    "backend_effective": effective_backend,
                    "train": train_metrics,
                    "valid": valid_metrics,
                    "test": None,
                    "best_epoch": best_stage,
                    "epochs": history,
                    "status": "running",
                }
                write_json(os.path.join(args.output, "metrics.partial.json"), partial_payload)
                write_training_progress(
                    args.output,
                    trained_estimators,
                    args.epochs,
                    estimator_batch_size,
                    best_stage,
                    valid_metrics["top1"],
                    valid_metrics["mrr"],
                    phase="training",
                    phase_message=f"完成 epoch={trained_estimators}/{args.epochs}",
                    status="running",
                )

            final_estimators = best_stage or args.epochs
            model = GradientBoostingRegressor(
                n_estimators=final_estimators,
                learning_rate=args.learning_rate,
                max_depth=args.max_depth,
                random_state=args.seed,
            )
            model.fit(x_train, y_train)
    except StopRequested as stop:
        status = "paused" if stop.action == "pause" else "stopped"
        if (
            effective_backend == "mlp"
            and model is not None
            and checkpoint_path is not None
            and hidden_sizes is not None
        ):
            try:
                checkpoint_best = best if best is not None else (0.0, 0.0, 0.0)
                checkpoint_epoch = best_stage or 0
                save_torch_checkpoint(
                    checkpoint_path,
                    model,
                    optimizer,
                    checkpoint_epoch,
                    checkpoint_best,
                    hidden_sizes,
                    f"{status}-current",
                )
            except Exception:
                pass
        partial_path = os.path.join(args.output, "metrics.partial.json")
        partial_payload = {
            "backend_requested": args.backend,
            "backend_effective": effective_backend,
            "best_epoch": best_stage,
            "epochs": history,
            "status": status,
        }
        if os.path.exists(partial_path):
            try:
                partial_payload.update(json.load(open(partial_path, "r", encoding="utf-8")))
                partial_payload["status"] = status
            except Exception:
                pass
        write_json(partial_path, partial_payload)
        write_phase_progress(
            args.output,
            "training",
            "已暫停" if status == "paused" else "已停止",
            8 if status != "running" else 0,
            preprocessing_steps,
            preprocessing_batch_size,
            best_stage or 0,
            0.0 if best is None else best[0],
            0.0 if best is None else best[1],
            status=status,
        )
        clear_training_control(args.output)
        return None, {
            "backend_requested": args.backend,
            "backend_effective": effective_backend,
            "model_architecture": MODEL_ARCHITECTURE if effective_backend == "mlp" else "gradient_boosting",
            "train": None,
            "valid": None,
            "test": None,
            "best_epoch": best_stage,
            "epochs": history,
            "status": status,
        }

    final_train_rows = train_eval_rows if train_chunk_sampler.is_enabled() else train_rows
    final_train_x = x_train_eval if train_chunk_sampler.is_enabled() else x_train

    final = {
        "backend_requested": args.backend,
        "backend_effective": effective_backend,
        "model_architecture": MODEL_ARCHITECTURE if effective_backend == "mlp" else "gradient_boosting",
        "train": evaluate_with_arrays(model, final_train_rows, final_train_x),
        "valid": evaluate_with_arrays(model, valid_rows, x_valid),
        "test": evaluate_with_arrays(model, test_rows, x_test) if test_rows and x_test is not None else None,
        "train_hard": evaluate(model, hard_case_rows(final_train_rows)) if hard_case_rows(final_train_rows) else None,
        "valid_hard": evaluate(model, hard_case_rows(valid_rows)) if hard_case_rows(valid_rows) else None,
        "test_hard": evaluate(model, hard_case_rows(test_rows)) if test_rows and hard_case_rows(test_rows) else None,
        "base_rank_valid": base_rank_metrics(valid_rows),
        "base_rank_valid_hard": base_rank_metrics(hard_case_rows(valid_rows)),
        "base_rank_test": base_rank_metrics(test_rows) if test_rows else None,
        "base_rank_test_hard": base_rank_metrics(hard_case_rows(test_rows)) if test_rows else None,
        "best_epoch": best_stage,
        "epochs": history,
        "status": status,
    }
    if train_chunk_sampler.is_enabled():
        final["train_eval_mode"] = "sampled"
        final["train_eval_rows"] = len(final_train_rows)
        final["train_chunk_size"] = train_chunk_sampler.chunk_size
    return model, final


def export_coreml(model, output_dir):
    if torch is not None and isinstance(model, nn.Module):
        path = os.path.join(output_dir, "CandidateRanker.mlpackage")
        model_cpu = model.to("cpu").eval()
        example = torch.rand(1, EXPECTED_DIM, dtype=torch.float32)
        traced = torch.jit.trace(model_cpu, example)
        mlmodel = ct.convert(
            traced,
            convert_to="mlprogram",
            inputs=[ct.TensorType(name="features", shape=example.shape)],
            outputs=[ct.TensorType(name="score")],
        )
        mlmodel.save(path)
        return path

    input_features = [("features", datatypes.Array(EXPECTED_DIM))]
    mlmodel = ct.converters.sklearn.convert(
        model,
        input_features=input_features,
        output_feature_names="score",
    )
    spec = mlmodel.get_spec()
    if spec.description.predictedFeatureName:
        spec.description.predictedFeatureName = "score"
    final_model = ct.models.MLModel(spec)
    path = os.path.join(output_dir, "CandidateRanker.mlmodel")
    final_model.save(path)
    return path


def evaluate_probs(rows, probs):
    y = np.asarray([int(r["label"] > 0) for r in rows], dtype=np.int64)
    loss = log_loss(y, probs, labels=[0, 1])
    grouped = group_rows(rows)
    top1 = 0
    mrr_total = 0.0
    count = 0
    index = 0
    for _, group in grouped.items():
        if not any(item["label"] > 0 for item in group):
            index += len(group)
            continue
        scored = []
        for item in group:
            scored.append((probs[index], item))
            index += 1
        scored.sort(key=lambda x: x[0], reverse=True)
        count += 1
        if scored and scored[0][1]["label"] > 0:
            top1 += 1
        for idx, (_, item) in enumerate(scored, start=1):
            if item["label"] > 0:
                mrr_total += 1.0 / idx
                break
    return {
        "loss": float(loss),
        "top1": float(top1 / max(count, 1)),
        "mrr": float(mrr_total / max(count, 1)),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--test")
    parser.add_argument("--output", required=True)
    parser.add_argument("--backend", choices=["tree", "mlp"], default="tree")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--hidden-sizes", default="192,128,96,64,32,8")
    parser.add_argument("--max-depth", type=int, default=3)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--pairwise-top-k", type=int, default=3)
    parser.add_argument("--pairwise-boost", type=float, default=2.0)
    parser.add_argument("--neighbor-noise-weight", type=float, default=0.35)
    parser.add_argument("--builtin-positive-boost", type=float, default=2.5)
    parser.add_argument("--builtin-negative-boost", type=float, default=1.15)
    parser.add_argument("--resume-checkpoint")
    parser.add_argument("--feature-cache-dir")
    parser.add_argument("--dataloader-workers", type=int, default=max(0, min(4, (os.cpu_count() or 1) - 1)))
    parser.add_argument("--train-eval-sample-limit", type=int, default=200000)
    parser.add_argument("--checkpoint-interval", type=int, default=5)
    parser.add_argument("--train-chunk-size", type=int, default=50000)
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)
    model, metrics = train(args)
    model_path = None
    if model is not None:
        model_path = export_coreml(model, args.output)

    with open(os.path.join(args.output, "metrics.json"), "w", encoding="utf-8") as f:
        json.dump(metrics, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.output, "feature_schema.json"), "w", encoding="utf-8") as f:
        json.dump(
            {"expected_dimension": EXPECTED_DIM, "model_architecture": MODEL_ARCHITECTURE},
            f,
            ensure_ascii=False,
            indent=2,
        )
    with open(os.path.join(args.output, "train_config.json"), "w", encoding="utf-8") as f:
        json.dump(vars(args), f, ensure_ascii=False, indent=2)

    if model_path:
        print(f"saved_model={model_path}")
    print(f"saved_metrics={os.path.join(args.output, 'metrics.json')}")


if __name__ == "__main__":
    main()
