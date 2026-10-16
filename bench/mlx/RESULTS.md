# MLX: хост и macOS VM

Модель `mlx-community/Qwen2.5-0.5B-Instruct-4bit`, генерация 256 токенов (лучший из 3 прогонов), LoRA: 8 слоёв, batch 4, 60 итераций.

| Метрика | host |
|---|---|
| Prompt, tok/s | 2005.92 |
| Генерация, tok/s | 278.94 |
| Пик памяти (инференс), ГБ | 0.37 |
| Загрузка модели, с | 1.31 |
| LoRA, it/s | 2.99 |
| LoRA, tok/s | 1237.00 |
| Пик памяти (LoRA), ГБ | 1.60 |

- **host**: Apple M4, 10 CPU, 16.0 ГБ, macOS 27.0.1, virtualized=False, Metal=True (Apple M4), mlx 0.32.4, модель mlx-community/Qwen2.5-0.5B-Instruct-4bit

Прогона в VM пока нет: macOS-гостю нужно 60–80 ГБ диска (см. `images/README.md`).
Когда VM появится, запустите внутри гостя:

    uv run bench/mlx/bench.py --label vm --out bench/mlx/results/vm.json
    uv run bench/mlx/compare.py bench/mlx/results/host.json bench/mlx/results/vm.json

Главное, что нужно проверить: `Metal=True` у гостя (паравиртуализированный GPU) и какая доля от
скорости хоста остаётся у генерации и LoRA.
