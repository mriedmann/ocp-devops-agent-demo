# Restart loop caused by a liveness probe (slow start)
**Symptom:** `RESTARTS` climbs; the log only ever shows "warming up"; exit code 137/143 (killed, not crashed).
**Expected tool path:** `pods_list` -> `pods_log` (previous) -> `events_list` (`Liveness probe failed ... Container will be restarted`) -> `pods_get` (probe settings vs. warm-up time in the command).
**Root cause:** the app needs ~40s to warm up, the liveness probe gives up after ~15s and kills it.
**Proposed fix:** add a `startupProbe` (or a larger `initialDelaySeconds`); keep the liveness probe strict afterwards.
**Talking point:** the same family as litellm's own `Readiness probe failed: connection refused` events at every start in this namespace.
