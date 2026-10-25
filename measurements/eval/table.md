# Task-level eval

Tool: llmprobe (Apache-2.0, `ddalcu/llmprobe`), version 0.6.12. Graded at temperature 0; the code deck is graded by executing the model's function against the ported asserts (3 s cap, `node:vm`), the reasoning decks by normalised `Answer:` line matching against the published answer and its listed equivalent forms. A question that hits the output cap with no answer line is counted as *out of tokens* and reported apart from wrong.

| model | suite | passed | score | out of tokens | errors | effort | cap | conc | sampling | output tok | reasoning tok/q | wall |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw | code | 86/100 | **86.0 %** | 0 | 0 | medium | 16000 | 2 | greedy t=0 (llmprobe default) | 165338 | 1544.3 | 6018.6 s |
| beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw | hard | 36/50 | **72.0 %** | 1 | 0 | xhigh | 16000 | 2 | greedy t=0 (llmprobe default) | 189870 | 3720.8 | 7792.0 s |
| initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw | code | 81/100 | **81.0 %** | 0 | 0 | medium | 16000 | None | greedy t=0 | 66332 | None | 2088.9 s |
| initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw | hard | 36/50 | **72.0 %** | 2 | 0 | xhigh | 16000 | 2 | greedy t=0 (llmprobe default) | 154423 | 3001.5 | 5240.3 s |

## Per source

| model | suite | HumanEval | LiveBench | MBPP | MMLU-Pro | NIST Juliet | OlympiadBench |
|---|---|---|---|---|---|---|---|
| beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw | code | 49/50 | - | 37/50 | - | - | - |
| beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw | hard | - | 4/5 | - | 27/30 | 5/5 | 0/10 |
| initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw | code | 48/50 | - | 33/50 | - | - | - |
| initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw | hard | - | 3/5 | - | 28/30 | 5/5 | 0/10 |

Suites are not comparable to each other (llmprobe says so explicitly: *Hard runs are reported as such and are not comparable to core runs*). A `--sampling` preset run is not comparable to a greedy run. Two rows are only comparable when effort, output cap, KV quantisation and MTP match — read the arms columns before comparing any two rows.

csv -> measurements/eval/table.csv
