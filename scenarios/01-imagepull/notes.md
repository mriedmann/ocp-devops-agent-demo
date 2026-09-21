# ImagePullBackOff (typo in image tag)
**Symptom:** pod `demo-web` stays `ErrImagePull` / `ImagePullBackOff`.
**Expected tool path:** `pods_list` -> `pods_get` / `events_list` (event: `manifest unknown` / `not found`).
**Root cause:** image tag `2.4-latest-typo` does not exist in the registry.
**Proposed fix:** set the image to `registry.access.redhat.com/ubi9/httpd-24:latest`
(the image of a bare pod cannot be changed to a new tag by re-applying a different pod spec that
way, so `scenario.sh fix` deletes and re-creates it).
**Talking point:** the exact registry error is only visible in events, not in `oc get pods`.
