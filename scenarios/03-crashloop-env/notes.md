# CrashLoopBackOff (missing environment variable)
**Symptom:** `demo-api` restarts, status `CrashLoopBackOff`, exit code 1.
**Expected tool path:** `pods_list` -> `pods_log` (current and `previous: true`) -> `resources_get Pod` to confirm no `env`.
**Root cause:** the app requires `DB_HOST`, the pod spec does not define it.
**Proposed fix:** add `env: DB_HOST=...` (or a ConfigMap/Secret reference) and re-create the pod.
**Talking point:** the answer is in the *log*, not in the events. Contrast with scenario 02.
