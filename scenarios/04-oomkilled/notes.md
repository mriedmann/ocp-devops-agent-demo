# OOMKilled (memory limit too low)
**Symptom:** `demo-worker` in `CrashLoopBackOff` / `OOMKilled`; the log stops at "loading dataset".
**Expected tool path:** `pods_list` -> `pods_log` (short, inconclusive) -> `pods_get` (`lastState.terminated.reason: OOMKilled`, exit 137, memory limit 32Mi).
**Root cause:** container memory limit (32Mi) is smaller than what the process needs while loading data.
**Proposed fix:** raise `resources.limits.memory` (e.g. 256Mi) and set a sensible request.
**Talking point:** the log alone is misleading; the *termination reason* is the evidence. The namespace LimitRange defaults (1000Mi limit) once OOM-killed litellm in this very project.
