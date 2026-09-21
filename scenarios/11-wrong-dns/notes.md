# Application cannot reach backend (wrong Service name)
**Symptom:** all pods `Running`; frontend logs `backend call failed` and curl reports `Could not resolve host: demo-backend-svc`.
**Expected tool path:** `pods_list` -> `pods_log demo-frontend` (resolve error) -> `resources_list Service` (only `demo-backend` exists) -> `resources_get Pod demo-frontend` (`BACKEND_URL`).
**Root cause:** `BACKEND_URL` points at `demo-backend-svc`; the Service is called `demo-backend`.
**Proposed fix:** correct `BACKEND_URL` to `http://demo-backend:8080/` and re-create the pod.
**Talking point:** cross-check of a log message against the real objects (the same class of bug as a wrong `DATABASE_URL` host for litellm/postgres).
