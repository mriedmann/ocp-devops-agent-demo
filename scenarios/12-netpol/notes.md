# Connection timeouts (NetworkPolicy egress lock-down)
**Symptom:** everything `Running`, Service has endpoints, name resolution works, client logs `server unreachable (timeout)` (a timeout, not "connection refused").
**Expected tool path:** `pods_log demo-client` -> `resources_get Service/Endpoints` (fine) -> `resources_list NetworkPolicy` (about 10 sandbox-managed policies plus `demo-client-egress`) -> `resources_get NetworkPolicy demo-client-egress` (Egress only allows DNS ports) -> pod labels.
**Root cause:** `demo-client-egress` restricts the client's egress to DNS; nothing allows it to reach `app=demo-server` on 8080.
**Proposed fix:** add an egress rule to `app=demo-server` on TCP 8080 to that policy (do not delete the policy).
**Talking point:** no exec tool is needed: the agent reasons from the policy and labels. It also has to ignore the sandbox's own `allow-*` policies (an ingress default-deny would be a no-op here because `allow-same-namespace` already exists, and NetworkPolicies are additive).
`scenario.sh fix` applies the extra egress rule.
