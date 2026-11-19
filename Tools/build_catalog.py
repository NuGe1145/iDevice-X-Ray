#!/usr/bin/env python3
"""生成机型库。

数据来源：
  - ipsw.me/v4/devices      全部机型的 identifier 清单（权威、更新及时）
  - api.appledb.dev/device  官方营销名、SoC、发布时间、机型编号

人工核对过的规格（屏幕尺寸、分辨率、PPI、电池设计容量）写在 CURATED 里逐条维护；
没有人工核对的一律留空，App 会显示「未收录」并说明原因，不用推断值填充。

用法：
    python3 Tools/build_catalog.py            # 用缓存，缺的才联网
    python3 Tools/build_catalog.py --refresh  # 全部重新拉取
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "iDeviceXRay/Core/Catalog/Resources/devices.json")
CACHE = os.path.join(ROOT, "Tools/cache")
APPLE_DB = "https://api.appledb.dev/device/{}.json"
IPSW = "https://api.ipsw.me/v4/devices"
UA = {"User-Agent": "iDeviceX-Ray-catalog-builder/1.0"}


def get_json(url, timeout=25, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt == retries - 1:
                return None
            time.sleep(1.5 * (attempt + 1))
    return None


def fetch_device(identifier, refresh=False):
    path = os.path.join(CACHE, f"{identifier.replace(',', '_')}.json")
    if not refresh and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    data = get_json(APPLE_DB.format(identifier))
    if data:
        os.makedirs(CACHE, exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
    return data


def main():
    refresh = "--refresh" in sys.argv

    with open(CATALOG, encoding="utf-8") as handle:
        current = json.load(handle)
    curated = {item["identifier"]: item for item in current.get("devices", [])}

    print(f"已有机型 {len(curated)} 条，拉取 ipsw.me 清单…")
    devices = get_json(IPSW)
    if not devices:
        sys.exit("ipsw.me 拉取失败，改用缓存或稍后重试")

    identifiers = sorted({
        item["identifier"] for item in devices
        if item.get("identifier", "").startswith(("iPhone", "iPad"))
    })
    print(f"待处理 {len(identifiers)} 个机型标识")

    new_identifiers = [i for i in identifiers if i not in curated]
    print(f"其中新增 {len(new_identifiers)} 个，逐个查询 AppleDB…")

    with ThreadPoolExecutor(max_workers=8) as pool:
        details = list(pool.map(lambda i: (i, fetch_device(i, refresh)), new_identifiers))

    failed = [i for i, d in details if not d]
    resolved = {i: d for i, d in details if d}
    if failed:
        print(f"有 {len(failed)} 个查询失败，这些机型将只保留标识符：{', '.join(failed[:5])}…")

    merged = []
    for identifier in identifiers:
        base = dict(curated.get(identifier, {}))
        detail = resolved.get(identifier) or {}

        name = base.get("name") or detail.get("name")
        if not name:
            continue

        chip = base.get("chip") or detail.get("soc")
        released = detail.get("released") or ""
        if isinstance(released, list):
            released = released[0] if released else ""
        released = str(released)[:4]

        entry = {
            "identifier": identifier,
            "name": name,
            "family": "iPad" if identifier.startswith("iPad") else "iPhone",
            "chip": chip,
            "ramGB": base.get("ramGB"),
            "screenInches": base.get("screenInches"),
            "nativeWidth": base.get("nativeWidth"),
            "nativeHeight": base.get("nativeHeight"),
            "ppi": base.get("ppi"),
            "refreshRate": base.get("refreshRate"),
            "panelType": base.get("panelType"),
            "batteryDesignMah": base.get("batteryDesignMah"),
            "releaseYear": base.get("releaseYear") or (int(released) if released.isdigit() else None),
            "modelNumbers": detail.get("model") or base.get("modelNumbers"),
            "specSource": "curated" if base.get("ppi") else "name-only",
        }
        merged.append(entry)

    merged.sort(key=lambda item: (item["family"], item["name"], item["identifier"]))

    payload = {
        "version": time.strftime("%Y.%m", time.gmtime()) + " · AppleDB + ipsw.me",
        "deviceCount": len(merged),
        "curatedCount": sum(1 for item in merged if item["specSource"] == "curated"),
        "devices": merged,
    }
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"写入 {len(merged)} 条机型（完整规格 {payload['curatedCount']} 条）")
    for identifier in ("iPad13,16", "iPhone18,1"):
        hit = next((d for d in merged if d["identifier"] == identifier), None)
        if hit:
            print(f"  {identifier} → {hit['name']} / {hit['chip']} / {hit['releaseYear']}")


if __name__ == "__main__":
    main()
