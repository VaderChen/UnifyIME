# NN 候選排序模型

此目錄保存已完成訓練的 CandidateRanker 模型成品，可搭配 UnifyIME 的 Core ML 候選排序介面使用。

| 檔案 | 用途 |
| --- | --- |
| `CandidateRanker.mlpackage` | Core ML 推論模型，內含模型定義與權重 |
| `ranker_checkpoint.pt` | 已訓練權重 checkpoint，保留模型與最佳權重狀態 |
| `feature_schema.json` | 模型架構與輸入維度規格 |

架構為 `dense_mlp_v2`，輸入特徵維度為 88，對應程式中的 `RankingFeatureVector.expectedDimension`。候選排序仍以規則結果為基礎，由 NN 提供有界輔助；未載入模型時會使用規則式排序。

模型特徵還需符合前文與座標格式，不能只憑維度判定相容。Core ML 自訂 metadata `unifyime.feature_contract` 可指定 `legacy_segments_v1`（片段前文、整句座標及最多六個後文音節）或 `bounded_segments_v2`（片段前文及局部座標）。未標記的既有模型使用 legacy 相容模式，未知格式回退規則；新模型匯出時應依實際訓練資料標記格式，不能只替舊權重改標籤。詳見 [計分文件](../doc/SCORING.md)。

## 在 macOS 載入

此目錄提供可自行評估的模型成品，正式安裝檔不自動啟用此模型。模型對特定詞句可能產生不合預期的排序，載入不代表準確率必定提高。外部模型優先於 app 資源內的模型；沒有可用模型時使用規則排序。

將 Core ML 套件編譯至輸入法的外部模型目錄：

```sh
mkdir -p "$HOME/Library/Application Support/UnifyIME/Models"
xcrun coremlcompiler compile models/CandidateRanker.mlpackage "$HOME/Library/Application Support/UnifyIME/Models"
```

產生的 `CandidateRanker.mlmodelc` 會在輸入法下次啟動時載入。也可用 `UNIFYIME_RANKER_MODEL_PATH` 指定已編譯模型路徑。模型置於獨立目錄，不會因更新 app 而自動覆寫個人模型設定。
