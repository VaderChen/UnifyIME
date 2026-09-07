# Train Ranker Script Spec

這份文件定義 `UnifyIME` 候選排序模型的最小訓練腳本規格。

目標：
- 先做 `zh-Hant` 候選重排
- 模型可在 M1 上低延遲推論
- 輸出符合 [`COREML_RANKER.md`](COREML_RANKER.md) 的 `CandidateRanker.mlmodel`
- 後續可擴到 `en` / `ja`

## 1. 產物

訓練腳本最終必須輸出：

- `artifacts/CandidateRanker.mlmodel`
- `artifacts/metrics.json`
- `artifacts/feature_schema.json`

建議另外輸出：

- `artifacts/train_config.json`
- `artifacts/label_stats.json`

## 2. 建議腳本位置

建議新增：

- `fastChIME/scripts/train_candidate_ranker.py`

若拆檔，可包含：

- `fastChIME/scripts/ranker_dataset.py`
- `fastChIME/scripts/ranker_features.py`
- `fastChIME/scripts/ranker_export.py`

## 3. 執行方式

建議 CLI：

```bash
python3 fastChIME/scripts/train_candidate_ranker.py \
  --train data/ranker/train.jsonl \
  --valid data/ranker/valid.jsonl \
  --output fastChIME/artifacts
```

可選參數：

```bash
--epochs 20
--batch-size 256
--learning-rate 1e-3
--hidden-sizes 128,64
--seed 42
--top-k 12
```

## 4. 輸入資料格式

先用 `jsonl`。

每行代表一個 candidate training sample：

```json
{
  "language_id": "zh-Hant",
  "all_tokens": ["ㄋㄧ", "ㄒㄧㄢˋㄗㄞˋ"],
  "combined_token": "ㄒㄧㄢˋㄗㄞˋ",
  "focused_token": "ㄒㄧㄢˋㄗㄞˋ",
  "preceding_values": ["你"],
  "following_tokens": [],
  "candidate_surface": "現在",
  "candidate_reading_or_token": "ㄒㄧㄢˋㄗㄞˋ",
  "span_start": 1,
  "span_length": 1,
  "provider_score": -1.0,
  "base_rank": 0,
  "label": 1.0
}
```

負樣本範例：

```json
{
  "language_id": "zh-Hant",
  "all_tokens": ["ㄋㄧ", "ㄒㄧㄢˋㄗㄞˋ"],
  "combined_token": "ㄒㄧㄢˋㄗㄞˋ",
  "focused_token": "ㄒㄧㄢˋㄗㄞˋ",
  "preceding_values": ["你"],
  "following_tokens": [],
  "candidate_surface": "西岸在",
  "candidate_reading_or_token": "ㄒㄧㄢˋㄗㄞˋ",
  "span_start": 1,
  "span_length": 1,
  "provider_score": -2.0,
  "base_rank": 1,
  "label": 0.0
}
```

## 5. Label 定義

第一版用 binary relevance 即可：

- `1.0`：正確候選
- `0.0`：錯誤候選

之後可升級成：

- pointwise score regression
- pairwise ranking
- listwise ranking

但第一版先用 pointwise binary 即可。

## 6. Feature 編碼要求

訓練腳本產出的 feature 順序必須完全對齊 [`COREML_RANKER.md`](COREML_RANKER.md)。

固定 48 維：

1. `base_rank`
2. `provider_score`
3. `span_length`
4. `candidate_length`
5. `token_length`
6. `preceding_count`
7. `following_count`
8. `exact_token_match`
9. `same_language`
10. `is_phrase`
11. `has_tone_marks`
12. `normalized_match`
13. `span_start`
14. `focused_token_length`
15. `all_tokens_count`
16. `script_han`
17. `script_latin`
18. `script_kana`
19. `script_mixed`
20. `script_other`
21. `lang_zh_hant`
22. `lang_en`
23. `lang_ja`
24. `lang_other`
25. `preceding_recent_count`
26. `preceding_total_chars`
27. `preceding_han_count`
28. `preceding_mixed_count`
29. `following_recent_count`
30. `following_total_chars`
31. `following_zh_count`
32. `following_latin_count`
33. `preceding_last_length`
34. `preceding_last_han_ratio`
35. `preceding_last_hash`
36. `preceding_second_hash`
37. `following_first_length`
38. `following_first_han_ratio`
39. `following_first_hash`
40. `following_second_hash`
41. `preceding_focused_overlap`
42. `focused_following_overlap`
43. `preceding_focused_hash`
44. `focused_following_hash`
45. `left_context_hash`
46. `right_context_hash`
47. `context_asymmetry`
48. `boundary_match_score`

要求：

- 訓練端 feature encoder 必須和 Swift 端邏輯一致
- 若訓練端另行實作，必須輸出 `feature_schema.json` 供比對

## 7. 建議模型

第一版建議：

- MLP
- input dim = 48
- hidden sizes = `[128, 64]`
- activation = `ReLU`
- output dim = 1

建議 loss：

- `BCEWithLogitsLoss`

推論時：

- output 越小或越大都可以，但要和 Swift 端排序方向一致
- 建議直接輸出「越小越好」的 score

## 8. 訓練框架建議

優先順序：

1. PyTorch 訓練
2. 匯出 ONNX 或 TorchScript
3. 轉成 Core ML

或：

1. scikit-learn MLP
2. 直接轉 Core ML

若只求最小可用：

- scikit-learn / PyTorch 皆可
- 模型小，重點是 export 穩定

## 9. Core ML 匯出要求

匯出後必須符合：

- input name: `features`
- input type: `MLMultiArray`
- input shape: `[48]`
- output name: `score`

建議部署格式：

- `CandidateRanker.mlmodel`

再由本機用 `coremlc` 編譯為：

- `CandidateRanker.mlmodelc`

## 10. 驗證指標

至少輸出：

- validation loss
- top-1 accuracy
- top-3 hit rate
- mean reciprocal rank

對 IME 最有用的指標：

- top-1 accuracy
- MRR

## 11. 資料來源建議

第一版可以混用：

- 現有 selftest 句子反推 sample
- 真實輸入紀錄轉 sample
- 使用者 override / commit 歷史

樣本產生方式：

1. 對每個 focus span 取 top-k 候選
2. 被選中的標 `1`
3. 其他標 `0`

## 12. 負樣本策略

第一版建議：

- 同一個 focus span 的 top-k 候選中，除正解外皆為負樣本

之後可加入：

- hard negatives
  例如「現在 / 西岸在」
- cross-language negatives
  例如英文 token 下混入中文候選

## 13. 最低可用版本

最低可用腳本只要做到：

1. 讀 `jsonl`
2. 轉 32 維 features
3. 訓練小型 MLP
4. 匯出 `CandidateRanker.mlmodel`
5. 寫出 `metrics.json`

這樣就可以先把真正 Core ML 路徑跑通。

## 14. 後續擴充

第二版可加入：

- 多語共同訓練
- shared backbone + language-specific head
- pairwise ranking loss
- 使用者個人化 bias
- online fine-tuning 或重新校正

## 15. 注意事項

- 不要讓模型依賴可變長 token 序列直接進網路，第一版先固定 feature vector
- 不要先做 transformer，對 IME 延遲不划算
- 不要讓匯出後的 input/output name 漂移，否則 Swift 端會直接 fallback

## 目前進度

目前已完成：

- `fastChIME/scripts/train_candidate_ranker.py`
- 本機可直接從 `jsonl` 訓練並匯出 `.mlmodel`
- 已完成 `expanded` 與 `x4` 兩輪訓練
- 已用 `coremlc` 編譯 `.mlmodelc` 並接進 app bundle

目前實際模型路線：

- 訓練：`GradientBoostingRegressor`
- 匯出：`coremltools.converters.sklearn.convert(...)`
- runtime：`CoreMLCandidateRanker`

後續若要回到小型 MLP，需另補可穩定匯出 Core ML 的訓練／轉換路線。
