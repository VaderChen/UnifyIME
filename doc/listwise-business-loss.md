# Listwise business-aligned loss

FastChIME does not optimize a generic relevance list. It starts from a strong
heuristic ranker and adds a bounded neural residual. The business objective is
asymmetric:

- correcting a wrong baseline choice is useful;
- changing a correct deployed choice into an error is substantially worse;
- article-derived labels are weak evidence, while real user selections are
  strong evidence;
- training and runtime must combine heuristic and residual scores with the
  same scale.

## Research mapping

- [ListNet](https://doi.org/10.1145/1273496.1273513) supplies the top-one
  listwise softmax foundation. With one positive candidate, FastChIME's
  cross-entropy over the complete candidate list is a ListNet-style top-one
  objective.
- [ListMLE](https://doi.org/10.1145/1390156.1390306) motivates optimizing a
  complete candidate permutation, but adds limited value when each training
  group contains only one positive label.
- [LambdaLoss](https://doi.org/10.1145/3269206.3271784) weights ranking errors
  by their change in the target metric. FastChIME applies the same idea to its
  business utility: a teacher-correct decision receives `harm_cost`, while a
  teacher-wrong decision receives `improvement_gain`.
- [Unbiased Learning-to-Rank with Biased Feedback](https://doi.org/10.1145/3018661.3018699)
  motivates preserving absolute source weights and controlling sampling bias.
  Weak article weights must not be normalized away inside an all-article
  batch, and every batch uses a fixed real-selection ratio.
- [Ranking Distillation](https://doi.org/10.48550/arXiv.1809.07428) motivates
  keeping the safe checkpoint as a teacher. FastChIME distills the teacher's
  combined-score distribution and protects its correct target margin.
- [NeuralNDCG](https://doi.org/10.48550/arXiv.2102.07831) is relevant when
  graded relevance and NDCG are the deployment metric. FastChIME instead uses
  Top-1 improvement, harm, and net lift, so a direct NeuralNDCG substitution
  would be misaligned.

## Implemented objective

For candidate group `q`, training uses the same score contract as runtime:

```text
student_score = heuristic_score + runtime_scale * student_residual
teacher_score = heuristic_score + runtime_scale * teacher_residual
```

The combined loss is:

```text
L = L_business_listwise
  + lambda_harm * L_teacher_margin
  + lambda_anchor * KL(teacher_scores || student_scores)
  + lambda_easy * L_easy_residual
```

`L_business_listwise` is full-list cross-entropy weighted by:

```text
difficulty_weight
* absolute_source_weight
* (harm_cost if teacher is correct else improvement_gain)
* real_selection_business_weight
```

`L_teacher_margin` is active only when the safe teacher selects the target. It
penalizes any reduction below the teacher's target-versus-competitor margin.
Checkpoint selection still enforces the real-selection harm-rate gate after
each turn.
