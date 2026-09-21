"""訓練資料、checkpoint 與 Core ML metadata 的特徵契約。"""

LEGACY = "legacy_segments_v1"
BOUNDED = "bounded_segments_v2"
METADATA_KEY = "unifyime.feature_contract"
SUPPORTED = {LEGACY, BOUNDED}


def validate_contract(value):
    if not isinstance(value, str) or value not in SUPPORTED:
        raise ValueError(f"不支援的特徵契約：{value!r}")
    return value


def dataset_contract(*datasets, untagged_contract=None):
    # 未標記的資料可能已經是局部座標；不能僅憑維度猜成 legacy。
    # 歷史資料須由呼叫端明確指定，checkpoint 與舊模型則保留原有 legacy 相容規則。
    contracts = {
        validate_contract(row.get("feature_contract", untagged_contract))
        for rows in datasets for row in rows
    }
    if len(contracts) != 1:
        raise ValueError(f"訓練／驗證／測試資料必須使用同一特徵契約：{sorted(contracts)}")
    return contracts.pop()


def require_checkpoint_contract(checkpoint, expected):
    actual = validate_contract(checkpoint.get("feature_contract", LEGACY))
    if actual != validate_contract(expected):
        raise ValueError(f"checkpoint 特徵契約 {actual} 與資料集 {expected} 不相容")


def model_contract(model):
    # 未標記的歷史權重不得直接改成新契約。
    return validate_contract(getattr(model, "unifyime_feature_contract", LEGACY))


def stamp_coreml_contract(mlmodel, model):
    mlmodel.user_defined_metadata[METADATA_KEY] = model_contract(model)
