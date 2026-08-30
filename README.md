# amun-kubernetes

k3s on 11 Raspberry Pis (`rpid0`..`rpid10.lan`), with embedded etcd HA on
`rpid0/1/2`, MetalLB load balancer (two L2 pools, one per subnet),
ingress-nginx, and k8s_gateway exposing services as `<name>.k8s.lan` via a
pfSense Domain Override.

The full design rationale and inventory live in [`spec/initial-plan.md`](spec/initial-plan.md).

## Quick start

```sh
./deploy            # provisions all nodes + cluster services + pfSense override
export KUBECONFIG=~/.kube/config-rpid
kubectl get nodes
```

The first run prompts for your **pfSense username + password** so `domain.py`
can program the `k8s.lan` Domain Override. The credentials are cached at
`./.pf-creds` (chmod 600, gitignored). Re-run anytime; everything is idempotent.
The same credentials are Kauket-managed as `pfsense.admin_creds` — on a fresh
machine, `kauket get pfsense.admin_creds --stdout > .pf-creds && chmod 600
.pf-creds` skips the prompt.

## Layout

| Path | What |
|---|---|
| `inventory/rpids.yml` | Node groups (servers, agents) and per-host vars |
| `main.yml` | The Ansible playbook (prereqs → k3s init → joins → agents → bootstrap) |
| `roles/k3s_prereqs/` | cgroup memory in `/boot/firmware/cmdline.txt`, sysctl, modprobe |
| `roles/k3s_server/` | Install k3s server with `--cluster-init` (embedded etcd) or join |
| `roles/k3s_agent/` | Install k3s agent |
| `roles/labels/` | Label nodes with `topology.kubernetes.io/zone` for MetalLB |
| `roles/helm_releases/` | Apply k3s `HelmChart` CRDs (no helm CLI needed) |
| `roles/pfsense_dns/` | Run `domain.py` |
| `cluster/` | Kustomize root applied after k3s is up: namespaces, MetalLB, ingress-nginx, k8s_gateway |
| `deployment/deployment.yml` | **The user-facing file you edit** to add new services |
| `deploy` | Bash entry point (calls Ansible + kustomize + domain.py) |
| `domain.py` | pfSense Unbound Domain Override automation |

## Health check (one-liners)

```sh
# Nodes
kubectl get nodes -o wide
kubectl top nodes
kubectl describe nodes | grep -A4 'Conditions:' | grep -E '(Ready|Pressure)'

# Control plane / etcd
kubectl get pods -n kube-system
ssh rpid0.lan sudo k3s etcd-snapshot ls
kubectl get --raw='/readyz?verbose' | tail -20

# Workloads + events
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl get events -A --sort-by=.lastTimestamp | tail -20

# Network: MetalLB + ingress
kubectl -n metallb-system get ipaddresspools,l2advertisements
kubectl get svc -A | grep LoadBalancer
kubectl -n ingress-nginx get pods,svc

# DNS
kubectl -n kube-system logs deploy/k8s-gateway --tail=20
dig @$(kubectl -n kube-system get svc k8s-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}') hello.k8s.lan +short
```

## Add a service

```sh
# 1. Create a cn-<name> repo with a k8s/kustomization.yaml
# 2. Append one line to deployment/deployment.yml
echo '  - github.com/GonzaloAlvarez/cn-<name>//k8s?ref=main' >> deployment/deployment.yml
# 3. Apply
kubectl apply -k deployment/
```

## Common tasks

```sh
# Drain a node for maintenance
kubectl drain rpid7.lan --ignore-daemonsets --delete-emptydir-data
# ...do work...
kubectl uncordon rpid7.lan

# Reboot safely
kubectl drain rpid7.lan --ignore-daemonsets --delete-emptydir-data
ssh rpid7.lan sudo reboot
kubectl uncordon rpid7.lan       # after Ready

# Upgrade k3s — edit group_vars/all.yml: k3s_version: vX.Y.Z+k3s1
./deploy                         # re-running is idempotent

# Re-run pfSense Domain Override (e.g. after re-IP)
./domain.py                      # or `./domain.py --refresh-creds`

# Reset a node (destructive!)
ssh rpidX.lan sudo /usr/local/bin/k3s-uninstall.sh         # for servers
ssh rpidX.lan sudo /usr/local/bin/k3s-agent-uninstall.sh   # for agents
```

## Why this deviates from the `amun X` per-host pattern

The `amun` CLI clones `amun-X` and runs `--connection=local --limit 127.0.0.1`,
which is right when the role is "install X *on this machine*". k3s clustering
needs central orchestration with `delegate_to`/`run_once` for the init host,
the join token, and the kubeconfig fetch. So `amun-kubernetes` exposes a
`./deploy` wrapper that runs Ansible against the whole inventory from your
laptop instead of self-installing per host.

## License

GNU GENERAL PUBLIC LICENSE Version 3
Copyright (c) 2026 Gonzalo Alvarez
