# External Ranker Hooks

這份文件定義未來 skill / 外部工具要呼叫的兩條穩定入口。

## 1. 重新訓練

```bash
python3 fastChIME/scripts/retrain_ranker.py \
  --train data/ranker_x10_iter2/train.jsonl \
  --valid data/ranker_x10_iter2/valid.jsonl \
  --test data/ranker_x10_iter2/test.jsonl \
  --output fastChIME/artifacts/manual_retrain \
  --backend tree \
  --neighbor-noise-weight 0.35 \
  --install
```

用途：

- 直接重訓 ranker
- 輸出新的 `CandidateRanker.mlmodel`
- 若加 `--install`，會自動安裝到外部模型路徑
- `--backend tree` 是目前可直接執行的 baseline
- `--backend mlp` 預留給 PyTorch 小型 MLP 路線，目標是更接近 Core ML / ANE 友善模型
- 若要求 `--backend mlp` 但環境缺少 PyTorch，訓練會自動 fallback 回 `tree`
- `--neighbor-noise-weight` 會加入「按到隔壁鍵」的鄰鍵噪音訓練樣本

## 2. 換權重

```bash
python3 fastChIME/scripts/install_ranker_model.py \
  fastChIME/artifacts/manual_retrain/CandidateRanker.mlmodel
```

或：

```bash
python3 fastChIME/scripts/install_ranker_model.py \
  /path/to/CandidateRanker.mlmodelc
```

預設安裝位置：

- `~/Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc`

## 3. Runtime 載入規則

app 啟動時只會從外部位置讀模型：

1. `UNIFYIME_RANKER_MODEL_PATH`
2. `~/Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc`
3. `~/.fastchime/Models/CandidateRanker.mlmodelc`

停用 Core ML：

```bash
UNIFYIME_DISABLE_COREML_RANKER=1
```

查看目前實際載入模型：

```bash
src/unifyIME/build/全一輸入法.app/Contents/MacOS/UnifyIME ranker-status
```
