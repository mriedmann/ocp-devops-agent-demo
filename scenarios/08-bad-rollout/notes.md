# Stuck rollout (new version never becomes ready)
**Symptom:** two ReplicaSets; old pod (v1.0) is Ready, new pod (v2.0) is Running but `0/1` Ready. `ProgressDeadlineExceeded` after 60s.
**Expected tool path:** `resources_get Deployment` (conditions) -> `resources_list ReplicaSet` -> `pods_list` -> `events_list` (`Readiness probe failed: cat: /tmp/ready`) -> `pods_get` on both pods.
**Root cause:** v2 has a readiness probe that checks for `/tmp/ready`, which the app never creates.
**Proposed fix:** roll back (`oc rollout undo deployment/demo-shop`), then fix the probe or the app before re-releasing.
**Talking point:** the agent should also answer "is the shop still up?": yes, `maxUnavailable: 0` kept v1 serving.
`scenario.sh fix` performs the rollback.
