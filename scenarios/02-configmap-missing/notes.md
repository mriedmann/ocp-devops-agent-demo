# CreateContainerConfigError (missing ConfigMap)
**Symptom:** pod `demo-app` in `CreateContainerConfigError`; no logs exist because the container never started.
**Expected tool path:** `pods_list` -> `pods_get` (waiting reason) -> `events_list` (`configmap "demo-app-config" not found`) -> `resources_list ConfigMap` to confirm it is absent.
**Root cause:** the pod references ConfigMap `demo-app-config` (key `mode`), which does not exist.
**Proposed fix:** create the ConfigMap (`oc create configmap demo-app-config --from-literal=mode=production`); the pod starts by itself.
**Talking point:** `pods_log` returns nothing here, so the agent has to switch to events.
