# Local helper comparison on 20 Nov 2026

The running `127.0.0.1:8765/health` reported `d1-2B-mlx8bit`. The GS3 training notes identify `d1-2B-gs3-mlx8bit` as the intended checkpoint. Both directories exist. The measured results below use the checkpoint reported by the helper. Its health reply did not advertise decision pictures.

This run sent 100 decision requests and six locate requests, sequentially. Each text case compared the old screen prefix and the new selected screen with the same goal, history and options. Variants alternated order. Median and p90 include request overhead. The first chooser request included a cold load.

## Text

Chooser abstention applies the current probability and lead cutoffs. A correct abstention counts as a correct policy choice when no option fits. Decision abstention counts calls that would emit no hint at the confidence cutoffs, including `act`. Completion hints are off by default.

| Split | Route | View | Top choice correct | Abstained | Median / p90 |
|---|---|---|---:|---:|---:|
| Dev | Choose | Old | 2/8 | 8/8 | 280 / 4572 ms |
| Dev | Choose | Focused | 7/8 | 3/8 | 244 / 374 ms |
| Dev | Decide | Old | 4/10 | 7/10 | 264 / 585 ms |
| Dev | Decide | Focused | 7/10 | 5/10 | 227 / 593 ms |
| Held out | Choose | Old | 8/16 | 16/16 | 194 / 458 ms |
| Held out | Choose | Focused | 12/16 | 6/16 | 233 / 362 ms |
| Held out | Decide | Old | 8/16 | 12/16 | 268 / 468 ms |
| Held out | Decide | Focused | 9/16 | 10/16 | 276 / 587 ms |

At the current chooser settings, held-out policy accuracy was 4/16 old and 13/16 focused. The focused chooser incorrectly ranked the Display options “Show Details” button above the identical Hearing options button in one Settings case. Its score cleared both cutoffs. The legacy chooser abstained on every held-out row.

The dev-only fit for the focused chooser was 0.70 minimum probability and a 0.35 lead. It accepted five correct dev actions. On held-out examples it had 11/16 correct policy choices, nine abstentions and zero wrong actions. No legacy setting qualified. The focused dev fit for completion was 0.86, matching the existing value. At that cutoff the focused view produced two correct held-out completion hints from four completed cases. The old view produced zero hints. Runtime thresholds stay at their existing values.

The summary keeps the GS3 training layout, including the `Screen:` label and plain window and element rows. The different line selection, the omission note and optional pictures change what the model sees. This run cannot tell whether GS3 needs retraining. It takes a paired GS3 run to answer that.

## Synthetic screen locations

| Pipeline | Correct | Abstained | LFM calls | Median | p90 |
|---|---:|---:|---:|---:|---:|
| LFM only | 2/4 | 1/4 | 4 | 1487 ms | 15002 ms |
| OCR first | 2/4 | 1/4 | 2 | 885 ms | 92534 ms |

OCR found both labelled targets in 390 and 499 ms. One request timed out per pipeline. Both pipelines proposed a point for a missing target. This scores proposed points. Unit tests cover coordinate mapping, changed pixels and the policy for accepting a hit. Live AX hit-testing was outside this run. The sample and timeout variation prevent a reliable speed comparison.

The picture patch applied to a staging copy and passed 16 stubbed requests across `/choose` and both `/decide` modes. Live decision pictures and native click delivery were not run. The comparison measures local requests and does not measure cloud token savings.
