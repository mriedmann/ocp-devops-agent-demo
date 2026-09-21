# Pod Pending (PVC cannot bind: unknown StorageClass)
**Symptom:** pod `Pending`, PVC `Pending`.
**Expected tool path:** `pods_get` / `events_list` (`FailedScheduling: unbound immediate PersistentVolumeClaims`) -> `resources_get PVC` (`storageclass.storage.k8s.io "fast-ssd" not found`).
**Root cause:** the PVC names StorageClass `fast-ssd`, which does not exist in this cluster.
**Proposed fix:** drop `storageClassName` to use the cluster default class (a PVC's class is immutable, so delete and re-create the PVC and pod).
**Talking point:** the pod's own events only point to the PVC; the agent has to follow the reference.
