# Job BackoffLimitExceeded (application error inside a run-to-completion pod)
**Symptom:** Job `Failed` with `BackoffLimitExceeded`; three pods in `Error`, none running (a Job's pods are not restarted, they are replaced until `backoffLimit` is reached).
**Expected tool path:** `resources_get Job` (conditions: `BackoffLimitExceeded`) -> `pods_list` (3 Error pods) -> `pods_log` (`ERROR: input file /data/input.csv not found`, exit code 2).
**Root cause:** the report script expects `/data/input.csv`, which does not exist in the container (no volume mounted / wrong path).
**Proposed fix:** mount or generate the input file, or point the job at the right path. Jobs are immutable: delete and re-create.
**Talking point:** after a Job fails, `oc get pods` is the only place the reason lives: the agent must read the log of a *completed* pod. Contrast with 03 (a Pod restarted in place).
