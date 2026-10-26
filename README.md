---
license: other
license_name: swift-open-license-1.0
license_link: LICENSE
base_model: ukisai/Swift1.5-Qwen3.8-Flash-Next
base_model_relation: quantized
pipeline_tag: image-text-to-text
github_repo: https://github.com/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
title: Swift 1.5 Qwen3.8-Flash-Next — Sushi 2.6bpw
images:
- ukisai-banner.png
video:
- swift-1.5-flash-next-demo.mp4
tags:
- sushi
- exl3
- apple-silicon
- mlx
- qwen4_exp
- moe
- quantization
- swift-1.5
---

# Swift 1.5 Qwen3.8-Flash-Next — Sushi pack (2.6bpw)

Unofficial, community-built [sushi](https://github.com/beamivalice/sushi) pack of
[ukisai/Swift1.5-Qwen3.8-Flash-Next](https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next),
quantised to EXL3 **k = 2.625 bpw on the routed experts** — 180 B parameters in 79.26 GB, i.e.
**≈3.52 bits/weight overall** (the 47.26 GB of safetensors hold the 128.9 B parameters outside the n-gram
table at **2.94 bits/weight**, see the Parameter count section below) — on a single 64 GB Apple Silicon Mac.

**Not affiliated with UkisAI or with beamster.** Weights are the property of their respective
copyright holders (UkisAI, Qwen); this repository is a conversion under the terms of the
[Swift Open License v1.0](LICENSE) and the [Qwen Community License 1.0](LICENSE-QWEN).
Read [`NOTICE-CONVERSION.md`](NOTICE-CONVERSION.md) for the full attribution and change notice.

## Getting it

**`sushi pull` cannot fetch this repo.** `pull` takes a short name (`qwen3.8-flash-next[:tag]`) or
`beamster/<repo>` and accepts **only** packs of the Hugging Face org `beamster`; any other
`org/repo` exits with an error before anything downloads, and `sushi run` follows the same rule
when it has to download. So publish under your own name, and install by hand into the tree sushi
scans:

```bash
hf download initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw \
  --local-dir ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
~/sushi-macos-arm64/sushi --model ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw \
  --prompt "Hello, Swift."
```

The path is under `~/.sushi/models/initialed85/…`, **not** `~/.sushi/models/beamster/` — sushi scans
that tree one directory per org, and `serve --model <path>` takes the explicit path, so the served
model id follows the directory name (`initialed85/Swift1.5-…`, as in the `/v1/models` sample above).
What you *cannot* do is address this pack by short name: name resolution only knows beamster's packs,
which is where `sushi pull` writes them. Serving needs the GPU wired-limit sysctl first:
[`docs/BUILD.md` → Serving it](docs/BUILD.md).

Install sushi (there is no `sushi.sh` installer):
```bash
brew install beamivalice/tap/sushi
# or the release tarball (ad-hoc signed; curl does not quarantine it)
curl -L https://github.com/beamivalice/sushi/releases/latest/download/sushi-bin-macos-arm64.tar.gz | tar xz
# a browser download is quarantined: xattr -dr com.apple.quarantine sushi-macos-arm64
```

## What this is

| part | how it is stored |
|---|---|
| routed experts (48 layers × 512, plus the MTP head) | **EXL3, 2.625 bpw** (`--experts-k 2.625` = "2.6bpw"), codebook **`mcg`**, window **15**, `ldlq-rotated`, `svh` output scales |
| dense part (attention, GatedDeltaNet, shared experts, hyper-connections, indexer, embedding, lm_head) | 8-bit affine, 64-row groups (`trunk=8/64`) |
| n-gram embedding table | 4-bit affine, group 32, one 32.0 GB file `ngram_table.bin` (29.8 GiB), read from SSD, never wired into GPU memory |
| vision tower (Qwen3-VL ViT) | included — image and video input work |
| MTP head | included — speculative decoding |
| context | native **262,144** tokens, **no YaRN** (see [Context](#context-and-the-differences-from-the-official-pack)) |
| size | **73.85 GiB** = 79.30 GB across 69 files: 47 261 167 608 B of safetensors payload (52 shards, 47.26 GB on disk) + 32.00 GB n-gram table + tokenizer and card |
| shards | 52 files, 3 069 tensors |

Runtime requirement: **sushi ≥ 1.3.0** (this build used 1.3.0; the `mcg` codebook, `n42` GEMM body
and `qwen-gdn` kernels are 1.3.x), Apple Silicon, macOS 26.2+. **sushi only** — does not load in
transformers, vLLM, mlx-lm, llama.cpp or exllamav3.

## Parameter count — the Hub's "26 B params" is not a parameter count

The auto-generated **Safetensors** section on this page reports **25 959 006 099 “parameters” (≈26 B) —
that figure is wrong for this model, and it is not something I can set.** HF counts *stored tensor
units* in the safetensors headers, and this pack's tensors are Sushi-packed blocks, so units ≠
parameters. The model is a **≈180 B-parameter MoE**, identical in architecture to the base model it
quantizes; here is the decomposition, computed from the 52 shard headers plus `ngram_table.bin`, and
it lands **0.09 %** off the base model's own authoritative count:

| stored | units in the headers | logical parameters | packing |
|---|---|---|---|
| `U16` (48 layer shards + `mtp-0`) | 20 230 963 200 | **≈123.31 B** | EXL3 experts at k = 2.625 bpw → 16/2.625 = 6.095 weights per 16-bit unit |
| `U32` (3 trunk shards) | 1 241 825 280 | **≈4.97 B** | trunk is **8-bit affine, 64-row groups** (`trunk=8/64`): four 8-bit codes packed per `U32` — e.g. `embed_tokens.weight` is stored `[248320, 640]` U32 for a 2560-wide hidden size. That is why HF's `U32` line reads exactly 4× its element count |
| `BF16` (trunk) | 675 125 104 | **≈0.675 B** | unquantized |
| `F16` | 240 844 800 | **0** | scales / output scales, not weights |
| `I64` | 35 | 0 | bookkeeping |
| `ngram_table.bin` | 32.00 GB | **≈51.20 B** | 20 000 000 × 2560 entries, 4-bit affine group 32 → 32.00 GB ÷ 51.2 B = exactly 5.0 bits/entry with scales |
| **total** | 22 388 758 419 elements (HF tallies 25.96 B, see above) | **≈180.16 B** | base model `ukisai/Swift1.5-Qwen3.8-Flash-Next` counts **179 999 981 424** (360.04 GB of BF16) |

So: **180 B parameters, of which 10 of 512 experts fire per token** — about **2.4 B of expert weights
consulted per token** (10 experts × 3 matrices × 2560 × 640 × 48 layers), at 47.26 GB of safetensors
+ 32.00 GB of n-gram table = 79.26 GB on disk. Dividing that back out: the 128.9 B parameters outside
the n-gram table occupy 47.26 GB, i.e. **2.94 bits/weight**, which is the 2.625 expert rate plus BF16
embeddings/attention and the 8-bit trunk — the arithmetic agrees. Including the table, the whole model
sits at 79.26 GB ÷ 180.16 B = **3.52 bits/weight** (the table itself is 5.0 bits/entry, weights plus scales).

The shard headers carry the recipe verbatim (`__metadata__: {format: exl3, k: 2.625, codebook: mcg,
window: 15, encoder: sushi-encoder-1, quantizer: ldlq-rotated, global_scale_search: on, calib_tokens:
65 536, calib_sha256: 7f2a5b14…}`), so the 16 / 2.625 = 6.095 weights-per-U16 figure comes from the
header's own `k`, not from the name “2.6bpw”.

One caveat on HF's own lines: its `U16`/`F16`/`I64` counts match our headers exactly, its `U32` is 4×
(its units are the packed 8-bit codes), and its `BF16` line is *short* by 155 228 160 units (519 896 944
vs 675 125 104) even though `model.safetensors.index.json` indexes every tensor in every shard. That is
an HF parsing quirk I can reproduce but not explain; it does not affect the arithmetic above, which is
computed from the shard headers themselves.

Two more things the page gets wrong in the same direction, and what I will *not* do about them:
`config.json` declares `quantization_config: {bits: 8, group_size: 64, mode: "affine"}`, which is why
HF shows a “8-bit” chip. That record is sushi's own **dense/affine arm**, written by the converter,
and sushi validates it on load (`unsupported quantization mode '' (supported: affine, nvfp4, mxfp4,
mxfp8)`, `unsupported affine quantization: -bit`) — rewriting `bits` to 2.625 risks an unloadable
pack, so `config.json` stays exactly as the converter wrote it and the card explains it instead.
Same for the tensor shapes: repacking to make HF print 180 B would break the pack. The number to quote
for this model is **≈180 B parameters**.

## Where the three trees live

This pack is published in two trees, deliberately:

| tree | contains | why |
|---|---|---|
| **this HF repo** | 48 layer shards + 1 MTP shard + 3 trunk shards (52 `.safetensors`) + `ngram_table.bin` (79.3 GB), the card, licences, `.gitattributes`, `provenance.json`, `measurements.json`, `measurements/eval/` **manifests + `table.csv` + write-ups**, `scripts/`, `docs/`, `fixtures/` | one `hf download` target: weights plus everything needed to audit and reproduce the claims |
| **the GitHub repo** ([`initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw`](https://github.com/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw)) | the same card, every script with its history, `docs/BUILD.md`, provenance, the aggregate measurement rows — no weights (`.gitattributes` keeps binaries on LFS/Xet if you ever add them) | diffs, history, issues: the place to read and argue about the harness and the build |

Neither tree carries the **case-level** eval reports or the run logs: those embed the benchmark
corpora' questions and published answers (and LiveBench's five are explicitly not ours to publish).
They stay in the working tree; each one is anchored by sha256 in its `*-manifest.json`, which *is*
published. See [`measurements/eval/README.md`](measurements/eval/README.md) for the policy and the
hash table.

## Measured on the build machine

MacBook Pro (Mac14,6) — **Apple M2 Max**, 12 CPU cores (8P+4E), 38 GPU cores, 64 GB, macOS 26.2,
1 TB APFS volume (994.7 GB), hardline ethernet.

| metric | value |
|---|---|
| prefill | **72.7 tok/s** |
| decode | **45.1 tok/s** |
| MTP speculative accept | **81.5 %** (181 accepts / 89 attempts, 2.03 tokens per round, depth 6) |
| preflight | weights **43.44 GB**, needs 45.69 GB, available 58.00 GB → **fits 64 GB** |
| `sushi list` verdict for `qwen3.8-flash-next:2.6bpw` | **fits**, *recommended* tier for this Mac, 73.7 GB published vs **73.85 GiB built** |

Kernels confirmed engaging in the log: `[exl3] n42 funnel … codebook=mcg window=15`,
`[exl3-gemm] simdgroup-matrix body n=42`, `[gdn] packed prework engaged: Hk=16 Hv=48`,
`[attn-pd] sushi_attn_pd`, `[mtp] draft rerank engaged`, `[ngram] speculative decoding engaged`.

Divergence against the official 2.6bpw pack **is** measured — see
[Quality](#quality-what-we-do-and-do-not-claim). KLD against a BF16 teacher of *this* model is not.

### Live in production

Serving verified 2026-10-25 on the same box, after the pack moved to
`~/.sushi/models/initialed85/…` (the served model id follows the directory name):

```bash
$ curl -s http://127.0.0.1:8088/v1/models | jq '.data[0] | {id,loaded,state,bytes_resident,bytes_on_disk,context_length}'
{
  "id": "initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw",
  "loaded": true, "state": "ready",
  "bytes_resident": 47539286008, "bytes_on_disk": 47261601960,
  "context_length": 262144, "max_model_len": 262144
}
```

One behaviour worth knowing: this server **unloads the pack when idle** and reloads on the next
request. An idle `/v1/models` answers `"loaded": false, "state": "unloaded", "bytes_resident": 0`
and reports the pack's native `context_length: 262144`; after a request it reports `ready`,
47.54 GB resident, and the `--ctx-size 131072` the server was started with. The first request
after an idle period pays the load.

`vm_stat` reports ~0.1 GB of *free* pages while serving; that is normal for a 64 GB Mac running a
43 GB pack with an 8 GB disk prefix cache — `vm.memory_pressure: 0` and 94 % system-wide free is
the health signal, not the free-page count.

## The build, start to finish

One converter (`sushi convert exl3`), one machine, no cluster. Wall clock **7 h 55 m** for the
conversion; **1 h 50 m** to download the 360 GB source; total **9 h 45 m** hands-off.

```
12:53  hf download  ukisai/Swift1.5-Qwen3.8-Flash-Next        131 shards, 360.04 GB
12:53 ─ 15:42  download completes (1 h 50 m, avg 59 MB/s on hardline ethernet, ~12 MB/s WiFi)
15:42  tree verify: 148/148 files byte-exact vs HF API
15:45  sushi convert exl3  →  tokenizer load, vocab 248 320, chat template
15:45 ─ 15:47  built-in calibration mix, 65 536 tokens
15:47 ─ 15:54  trunk → affine 8/64 (model-trunk-00000..2.safetensors, 6.32 GB on disk)
15:54 ─ 16:04  n-gram table → 4-bit/g32 (ngram_table.bin, 32.0 GB / 29.8 GiB)
16:04 ─ 23:35  48 expert layers → EXL3 (layer-0..47.safetensors, 836 MB each)
23:35 ─ 23:44  MTP head (mtp-0.safetensors, 836 MB), index, final shard set
23:46  ALL DONE · pack 74G · free 451G
23:47  source deleted, pack integrity verified, smoke test green
```

### Per-layer cost, and where the time goes

48 expert layers, **median 9.4 min/layer**, max 9.5 min (layer 0), total 7.55 h of layer work:

| stage | median / layer | total | share |
|---|---|---|---|
| `search` (trellis / codebook window search) | 354.4 s | 4.75 h | **55.1 %** |
| `scale` (output scales, `svh`) | 88.2 s | 1.18 h | 13.7 % |
| `hessian` (per-expert Hessian build) | 81.7 s | 1.09 h | 12.6 % |
| `prep` (rotation + activation capture) | 79.3 s | 1.06 h | 12.3 % |
| `feedback` | 38.2 s | 0.49 h | 5.7 % |
| `read` + `factor` + `wait` + `pack` | 4.1 s | 0.05 h | 0.6 % |
| **sum of stages** | **646.1 s** | **8.62 h** | — |

`search` is the dominant cost and is memory-bound: the converter keeps the whole layer's
512-expert Hessian set resident, which is why the machine wants ≥ 48 GB RAM and nothing else
big running. `factor` is 0.0 s because `--factor-precision` was left at the default (CPU float64).

### Resource profile (measured, not guessed)

| phase | RSS | wired | disk free | notes |
|---|---|---|---|---|
| download | ~1 GB | low | 524 → 165 GB | 4 workers, resumable, `.incomplete` → published per shard |
| trunk (15:47–15:57) | ~11 GB | ~12 GB | 165 GB | 3 GB RSS in 7 min, ~1.3 GB/s read |
| n-gram (15:54–16:04) | ~28 GB | — | 165 GB | 20 GB in ~1 min, 32 GB written |
| experts (16:04–23:35) | 29–33 GB | 4.5–7 GB | 165 → 111 GB | 512-expert set resident, 9.4 min/layer |
| MTP / lm_head / embed | 32 → 46 GB | 23 → 45 GB | 111 GB | the peak, 51.7/64 GB used, 9 GB free — the tightest moment |
| serving the pack | — | ~46 GB wired | 111 GB | 12 GB free under 26.4 GB of caches |

Disk math for a 64 GB Mac with a 1 TB volume (994.7 GB): peak requirement **401 GB** (360 source +
41 pack mid-build), net cost after cleanup **+74 GB**, free at the end **451 GB**. The binding
constraint is peak, not final size — leave ≥ 60 GB headroom before starting.

## Reproduce it

```bash
scripts/01-download-source.sh   ~/swift15-src   # 360 GB, resumable
scripts/02-verify-source.py     ~/swift15-src   # byte-exact vs HF file tree
scripts/03-convert.sh           ~/swift15-src   ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
scripts/04-verify-pack.py       <pack dir>      # headers, offsets, payload vs on-disk, index closure
scripts/05-smoke-test.sh        <pack dir>      # generate with the pack, assert the sentinel
scripts/06-kld.sh               <pack dir>      # optional KLD vs BF16 teacher (needs source re-download)
scripts/publish.sh              <pack dir>      # HF card files + weights → a repo
scripts/supervise.sh            <pack dir>      # the unattended wrapper that finished this build
```

`scripts/` are the scripts that were actually used, with the knobs promoted to arguments and the
failures we hit hardened into checks. `03-convert.sh` is the whole conversion in six flags.

### The flags, and the one trap

```bash
sushi convert exl3 \
  --model ~/swift15-src \
  --out ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw \
  --experts-k 2.625 \
  --codebook mcg \
  --window 15 \
  --batch 16
```

- **`--experts-k 2.625` is the trap.** "2.6bpw" in sushi's vocabulary is **21⁄8**, and the flag
  accepts a strict 1/8 ladder: `--help` says *"routed-expert rate in bits per weight, 1.5 to 8 in
  steps of 0.125 (default 2.5)"*. Passing `2.6` fails with
  `error: BadFlagValue: --experts-k expects <float>; use 'help' to list valid choices` — the
  *first* run of this build died there. `scripts/03-convert.sh` derives that ladder from the
  binary's help text and refuses off-grid values, printing `2.6 REJECTED; nearest valid 2.625`.
- `--codebook mcg` and `--window 15` are beamster's recipe for the 2.6bpw tier. `--help`:
  codebook is `mcg` or `mul1` (default `mcg`); the window is the trellis search window, **12 to
  16, default 15**. The converter's auto choice for this model is 32, which the flag caps — the
  log shows `expert windows: auto (window 32)` then `expert windows: capped (window 32 -> 15)`.
- `--batch 16` (default) quantises the routed experts **16 banks together**; the range is 1 to 64
  and — per `docs/flags.md` — **the pack bytes do not depend on it**. It is a RAM/throughput knob,
  not a quality knob: raise it if the box has memory to spare, lower it if the layer-resident set
  gets tight. Our 64 GB box ran 16 all the way through.
- `--calib` was left unset: sushi builds in a 64k prose+code mix, `calib_sha256` recorded below.
- `--factor-precision 32` (GPU float32, faster) was deliberately **not** used — it changes pack
  bytes; keeping the default CPU float64 path is what makes this pack comparable in structure to
  the released 2.6bpw tier.
- Resume is real: `--resume` re-reads `convert-progress.json` (`policy`, `trunk_done`,
  `ngram_done`, `ngram_present`) and continues at the layer boundary, not from scratch. The
  unattended wrapper used it.

## Context, and the differences from the official pack

`config.json` in this pack keeps the native `max_position_embeddings: 262144` and
`rope_type: default` — i.e. **no YaRN**. beamster's published packs ship **YaRN ×4 → 1 048 576
tokens**. So:

- At 131 072-token serving contexts (our use, and the Swift README's own Terminal-Bench setup)
  this pack is exactly as advertised.
- For 1M-token contexts, extend at serve time with `--config-overrides` (JSON deep-merged into the
  pack's `config.json` — "the context-extension lever" in `docs/flags.md`), e.g.

  ```bash
  --config-overrides '{"text_config":{"rope_scaling":{"type":"yarn","factor":4.0,"original_max_position_embeddings":262144}}}'
  ```

  262 144 × 4 = 1 048 576. Sushi's YaRN arm refuses without `original_max_position_embeddings`
  (`YarnRopeNeedsOriginalMaxPos`), and it confirms on the log as
  `[rope] YaRN: factor … (window …), rotary … dims, ramp …, mscale …`. No re-conversion needed.

The other difference to be honest about: beamster's pack records `calibration=imatrix-diagonal`
with its own `imatrix_sha256`; this pack records sushi's **built-in** 64k calibration mix.
Same encoder, same codebook, same window, same rate — **different calibration**. Do not expect
bit-identical quality to the released 2.6bpw pack; expect the same rate and encoder.

### Every structural difference we found, verified on disk

Compared against `beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw` downloaded whole (218 files,
79.21 GB) on 2026-10-25:

| | ours | theirs |
|---|---|---|
| `expert_quant` | `exl3 k=2.625 codebook=mcg window=15` | identical |
| top-level `quantization_config` | `bits 8, group_size 64, affine` | identical |
| **trunk linear group size** | inherits **64** (no per-tensor entries) | explicit per-tensor **`{bits: 8, group_size: 128}`** on every trunk linear, shared expert, self-attn, indexer, lm_head, MTP trunk |
| weights in the index | 47.261 GB (44.01 GiB), 3 069 tensors | 47.186 GB (43.95 GiB), 3 070 tensors |
| extra tensor | — | `layers.1.ple.ple_embedding.ngram_embedding.weight_scale` |
| shard layout | 52 shards / 69 files: `layer-N.safetensors`, `mtp-0.safetensors`, embed + lm_head + vision inside the trunk shards | 203 shards / 218 files: `model-exl3-LNN-{gate,up,down}.safetensors`, `model-mtp.safetensors`, `model-embed/lm-head/vision` as separate files |
| context | native 262 144, no YaRN | ships YaRN ×4 → 1 048 576 |
| calibration | sushi built-in 64k mix | `imatrix-diagonal`, their own `imatrix_sha256` |
| n-gram table | 4-bit g32, 29.8 GiB | same file, same table |
| tokenizer | 248 044 base tokens, 33 added tokens | **0 id mismatches** against ours; `vocab.json`/`merges.txt` byte-identical |

The two layout families are both read by sushi 1.3.0 through `model.safetensors.index.json`; the
per-projection layout is the older writer (their KLD rows were measured on binary `ad5e6be8`, ours
built on 1.3.0), so it is version drift, not a fault. The `--trunk-group 128` difference is the one
that would change pack bytes on a rebuild, and it is the likely reason we sit +0.06 GiB heavier.

## Quality: what we do and do not claim

Claimed, and reproducible with `scripts/05-smoke-test.sh` on a 64 GB M2:

- loads and serves in sushi 1.3.0; MTP, `mcg`, `n42`, GDN packed-prework, vision tower all engage;
- 45.1 decode tok/s, 72.7 prefill tok/s, 81.5 % MTP accept;
- sane generations — a from-scratch `fnmatch`-free glob matcher (correct), a 306-token answer,
  `PACK OK` sentinel;
- 47.26 GB payload with 0 header/offset/index defects (`scripts/04-verify-pack.py`).

Not claimed: KLD, perplexity, NLL, or any benchmark score vs the BF16 Swift checkpoint. sushi
ships the tool for exactly that (`scripts/06-kld.sh`), which needs the 360 GB BF16 teacher
present — and we deleted ours after conversion to reclaim the disk. What we *have* measured is
the pack's divergence from the official 2.6bpw of the base model, on identical prompts.

### Measured 2026-10-25 — divergence vs the official 2.6bpw pack

Protocol: sushi's `standard4` fixture (two code + two prose prompts, raw text, no chat template),
512 greedy tokens each, `top-k 10`, `--ctx-size 8192`, teacher arms `--kv-quant off` (bf16),
students scored at the served `--kv-quant 8`, `MLX_ENABLE_TF32=0`, `--qwen-gdn 32 --no-mtp`,
weights resident. Captured from each pack, then each pack scored against each fixture.
Full JSONs and per-prompt detail: [`measurements/kld/table.md`](measurements/kld/table.md).

| fixture → student | arms | KLD all | KLD to first EOS | top-1 to EOS | NLL to EOS | positions to EOS |
|---|---|---|---|---|---|---|
| ours → itself | bf16 | **0.0000** | **0.0000** | **100.00 %** | 0.4478 | 956 |
| theirs → itself | bf16 | **0.0000** | **0.0000** | **100.00 %** | 0.3093 | 1 286 |
| ours fixture → theirs (kv8) | affine8 | 0.0794 | 0.0954 | 85.77 % | 0.5422 | 956 |
| theirs fixture → ours (kv8) | affine8 | 0.0726 | 0.0758 | 91.45 % | 0.3539 | 1 286 |

What that does and does not say:

- **The harness is sound.** Both self rows are exactly 0 KLD, 100 % top-1, cosine loss 0 — the
  capture and the score agree bit for bit on the same binary and arms, so the cross rows are
  measuring the packs and not the tooling.
- **The two packs are close.** On the same four prompts they agree on 86–92 % of content
  positions and sit 0.076–0.095 nats apart. That is a *fingerprint between two different models*
  (Swift 1.5 vs base Qwen, each quantised at 2.6 bpw), not a KLD-to-teacher, and it is not
  comparable with sushi's published 16×512 wikitext readings.
- **Quantisation is the bigger effect than the model swap.** sushi's own 2.6bpw-vs-BF16-teacher
  reading is 0.1355; the whole Swift-vs-base difference at 2.6 bpw is smaller than that on this
  screen. Different fixture, so treat it as indicative — but it is the reason we are comfortable
  shipping at this rate.
- **Our pack ends its turn earlier** on these prompts (956 scored positions before the first EOS
  vs their 1 286). Behavioural, not a quality claim.
- The cross rows carry the served kv8 penalty; the self rows do not. A kv8-armed self row would
  separate the two and has not been run.

Reproduce (server must be stopped — the capture needs ~13 GB of GPU headroom):

```bash
scripts/08-capture.sh            # fixtures -> ~/kld/<pack>/standard4, gated by pack-check.py
scripts/09-compare.sh            # every pack x every fixture -> measurements/kld/*.json
scripts/10-kld-table.py measurements/kld   # the table above
```

### Task-level eval — the claim that needs no teacher

The reading above is capped by hardware. Capability is not: it needs the server and the questions,
not a 360 GB teacher. Packs are scored with **llmprobe** (`ddalcu/llmprobe`, Apache-2.0), which
drives the OpenAI-compatible endpoint, runs everything at **temperature 0** (its default), and
grades deterministically — execution for code, `Answer:`-line matching for the reasoning decks.

| deck | what it is | grading |
|---|---|---|
| `--eval-suite code` | 100 JavaScript functions: 50 HumanEval + 50 MBPP (MultiPL-E ports) | **executes** the model's function against the ported asserts (`node:vm`, 3 s cap) |
| `--eval-suite hard` | 50 questions: 30 MMLU-Pro, 10 OlympiadBench, 5 LiveBench (zebra), 5 NIST Juliet reductions | normalised `Answer:` line vs the published answer and its listed equivalent forms |
| `--eval-suite core` | 92: GPQA Diamond, SuperGPQA, AIME 2025, COMPSEC | as above; **run on this box** — ours landed 69/92 (75.0 %, a floor), theirs produced no report (see the core row below). **Suites are not comparable to each other** (llmprobe's rule, quoted in its README) |

The `hard` deck is the same test behind beamster's card line *"LLMProbe Hard 50 — 88.0 %"*, which
matters because it is the only claim of that kind we could check against someone else's pack —
and it is **not reproduced here** (their pack, our server, arms below: 72.0 %). The source model's
`medium` 0.2078 / `xhigh` 0.2980 GPQA-Diamond figures are reachable with `--eval-suite core` — but
**that suite was not run here**, so those figures are quoted from the source card, not checked.

Arms, pinned, identical for both packs — only `--model` moves:

```bash
llmprobe 0.6.12                 # the version beamster's card reports
--eval-suite code|hard|core    # greedy t=0 (tool default)
code: --reasoning medium        hard+core: --reasoning xhigh   # xhigh is what their card reports
--concurrency 2                 # half the server's --max-concurrent 4; never sat
--eval-max-tokens 16000         # = their card's cap
server: --kv-quant 8 --mtp --ctx-size 131072 --qwen-gdn 16 --expert-pick-tolerance 0.3
```

So a pair of rows measures the pack *as served on this server*, kv8 penalty, 16-lane GDN and
0.3 expert-pick tolerance included — which is what a user of this box gets, and is **not** a
weights-only quality number and **not** a teacher KLD.

### The deck rows, all on arms that match each other

Every row in this card is greedy t=0, effort medium on code / xhigh on hard and core, `--concurrency 2`,
16 k output cap, and the same server flags (`--kv-quant 8 --mtp --qwen-gdn 16 --expert-pick-tolerance 0.3 ...`)
**only `--model` changes between rows**, so a pair of rows in the same deck is a like-for-like
comparison. The code and hard decks both landed for both packs, so they have real like-for-like pairs;
the core row is ours-only for now (see the core section below). Full arms and cost per row are in the
`*-manifest.json` files next to each report (render them with `scripts/12-eval-table.py measurements/eval`).

| pack | code (100) | HumanEval / MBPP | hard (50) | MMLU-Pro / Olympiad / LiveBench / Juliet | wall |
|---|---|---|---|---|---|
| **ours** (`initialed85/…-Sushi-2.6bpw`) | **81/100** | 48/50 · 33/50 | **36/50** | 28/30 · **0/10** · 3/5 · 5/5 | 35 min · 87 min |
| **theirs** (`beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw`) | **86/100** | 49/50 · 37/50 | **36/50** | 27/30 · **0/10** · 4/5 · 5/5 | 100 min · 130 min |

What that says, in the plainest terms I can defend:

- **On the code deck our pack is 5 questions behind theirs** (81 vs 86; the whole gap sits in MBPP,
  33 vs 37 — HumanEval is 48 vs 49). This is a *served* result on this box at 2.6 bpw + kv8, not a
  statement about whose weights are better, but it is a real regression of our conversion against
  theirs on the one axis where both packs are being compared, and the card says so.
- **On the hard deck the two packs tie at 36/50**, and the tie is not clean: ours wins MMLU-Pro by 1,
  loses LiveBench by 1, and both are identical on Juliet (5/5).
- **OlympiadBench is 0/10 for BOTH packs**, so that sub-deck carries no discriminating signal here.
  The reason is not that the models cannot attempt it: all 10 cases generated **1 503–16 000 tokens
  of reasoning and then no `Answer:` line at all** (9 stopped, 1 hit the cap). That is a genuine
  answer-emission failure of both packs at these arms, and it caps both hard scores by up to 10
  questions. A hard-deck number quoted from this box without that caveat is misleading.
  I chased that failure mode instead of leaving it as a zero: at `--reasoning-budget 4096` (a
  separate launcher, `~/run-sushi-budget.sh`, never production) thinking is clamped to 4 119 tokens
  on the cases where it was long — 5/10 for ours, 4/10 for theirs — and exactly those cases then
  emit an `Answer:` line: **ours 1/10, theirs 2/10** on the 10-question slice. Answers are visible
  and near-misses are real (`1002` vs `1003`, `3 976 036` vs `3 986 729`). So the 0/10 was a
  format/channel artifact, **not hidden competence**: at 2.6 bpw + kv8 this deck is genuinely ~1–2/10,
  and 1 vs 2 at n=10 is noise. Full detail: `measurements/eval/failures-by-source.md`.
- **beamster's card claims "LLMProbe Hard 50 — 88.0 %".** With *their* pack, on *our* server, at the
  arms above, we measure **72.0 %** (36/50). Their claim is not reproduced here — most plausibly
  because their run used different serving flags, effort or deck revision than ours, which is exactly
  why the arms columns have to be read before comparing rows. I am not claiming either number is
  wrong; I am claiming they are not the same measurement.
- Run-to-run spread: the same pack, deck and arms scored 82/100 and 81/100 (pilot vs clean), so
  **±1/100 is noise, not a finding**. The 5-question code gap is 5× that band, so it is a real gap.

### The core row — measured, ours only for now

`--eval-suite core` (92: GPQA Diamond, SuperGPQA, AIME 2025, COMPSEC) was run on this box on
2026-10-26/27 at the arms above (xhigh, concurrency 2, 16 k cap, same server flags). Ours finished;
theirs did not:

| pack | core (92) | AIME 2025 / GPQA Diamond / SuperGPQA / COMPSEC | no-Answer-line | cap-stopped | wall |
|---|---|---|---|---|---|
| **ours** (`initialed85/…-Sushi-2.6bpw`) | **69/92 (75.0 %)** | 11/25 · 19/24 · 21/25 · 17/17 | 16 | 3 | 3 h 30 min |
| **theirs** (`beamster/Qwen3.8-Flash-Next-…`) | **no report** | — | — | — | killed at 6 h 57 m |

- **Ours: 69/92 (75.0 %), valid, and a floor.** 16 questions generated real thinking (hundreds-to-
  thousands of tokens) and then emitted no `Answer:` line — the same answer-emission failure mode
  the Olympiad 0/10 showed — and 3 more stopped at the 16 k output cap with no answer line. So
  **75.0 % is what this box graded, not a point estimate of deck competence**: none of those 16 can
  be rescued into the numerator, and some may be wrong in substance, not just in form. COMPSEC (17/17)
  and GPQA-Diamond (modified) (1/1) were clean; AIME 2025 (11/25) is the weak half.
- **Theirs: no report — not a number, and not comparable.** The run started 13:00Z and was still
  going 6 h 57 m later. By a 19:34Z check the server log had ~22 min of no new output (last decode
  activity ~19:11Z); a healthy run streams the mtp-planner every step, so that is a stall, not merely
  slowness. I killed it at 19:58Z (rc=1). The queue's own 6 h watchdog (which was due to fire at
  19:00Z) never did: it `SIGTERM`ed the `npm exec` wrapper (its pattern `llmprobe@0.6.12 …`), not the
  real `node` child that writes the report, and its log line went to `/dev/null` because the queue's
  stdout is `/dev/null` under nohup. There is no score and no partial count, and I will not invent one.
  This is either a genuine stall on these decks at xhigh or an unusually slow run; the silence looks
  like a stall, but the deck is long enough that I cannot rule out the other. The watchdog is now
  fixed (it logs to the queue log and does TERM-then-KILL on the `node`), so a re-run is bounded:

  ```bash
  JOBS="theirs:core" scripts/13-eval-queue.sh     # ~3–5 h, restarts the server per job
  ```

  The queue skips `ours:core` (its report is already on disk) and restores production on our pack at
  the end.

Until a comparable `theirs:core` lands, read the card's `core` claims as ours-only: **69/92 (75.0 %, a
floor)**. The source model's 0.2078 / 0.2980 GPQA-Diamond figures remain quoted from the source card,
not checked, and beamster's card is not a source for `core` on our box either.

### Two things the harness had wrong, and what fixing them changed

**The validity gate.** It originally keyed on "no final text", which quarantined rows that were
perfectly good measurements: on the hard decks a pack can reason for 1 503–16 000 tokens and never
emit an answer line, and that is a real result about a real failure mode, not a broken run. The
signature of the actual bug — the server answering while the pack was not resident — is requests that
generated **nothing at all**. So invalidity is now `outputTokens == 0` per case (measured: the
quarantined 0/100 artifact was 100/100 cases at 0 tokens in 3.1 s; every genuine case has ≥ 119).
The manifests record both counts separately: `cases_without_final_text` (kept, a real result) and
`cases_without_generation` (the bug). Exactly one report in this card's evidence is a real artifact;
it lives in `measurements/eval/invalid/`.

**Sub-deck labelling.** `--eval-cases` slices (the Olympiad experiment) are a *different deck size*,
so they must never be read as deck scores. `11-eval.sh` folds the slice into the report and manifest
label (`hard-olympiad`) and `12-eval-table.py` prints it as `hard-olympiad (SUB-DECK slice, 10 q)`
with a `serving` column taken from the live serve command line (`budget 4096` vs `no budget`), and
refuses to print two same-suite rows of different deck sizes that are not labelled as slices.

**The MBPP mechanism is visible in the cost columns.** At the code deck our pack medians **332**
thinking tokens/question on MBPP against theirs at **556** (across the whole deck: 565 vs 1 544
mean reasoning/question). Ours under-thinks at `effort medium`, and that is where the −5 sits —
so the clean capability gap on this card is partly a thinking-budget effect at these arms, not only
a weights difference. HumanEval's misses are extraction misses (2 ours, 1 theirs) and `HumanEval_116_sort_array`
fails on **both** packs, which points at the prompt, not the pack. Full per-source table:
[`measurements/eval/failures-by-source.md`](measurements/eval/failures-by-source.md).

**Pilot, with its contamination disclosed** ([receipt](measurements/eval/superseded/)): the same
code deck at concurrency 4 **while the engine was shared with this agent's own inference** scored
**82/100** (HumanEval 48/50, MBPP 34/50). Scoring is latency-independent, so the score stays credible;
the cost columns (28 min wall) are the congested numbers. Kept as the receipt that sized the harness,
superseded by the dedicated 81/100 row above.

MBPP is the weak half by construction, and llmprobe warns about exactly that: *"MBPP prompts are
one-liners with no examples, so a model can write a correct function to a different reading. Ask
for 100 % on this deck of a quantised model and you will be disappointed."* The ~16 MBPP misses are
a floor for 2.6 bpw JavaScript, not a per-pack finding — the pack-vs-pack comparison is the point.

Scores are aggregates only. The prompt sets are third-party corpora (GPQA CC BY 4.0, SuperGPQA
ODC-BY, AIME 2025 mirror MIT, MMLU-Pro / OlympiadBench / LiveBench Apache-2.0 as redistributed by
llmprobe, Juliet reductions CC0, MultiPL-E MIT) and are **not redistributed by either published
tree**: what ships is aggregate scores, arms and cost per row (`*-manifest.json`, `table.csv`) plus
the write-ups. The case-level reports and the run logs that embed them stay in the working tree,
hash-anchored through the manifests — LiveBench's five questions come from a private benchmark and
are not publishable at all. Re-obtain a report by re-running `scripts/11-eval.sh` at the arms in
`measurements/eval/README.md`; its sha256 should match the manifest's `report_sha256`.

```bash
scripts/11-eval.sh <served-model-id>          # one deck against whatever the server serves
scripts/12-eval-table.py measurements/eval    # arms-matched table from the saved reports
scripts/13-eval-queue.sh                      # both packs x hard+code, unattended, ~4–7 h
CHECK=1 scripts/11-eval.sh ...                # print the command, run nothing

# the run as handed over (dedicated box, ~4–7 h, restores our server when it finishes):
nohup caffeinate -is scripts/13-eval-queue.sh > logs/handrun-$(date -u +%FT%TZ).log 2>&1 &
tail -f logs/eval-queue-*.log
# smaller slices, safe to ctrl-C, leaves the server down instead of restoring it:
LEAVE_DOWN=1 JOBS="ours:code,theirs:code" scripts/13-eval-queue.sh
LEAVE_DOWN=1 JOBS="ours:hard" scripts/13-eval-queue.sh
scripts/12-eval-table.py measurements/eval --csv measurements/eval/table.csv
```

The bar to beat, from sushi's own tables
([`docs/qwen4-kld.md`](https://github.com/beamivalice/sushi/blob/main/docs/qwen4-kld.md)):

| pack | GiB | KLD (to first EOS) | top-1 |
|---|---|---|---|
| published **Sushi-2.6bpw** (base Qwen, 4-bit g32 table) | 43.95 | **0.1355** | 89.08 % |
| Sushi-3bpw, published 2026-09-29 | 49.33 | 0.1036 | 90.31 % |
| Sushi-4bpw, published 2026-09-29 | 63.68 | 0.0592 | 92.89 % |
| Sushi-2bpw, published (bf16 KV) | 34.97 | 0.2080 | 85.94 % |
| *this pack* | 44.01 GiB of weights + 29.8 GiB table = 73.85 GiB | *not measured vs a BF16 teacher* | *not measured* |

House protocol for that bar: 16 prompts × 512 tokens, scored to the teacher's first end-of-turn
token (7 186
positions); teacher captured with a dense KV cache, students scored at `--kv-quant 8`; weights
resident; the n-gram table is excluded from the GiB column. Quote the first-EOS number, with the
all-positions number beside it. Same rate, same encoder, same window — so expect the region
around **0.13–0.15**, with our built-in calibration (not beamster's imatrix) as the reason it will
not be 0.1355 exactly. Closing that gap needs the 360 GB BF16 source re-downloaded; the harness
is now built and proven, so it is a fetch and ~40 minutes of GPU, not an unknown.

## File map

```
model.safetensors.index.json        3 069 tensors → 52 shards
model-trunk-00000..2.safetensors    6.32 GB — dense/affine 8-bit, 2 628 tensors: embed, lm_head,
                                      trunk linears, vision tower, MTP fc/norm
ngram_table.bin                     32.0 GB (29.8 GiB), 4-bit/g32, SSD-resident
layer-0..47.safetensors             EXL3 experts, 836 MB each (9 tensors per shard: gate/up/down ×
                                      suh/svh/trellis)
mtp-0.safetensors                   836 MB — the MTP layer's routed experts, same 9-tensor shape
                                      as a decoder layer
config.json · generation_config.json · chat_template.jinja
tokenizer.json · tokenizer_config.json · vocab.json · merges.txt ·
  preprocessor_config.json · video_preprocessor_config.json
LICENSE · LICENSE-QWEN · NOTICE        carried through from the source, unmodified
ukisai-banner.png · swift-1.5-flash-next-demo.mp4   media from the source repo
README.md           the source repo's own model card, verbatim, in the pack dir (it is published
                    to HF as README-SOURCE.md so it cannot overwrite this card)
```

69 files. This list is `ls` of the pack directory, not the converter's log — an earlier revision of
this card described beamster's layout (`model-lm-head/embed/vision.safetensors`,
`tokenizer.sushi.json`, `vocab.filemap.json`) as if it were ours, and understated the trunk and
MTP sizes; those files do not exist in this pack. See [docs/BUILD.md](docs/BUILD.md).

Checksums of all 74 GB: [`SHA256SUMS.txt`](SHA256SUMS.txt) — 69 files, paths as they are in the pack
dir (`shasum -a 256 -c SHA256SUMS.txt` run from inside it; `README.md` is published under the name
`README-SOURCE.md`).
Machine-readable provenance: [`provenance.json`](provenance.json). Raw measurements:
[`measurements.json`](measurements.json).

The unedited build logs are in [`logs/`](logs) — download, pipeline, full converter output
(48 layers with per-stage timings), supervisor, smoke test, the real-prompt test — plus the
in-the-moment scripts (`build-sushi-pack.sh`, `swift15-pipeline.sh`, `sushi-supervisor.sh`).
Local paths are redacted to `$HOME`. Read them as the receipts behind every number above.

## Licensing — read this before you use or republish

Two licences apply, and both travel with this pack:

- **`LICENSE` — Swift Open License v1.0 (UkisAI).** Apache-2.0-shaped, plus §5 *Commercial Use
  Limitation*: rights are void for a legal entity exceeding **US$1M** gross revenue in the last
  fiscal year (§5(a,b)); non-profits are exempt for non-commercial/research use (§5(c)); above
  the threshold, get a [Swift Enterprise License](https://ukisai.com/contact) (§5(d)).
  §8 forbids use of the "UkisAI"/"Swift" marks beyond describing origin.
- **`LICENSE-QWEN` — Qwen Community License 1.0 (Qwen).** Permits use, modification, publishing
  and distribution; §1 copyright notice + prominent display above 100 M MAU / US$20 M monthly
  revenue; §2 requires a separate Qwen licence for *Model as a Service* / *AI Work Assistant*
  commercial use (internal use is exempt).

§4 of the Swift licence is what authorises **this** repo, and §4(e) is explicit about quantised
derivatives: *"including merged, quantized, or otherwise converted weights that incorporate the
Base Model, You must also give recipients a copy of the Base Model License."* So `LICENSE`,
`LICENSE-QWEN` and `NOTICE` are all redistributed unchanged, and §4(b)'s change notice is
[`NOTICE-CONVERSION.md`](NOTICE-CONVERSION.md). The source repo is **not gated**, and its own card
travels with the pack verbatim as [`README-SOURCE.md`](README-SOURCE.md).

This is a hobbyist build for personal/research use. If you work somewhere above the thresholds,
get the licences from UkisAI and Qwen before any commercial use.

## References

Engine, converter and measurement tool —
[`beamivalice/sushi`](https://github.com/beamivalice/sushi). The docs this build actually used:

| doc | what it is |
|---|---|
| [`docs/usage.md`](https://github.com/beamivalice/sushi/blob/main/docs/usage.md) | install; `pull`/`list`/`run`/`serve`; the RAM tier per Mac per pack |
| [`docs/flags.md`](https://github.com/beamivalice/sushi/blob/main/docs/flags.md) | serve and convert flags |
| [`docs/pack-format.md`](https://github.com/beamivalice/sushi/blob/main/docs/pack-format.md) | **the consumer contract**: tensor layout a pack must ship, and the quality bar |
| [`docs/encoder.md`](https://github.com/beamivalice/sushi/blob/main/docs/encoder.md), [`docs/engine-exl3-encoder.md`](https://github.com/beamivalice/sushi/blob/main/docs/engine-exl3-encoder.md) | what `convert exl3` writes; the numerical core |
| [`docs/qwen4-arch.md`](https://github.com/beamivalice/sushi/blob/main/docs/qwen4-arch.md) | the `qwen4_exp` architecture this pack is |
| [`docs/quality-kld.md`](https://github.com/beamivalice/sushi/blob/main/docs/quality-kld.md), [`docs/qwen4-kld.md`](https://github.com/beamivalice/sushi/blob/main/docs/qwen4-kld.md) | the KLD protocol and the published numbers (the bar in [Quality](#quality-what-we-do-and-do-not-claim)) |
| [`docs/qwen4-perf.md`](https://github.com/beamivalice/sushi/blob/main/docs/qwen4-perf.md), [`docs/perf-baselines.md`](https://github.com/beamivalice/sushi/blob/main/docs/perf-baselines.md) | expected tok/s per tier |
| [`docs/engine-mtp.md`](https://github.com/beamivalice/sushi/blob/main/docs/engine-mtp.md), [`docs/engine-kv-cache.md`](https://github.com/beamivalice/sushi/blob/main/docs/engine-kv-cache.md), [`docs/engine-prefix-cache.md`](https://github.com/beamivalice/sushi/blob/main/docs/engine-prefix-cache.md) | the three subsystems we saw engage |
| [`docs/server-lifecycle.md`](https://github.com/beamivalice/sushi/blob/main/docs/server-lifecycle.md), [`docs/server-http-apis.md`](https://github.com/beamivalice/sushi/blob/main/docs/server-http-apis.md) | server start, `/v1/models`, metrics |
| [`docs/process-measurement.md`](https://github.com/beamivalice/sushi/blob/main/docs/process-measurement.md) | how to measure a build like [docs/BUILD.md](docs/BUILD.md) does |

Model and pack references:

- [`beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw`](https://huggingface.co/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw) — the official 2.6bpw tier: the rate, codebook and window this build matches, and the only org `sushi pull` accepts
- [`ukisai/Swift1.5-Qwen3.8-Flash-Next`](https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next) — BF16 source, 360 GB, 149 files
- [`ukisai/Swift1.5-Qwen3.8-Flash-Next-GGUF`](https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next-GGUF), [`…-GSQ-RCO-GGUF`](https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF) — the llama.cpp route (what our Strata cluster runs)
- [`Qwen/Qwen3.8-Flash-Next`](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) — the base model
- [`ukisai/Qwen3.8-27B-multi-turn-agent-sft`](https://huggingface.co/datasets/ukisai/Qwen3.8-27B-multi-turn-agent-sft) — Swift training data

## Notes on how this was built (the unattended part)

The conversion ran unattended under `scripts/supervise.sh`, which is the boring
infrastructure that made 8 hours of unattended quantising safe: it watches for
`ALL DONE`, re-launches `convert --resume` on a crash, refuses to start a conversion while
a sushi **server** is running (a server wires ~50 GB and owns the RAM/GPU the trellis
search needs), pauses when free disk drops below 60 GB, verifies pack integrity, runs the
smoke test, and only deletes the 360 GB source **after** a green smoke test. It is
single-instance (`flock`-style lockdir) and capped at 3 resumes so a systematic failure
stops and asks for a human instead of eating the disk.

Two lessons worth keeping:

1. `--experts-k 2.625`, not `2.6` — see [The flags, and the one trap](#the-flags-and-the-one-trap).
2. `scripts/04-verify-pack.py` skipped the `__header__` key and not `__metadata__` in an earlier
   revision, and dutifully reported 52 "defective" shards on a perfectly healthy pack. Safetensors
   headers contain `__metadata__`, which has no `data_offsets`. The current version skips both.

— built 2026-10-24, `initialed85`, on a MacBook Pro (Mac14,6) with an Apple M2 Max, 12 cores, 64 GB. sushi 1.3.0, MLX 0.32.3, mlx-c `56b2d39`.
