# Centralized Kubernetes logs

Grafana Alloy discovers only Pods in the application namespace through a
namespaced read-only Role and streams their logs through the Kubernetes API.
It requires no host filesystem mount or privileged container. Loki stores seven
days of logs on the retained `loki-data` volume, and Grafana provisions Loki as
a non-default data source.

Images are pinned by multi-architecture digest:

- Grafana Alloy `v1.18.0`;
- Grafana Loki `v3.7.4`.

Prometheus alerts after five minutes if Loki or Alloy is unavailable. The
production deployment gate also requires both scrape targets to be `up=1`.

## Verify

```bash
kubectl -n observability rollout status deployment/loki
kubectl -n observability rollout status deployment/alloy
kubectl -n observability port-forward service/loki 13100:3100
curl -fsS http://127.0.0.1:13100/ready
curl -fsS -G http://127.0.0.1:13100/loki/api/v1/query \
  --data-urlencode 'query={namespace="default",app="server"}'
```

Do not expose Loki publicly: authentication is disabled because it is reachable
only through the cluster network and Grafana proxy. The retained block volume
protects logs from a Pod replacement, but it is not a multi-zone archive.
Export to a dedicated object-store prefix before claiming disaster-recovery
durability for logs.
