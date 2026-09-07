# CLI 模擬輸入測試盤點與交接

日期：2026-09-05。本文件是靜態檢視結果；以下案例數不代表本次動態測試通過數。

## 執行限制

- 僅測試本機 CLI，不安裝、切換或重載系統輸入法，不操作 GitHub。
- 測試人員不修改正式程式；回報可重現步驟，由開發人員修正。
- 避免寫入現用輸入法的個人詞頻、偏好設定或模型；需要測試資料時使用獨立暫存目錄。

## 現有入口

| 入口 | 實際範圍 | 主要限制 |
| --- | --- | --- |
| `selftest` | 讀音序列組合後解析文字 | 並未走完整按鍵事件；非 full 模式截取前 10 筆 |
| `ime-action-replay`、`ime-action-batch-replay` | IMEProbeEngine 模擬 raw、方向鍵、選字、刪除等動作 | 模擬器與正式 SessionCtl 各自維護狀態與事件處理 |
| `raw_selftest.py` | zh 100、en 100、mix 200 筆 | 從期望句反查按鍵，會加入 Enter；只比對最後文字 |
| `mixed_live_smoke.py` | 21 筆連續中英混打 | 14 筆逐字送入，7 筆整串 raw；只比對最後文字 |
| `web_mixed_article_smoke.py` | 40 筆長句 | 可用 `--full-incremental`；探索案例失敗預設不造成整體失敗，需 `--strict` |
| `fast_cursor_regression.py` | 5 筆插入、5 筆刪除 | Python 自行拼接字串與查表，沒有呼叫 Swift CLI，不能代表輸入法游標測試 |

## 靜態確認的問題

1. **測試產物不一致**：三個主要 Python runner 固定使用 `bin/app/全一輸入法.app/Contents/MacOS/UnifyIME`；目前只有 `bin/cli/UnifyIMECLI` 存在。因此直接啟動 runner 無法測到剛建置的 CLI。交接階段可在暫存測試驅動中載入 runner 並覆寫其 APP 變數，不修改正式腳本或偽造 app 安裝。
2. **Escape 語意錯誤**：`performIMEProbeAction` 的 `.esc` 呼叫 `reset()`，連已提交文字也清空；同檔 `handleStandaloneRawInput` 的 `<esc>` 卻還原 undo snapshot。正式 `SessionCtl` 的 keyCode 53 也走還原前一步。模擬器與正式行為不一致。
3. **錯誤可能被當作成功**：batch 入口用 `compactMap` 靜默略過無效 JSON；缺少或非字串陣列的 `row_keys` 退成空陣列；batch 即使輸出 error 最後仍回傳 0。`raw_selftest.py` 全數 unresolved 時亦可能回傳 0；mixed/web runner 只比文字，沒有檢查 payload error。
4. **提交狀態沒有被驗證**：batch 的 text 同時包含已提交及組字文字。runner 不檢查 `has_composition`；即使 Enter 未真正提交，文字一樣就可能通過。raw runner 額外 `.strip()` 並刪除 `❚`，可能掩蓋空白或字元錯誤。
5. **測試範圍受反查結果限制**：由期望文字與現有詞庫產生按鍵，無法反查者跳過；中文音節、英文片段並不一定逐實體按鍵送入，生成器加入 Enter 也會縮短連續混打範圍。
6. **游標測試失真與舊路徑**：fast_cursor_regression 指向不存在的 `src/fastChIME/Resources`，且可能讀寫個人 Application Support 的反查快取。其 Python 模型不驗證候選鎖定、raw buffer、實際左右移動或組字刪除。插入案例「你現在可以」的 cursor=2 與預期插在「你現在」後也不一致。
7. **模擬器無法覆蓋正式時序**：正式 SessionCtl 有延後 replay、取消排程及 prefix cache，IMEProbeEngine 則同步重建。CLI 通過無法证明快速打字、停頓、切換 client、NSEvent 修飾鍵及 IMK marked-text 行為正確。
8. **其他漏測與穩定性問題**：非 full selftest 即使指定較大數量仍只取 10 筆；raw runner 使用固定暫存檔名且未清理，並行執行會互相覆寫；整批 timeout 與總耗時無法定位單鍵延遲尖峰。parseIMEProbeAction 將 `left:abc`、`choose:0` 等錯誤參數改成 1，會掩蓋案例格式錯誤。

## 動態測試交付範圍

1. 記錄 CLI 檔案與來源版本資訊、ranker 狀態；不得以舊文件的 PASS 數當成本次結果。
2. 用目前 CLI 執行 21 筆 mixed smoke、400 筆 raw regression，再執行 40 筆 web 案例，分開記錄 regression、explore、skip 與 setup failure。長句完整逐鍵模式採有界時間，超時個別列出。
3. 加上小型手工 raw 動作：連續中英切換、未完成音節或英文、Enter 前後狀態、左右移動後插入、Backspace/Delete、上下選字與 choose、Escape 還原與保留已提交文字、空白與標點、長句逐鍵與整串輸入對照。
4. 驗證錯誤協定：無效 JSON、錯誤 row_keys、未知動作、非法次數、空案例集及重複 row_id；同時記錄退出碼和輸出 error。
5. 逐項回報命令／row_keys、預期、實際、退出碼、是否仍組字、耗時及可重現次數。區分產品錯誤、模擬器差異、測試工具缺陷與缺少資源。
6. 將報告回傳給「輸入法-開發」任務，由開發修正後再安排相同案例複驗。
