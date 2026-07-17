# Splunk Enterprise (standalone) on NFS

Single-instance Splunk with persistent `/opt/splunk/etc` and `/opt/splunk/var`
on StorageClass `nfs` (dynamic PVs on `nfs-01`).

## Prerequisites

- Cluster up with StorageClass `nfs` (`make verify` / `kubectl get sc nfs`)
- Worker RAM: defaults are ~4 GiB; this Deployment requests **2 GiB** and limits **~3.5 GiB**. Increase worker memory in tfvars if Splunk OOMs.

## Deploy

```bash
export KUBECONFIG="$PWD/kubeconfig"

cp manifests/splunk/secret.yaml.example manifests/splunk/secret.yaml
# edit manifests/splunk/secret.yaml — set a strong password (not the example)

kubectl apply -f manifests/splunk/namespace.yaml
kubectl apply -f manifests/splunk/secret.yaml
kubectl apply -f manifests/splunk/pvc.yaml
kubectl apply -f manifests/splunk/deployment.yaml
kubectl apply -f manifests/splunk/service.yaml
kubectl apply -f manifests/splunk/service-s2s.yaml
```

First boot can take several minutes (Ansible inside the image configures Splunk).

```bash
kubectl -n splunk get pvc,pods,svc
kubectl -n splunk logs -f deploy/splunk
```

## Access

| Path | How |
|------|-----|
| Web UI | `http://<any-node-ip>:30080` (NodePort) — user `admin` |
| Port-forward | `kubectl -n splunk port-forward svc/splunk 8000:8000` |
| **S2S ingest** | `<any-node-ip>:9997` (LoadBalancer via k3s ServiceLB) |
| **Deployment server (mgmt)** | `<any-node-ip>:8089` (LoadBalancer `splunk-mgmt`) |

Mac Universal Forwarder + deployment client: [macos-uf.md](macos-uf.md).

HEC / management NodePort Service still exposes `8088` / `8089` as well. Forwarders should use **`:9997`** for data and **`:8089`** for phone-home.
## Persistence

| PVC | Size | Mount |
|-----|------|--------|
| `splunk-etc` | 5Gi | `/opt/splunk/etc` |
| `splunk-var` | 50Gi | `/opt/splunk/var` |

Reclaim policy is `Retain`: deleting the PVCs leaves data under `/srv/nfs/k3s/` on `nfs-01` until you remove those directories.

## Tear down

```bash
kubectl delete -f manifests/splunk/deployment.yaml
kubectl delete -f manifests/splunk/service.yaml
kubectl delete -f manifests/splunk/pvc.yaml
kubectl delete -f manifests/splunk/secret.yaml
kubectl delete -f manifests/splunk/namespace.yaml
# optional: remove leftover NFS dirs on nfs-01
```
