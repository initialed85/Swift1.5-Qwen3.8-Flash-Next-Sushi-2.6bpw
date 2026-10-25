# KLD measurements

Source: `sushi kld compare`, schema `mlx-serve-kld-compare-v1`, 4 rows. Fixture protocol: standard4 (2 code + 2 prose, raw text, no chat template), 512 greedy tokens per prompt, top-k 10, ctx 8192, teacher arms bf16 KV.

| fixture | row (fixture → student) | KLD all | KLD to first EOS | top-1 | top-1 to EOS | NLL | NLL to EOS | cos loss | positions | student KV |
|---|---|---|---|---|---|---|---|---|---|---|
| standard4 | ours → itself | 0.0000 | 0.0000 | 100.00 % | 100.00 % | 0.2794 | 0.4478 | -0.0000 | 2048 / 956 | bf16 |
| standard4 | theirs → itself | 0.0000 | 0.0000 | 100.00 % | 100.00 % | 0.2707 | 0.3093 | -0.0000 | 2048 / 1286 | bf16 |
| standard4 | ours fixture → theirs | 0.0794 | 0.0954 | 90.62 % | 85.77 % | 0.3539 | 0.5422 | 0.0442 | 2048 / 956 | affine8 |
| standard4 | theirs fixture → ours | 0.0726 | 0.0758 | 92.09 % | 91.45 % | 0.3178 | 0.3539 | 0.0429 | 2048 / 1286 | affine8 |

Self rows (a pack against its own fixture, same binary and arms) are the harness check: they must read 0 KLD and 100 % top-1. Cross rows between two packs of two **different models** are a divergence fingerprint, not a KLD-to-teacher, and are not comparable with sushi's published 16x512 wikitext readings. Students in cross rows carry the served kv8 penalty; self rows do not.

## Per-prompt detail (to first EOS)

| row | code-python-topological-sort | code-zig-byte-reader | prose-water-cycle | prose-navigation |
|---|---|---|---|---|
| standard4__self-ours | 0.0000 / 100.00 % | 0.0000 / 100.00 % | 0.0000 / 100.00 % | 0.0000 / 100.00 % |
| standard4__self-theirs | 0.0000 / 100.00 % | 0.0000 / 100.00 % | 0.0000 / 100.00 % | 0.0000 / 100.00 % |
| standard4__ours-fixture-vs-theirs | 0.0185 / 98.56 % | 0.0432 / 95.49 % | 0.1224 / 80.47 % | 0.1175 / 83.72 % |
| standard4__theirs-fixture-vs-ours | 0.0478 / 95.51 % | 0.0373 / 97.27 % | 0.1082 / 86.17 % | 0.1272 / 84.51 % |

Cells are `KLD / top-1 agreement`.

csv -> measurements/kld/table.csv
