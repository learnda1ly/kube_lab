# Storage smoke tests
#
# Dynamic NFS provisioning is installed by Ansible (`make storage` / `site.yml`)
# from `ansible/roles/nfs_provisioner` — that is the canonical path (fills the
# NFS server IP from Terraform inventory).
#
# Manual PVC smoke test after the cluster is up:
#   export KUBECONFIG=$PWD/kubeconfig
#   kubectl apply -f manifests/storage/pvc-smoke.yaml
#   kubectl get pvc nfs-smoke
#   kubectl delete -f manifests/storage/pvc-smoke.yaml
