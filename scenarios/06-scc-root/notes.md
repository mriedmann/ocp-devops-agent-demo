# Blocked by SecurityContextConstraints (runs as root)
**Symptom:** `demo-legacy` `0/1`, no pod.
**Expected tool path:** `resources_get Deployment` -> `resources_list ReplicaSet` -> `events_list` (`FailedCreate ... unable to validate against any security context constraint ... runAsUser: Invalid value: 0`).
**Root cause:** the pod asks for UID 0; the `restricted-v2` SCC assigned to normal users forbids it.
**Proposed fix:** remove `runAsUser: 0` (let OpenShift assign a UID) and use an image that runs as non-root / on a port > 1024. Do *not* propose granting the `anyuid` SCC on a sandbox.
**Talking point:** the classic "works on Docker/Kubernetes, fails on OpenShift" problem.
