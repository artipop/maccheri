# /// script
# requires-python = ">=3.11"
# ///
"""Сводит JSON-результаты bench.py в markdown-таблицу.

Первый файл — база; для остальных печатается отношение к ней.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

METRICS = [
    ("Prompt, tok/s", lambda r: r["inference"]["best"]["prompt_tps"]),
    ("Генерация, tok/s", lambda r: r["inference"]["best"]["generation_tps"]),
    ("Пик памяти (инференс), ГБ", lambda r: r["inference"]["best"]["peak_memory_gb"]),
    ("Загрузка модели, с", lambda r: r["inference"]["load_s"]),
    ("LoRA, it/s", lambda r: r["lora"]["it_per_s"]),
    ("LoRA, tok/s", lambda r: r["lora"]["tokens_per_s"]),
    ("Пик памяти (LoRA), ГБ", lambda r: r["lora"]["peak_memory_gb"]),
]


def value(fn, r):
    try:
        return fn(r)
    except (KeyError, TypeError):
        return None


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: compare.py base.json [other.json …]")
    runs = [json.loads(Path(p).read_text()) for p in sys.argv[1:]]
    base = runs[0]

    header = ["Метрика"] + [r["label"] for r in runs]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for name, fn in METRICS:
        b = value(fn, base)
        cells = [name]
        for r in runs:
            v = value(fn, r)
            if v is None:
                cells.append("—")
            elif r is base or not b:
                cells.append(f"{v:.2f}")
            else:
                cells.append(f"{v:.2f} ({v / b:.0%})")
        print("| " + " | ".join(cells) + " |")

    print()
    for r in runs:
        e = r["env"]
        print(
            f"- **{r['label']}**: {e['chip']}, {e['cpus']} CPU, {e['memory_gb']} ГБ, macOS {e['macos']}, "
            f"virtualized={e['virtualized']}, Metal={e['metal']} ({e['gpu'] or '—'}), mlx {e['mlx']}, модель {r['model']}"
        )


if __name__ == "__main__":
    main()
