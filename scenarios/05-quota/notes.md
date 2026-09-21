# Deployment with no pods (ResourceQuota exceeded)
**Symptom:** `demo-batch` is `0/1`, `oc get pods` shows nothing for it.
**Expected tool path:** `resources_get Deployment` -> `resources_list ReplicaSet` -> `events_list` (`FailedCreate ... exceeded quota: compute-deploy, requested: requests.cpu=8, limited: requests.cpu=3`) -> `resources_list ResourceQuota` for current usage.
**Root cause:** pod requests 8 CPU; the sandbox quota allows 3 CPU of requests in total.
**Proposed fix:** lower `requests.cpu`/`limits.cpu` to what the workload really needs (e.g. 50m).
**Talking point:** no pod exists, so pod tools are useless: the error lives on the ReplicaSet. The same kind of quota (replicaset count) blocked litellm rollouts in this namespace.
