# Route shows "Application is not available" (Service selector mismatch)
**Symptom:** the pod is `Running/Ready`, but the Route returns the OpenShift 503 page.
**Expected tool path:** `pods_list` (healthy) -> `resources_get Route` -> `resources_get Service` -> `resources_get Endpoints` (empty) -> compare Service selector `app=demo-webs` with pod label `app=demo-site`.
**Root cause:** typo in the Service selector, so it matches no pod and has no endpoints.
**Proposed fix:** `oc patch svc demo-site -p '{"spec":{"selector":{"app":"demo-site"}}}'`.
**Talking point:** every individual object looks healthy; the bug is in the *relationship* between them.
Optional live proof after the fix: `curl -k https://$(oc get route demo-site -o jsonpath='{.spec.host}')`: before the fix HTTP 503 (OpenShift error page), after it the Apache/RHEL test page (that page is served with status 403 by design, it still proves the route works).
