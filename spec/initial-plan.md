# Plan: 12-Pi Kubernetes cluster with replicated storage and pfSense-aware DNS

## Context

You have 12 Raspberry Pi nodes (`rpid0..rpid11.lan`) and want a self-hosted Kubernetes cluster with shared storage that survives **2 simultaneous node failures**, plus a workflow where you edit one `deployment.yml` and your services land on the cluster reachable as `hello.k8s.lan` (resolved by your pfSense box).

Three repos under `github.com/gonzaloalvarez` will be created:

| Repo | Role | Style |
|---|---|---|
| `amun-kubernetes` | Provisions k3s on all Pis + cluster-wide bootstrap (MetalLB, k8s_gateway, Longhorn install, ingress) + holds the user's `deployment.yml` | Ansible + kustomize |
| `amun-longhorn` (renamed from `amun-glusterfs`) | Storage prerequisites + Longhorn Helm install + StorageClass | Ansible |
| `cn-helloworld` | Tiny echo server with PVC + Ingress to validate end-to-end | k8s manifests |

> **Why rename `amun-glusterfs` → `amun-longhorn`:** The GlusterFS Kubernetes CSI driver has been officially deprecated since 2018. You picked Longhorn (3-replica) — the file naming should match.

---

## Survey results — what we're actually working with

Gathered live from each Pi via SSH. **Important: this fleet is heterogeneous and split across two subnets.**

| Host | Model | RAM | Disk | Subnet | Docker | Role assignment |
|---|---|---|---|---|---|---|
| rpid0 | Pi 4B v1.5 | 4GB | **954G** SD | 10.1.1.156/16 | yes | **server** (control-plane + storage) |
| rpid1 | Pi 4B v1.5 | 4GB | **954G** SD | 10.1.1.154/16 | yes | **server** (control-plane + storage) |
| rpid2 | Pi 4B v1.5 | 4GB | **954G** SD | 10.1.1.155/16 | yes | **server** (control-plane + storage) |
| rpid3 | Pi 4B v1.5 | 4GB | **954G** SD | 10.0.0.184/24 | yes | agent (storage) |
| rpid4 | Pi 4B v1.5 | 4GB | **954G** SD | 10.0.0.185/24 | yes | agent (storage) |
| rpid5 | Pi 4B v1.5 | 4GB | **954G** SD | 10.0.0.187/24 | yes | agent (storage) |
| rpid6 | Pi 4B v1.5 | 4GB | **954G** SD | 10.0.0.189/24 | yes | agent (storage) |
| rpid7 | Pi 4B v1.5 | 4GB | 30G | 10.1.1.131/16 | yes | agent (compute-only) |
| rpid8 | Pi 4B v1.5 | 4GB | 60G | 10.1.1.133/16 | yes | agent (compute-only) |
| rpid9 | Pi 4B v1.5 | 4GB | 30G | 10.0.0.191/24 | yes | agent (compute-only) |
| rpid10 | Pi 4B v1.2 | 4GB | 30G | 10.0.0.193/24 | **no** | agent (compute-only) |
| rpid11 | **Pi 3B** | **1GB** | 30G | 10.0.0.188/24 | no | **excluded** (RAM too tight; can join later) |

All run **Debian 13 trixie** with **kernel 6.12 aarch64** and **cgroup v2** (✓ k3s ready).
All boot from `mmcblk0` (microSD) — no SSDs/NVMe.
Cross-subnet ICMP works at <0.5ms (your pfSense routes 10.1.0.0/16 ↔ 10.0.0.0/24).
User `gonzalo` has passwordless sudo and SSH key access on all reachable nodes.

**Storage capacity math (Longhorn 3-replica, 7 storage nodes × 954G ≈ 6.5TB raw):**
Usable ≈ 6.5TB / 3 ≈ **~2.1TB**. Survives any 2 nodes going down simultaneously.

**MetalLB note (two subnets):** L2 mode requires each pool on one L2 segment. We'll define two `IPAddressPool`s, advertised by nodes in their own subnet. Services pick a pool via annotation. Optional follow-up: collapse all Pis to a single VLAN at the pfSense level — simpler, but a network change you'd do separately.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  pfSense (10.0.0.1 / 10.1.0.1)                                      │
│    Unbound Resolver:                                                │
│      Domain Override: k8s.lan → <k8s_gateway LB IP>                 │
│    Existing .lan zone unchanged                                     │
└──────┬───────────────────────────────────────────────┬──────────────┘
       │ 10.1.0.0/16                                   │ 10.0.0.0/24
       │                                               │
   ┌───┴────┐  ┌───────┐  ┌───────┐               ┌────┴───┐  ┌──────┐
   │ rpid0  │  │ rpid1 │  │ rpid2 │               │ rpid3  │  │ ...  │
   │ server │  │ server│  │server │               │ agent  │  │      │
   │ + etcd │  │ +etcd │  │+ etcd │               │+storage│  │      │
   └────────┘  └───────┘  └───────┘               └────────┘  └──────┘
       k3s embedded etcd HA (3-node quorum)            k3s agents
       │           │            │                          │
       └───────────┴────────────┴──────── flannel VXLAN ───┘
                              │
                ┌─────────────┼──────────────┐
                ▼             ▼              ▼
          [ MetalLB ]   [ Longhorn ]   [ k8s_gateway ]
          L2 LB IPs     3-replica CSI  Authoritative for *.k8s.lan
                              │              │
                              └─ ingress-nginx (HTTP/S routing)
                                       │
                              [ your apps via deployment.yml ]
```

---

## Repo 1: `amun-kubernetes`

**Purpose**: install k3s on the 11 active Pis, bootstrap cluster-wide services (MetalLB, k8s_gateway, ingress-nginx, Longhorn), and host the user-facing `deployment.yml` that lists user apps.

**Convention deviation:** the existing `amun` CLI is a **per-host self-installer** (`/Users/galvarez/dev/amun/amun:60` runs `--connection=local --limit 127.0.0.1`). Clustering k3s requires central orchestration with `delegate_to`/`run_once`. We keep the `amun-X` directory shape, but add a `./deploy` wrapper that runs the playbook against the whole inventory from your laptop. `amun kubernetes` won't be the entry point for this one — `./deploy` is.

```
amun-kubernetes/
├── README.md
├── ansible.cfg                       # mirrors amun-tailscale; inventory = inventory/rpids.yml
├── main.yml                          # 4 plays: prereqs | first server | other servers | agents
├── deploy                            # bash wrapper: ansible-playbook + post-step kubeconfig fetch
├── inventory/
│   └── rpids.yml                     # static, with role groups
├── group_vars/
│   ├── all.yml                       # k3s_version, cluster_cidr, service_cidr, dns_zone=k8s.lan
│   ├── k3s_servers.yml               # server-only (etcd, api options)
│   └── k3s_agents.yml
├── requirements.yml                  # community.general, kubernetes.core, ansible.posix
├── roles/
│   ├── k3s_prereqs/                  # cgroup memory in /boot/firmware/cmdline.txt; modprobe; sysctl
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml         # reboot if cmdline changed
│   │   └── defaults/main.yml
│   ├── k3s_server/                   # downloads k3s ARM64; init OR join with K3S_TOKEN; kube-vip-free (use first server IP for join)
│   │   ├── tasks/{main,init,join}.yml
│   │   └── templates/k3s.service.j2
│   ├── k3s_agent/                    # joins as worker
│   │   └── tasks/main.yml
│   └── kubeconfig_fetch/             # rewrite localhost->rpid0; copy to ~/.kube/config-rpid
│       └── tasks/main.yml
├── cluster/                          # post-cluster bootstrap (kustomize)
│   ├── README.md
│   ├── kustomization.yaml            # root: includes everything below
│   ├── 00-namespaces/
│   ├── 10-metallb/
│   │   ├── kustomization.yaml        # remote helm chart + IPAddressPool/L2Advertisement
│   │   ├── pool-10-1-1.yaml          # 10.1.1.200-10.1.1.220 (servers + rpid7,8)
│   │   ├── pool-10-0-0.yaml          # 10.0.0.200-10.0.0.220 (rpid3-6,9,10)
│   │   └── advertisements.yaml       # nodeSelector=topology.kubernetes.io/zone
│   ├── 20-longhorn/                  # Helm values pointer; install handled by amun-longhorn
│   │   └── storageclass.yaml         # numberOfReplicas: 3 default
│   ├── 30-k8s-gateway/
│   │   ├── helmrelease.yaml          # ori-edge/k8s_gateway, domain=k8s.lan, expose as LoadBalancer
│   │   └── values.yaml
│   └── 40-ingress-nginx/
│       └── kustomization.yaml        # exposed via MetalLB; default ingress class
├── deployment/                       # USER-FACING deployment.yml lives here (folder name avoids clash with `deploy` script)
│   ├── README.md                     # "How to add a new service"
│   └── deployment.yml                # kustomize root: a list of apps to deploy
├── domain.py                         # ensures pfSense Unbound has k8s.lan → LB IP override
├── .pf-creds                         # gitignored cache of pfSense user/password (chmod 600)
└── test                              # delegates to amun framework, follows amun-tailscale pattern
```

**Naming choice:** the bash entry point is `deploy` (file). The user-edited Kustomize root lives in `deployment/` (folder) — different name avoids any path/script collision.

### Inventory (`inventory/rpids.yml`)

```yaml
all:
  vars:
    ansible_user: gonzalo
    ansible_ssh_private_key_file: ~/.ssh/gonzalo_main_private_key.pem
  children:
    k3s_servers:
      hosts:
        rpid0.lan:
          k3s_role: server-init
          subnet_zone: net-10-1-1
        rpid1.lan: { k3s_role: server-join, subnet_zone: net-10-1-1 }
        rpid2.lan: { k3s_role: server-join, subnet_zone: net-10-1-1 }
    k3s_agents:
      hosts:
        rpid3.lan:  { subnet_zone: net-10-0-0, longhorn_storage: true }
        rpid4.lan:  { subnet_zone: net-10-0-0, longhorn_storage: true }
        rpid5.lan:  { subnet_zone: net-10-0-0, longhorn_storage: true }
        rpid6.lan:  { subnet_zone: net-10-0-0, longhorn_storage: true }
        rpid7.lan:  { subnet_zone: net-10-1-1, longhorn_storage: false }
        rpid8.lan:  { subnet_zone: net-10-1-1, longhorn_storage: false }
        rpid9.lan:  { subnet_zone: net-10-0-0, longhorn_storage: false }
        rpid10.lan: { subnet_zone: net-10-0-0, longhorn_storage: false }
    excluded:
      hosts:
        rpid11.lan: { reason: "1GB RAM, Pi 3B" }
```

### Main playbook (`main.yml`)

```yaml
---
- name: Prereqs on all nodes
  hosts: k3s_servers:k3s_agents
  become: true
  roles:
    - role: k3s_prereqs

- name: Install k3s on first server (cluster-init)
  hosts: rpid0.lan
  become: true
  roles:
    - role: k3s_server
      vars: { k3s_action: init }

- name: Install k3s on remaining servers
  hosts: k3s_servers:!rpid0.lan
  become: true
  serial: 1
  roles:
    - role: k3s_server
      vars: { k3s_action: join }

- name: Install k3s on agents
  hosts: k3s_agents
  become: true
  roles:
    - role: k3s_agent

- name: Label nodes for MetalLB & Longhorn placement
  hosts: rpid0.lan
  tasks:
    - name: Label by subnet zone
      kubernetes.core.k8s:
        state: patched
        kind: Node
        name: "{{ item }}"
        definition:
          metadata:
            labels:
              topology.kubernetes.io/zone: "{{ hostvars[item].subnet_zone }}"
              storage.amun/role: "{{ 'replica' if (hostvars[item].longhorn_storage|default(true)) else 'none' }}"
      loop: "{{ groups['k3s_servers'] + groups['k3s_agents'] }}"

- name: Fetch kubeconfig
  hosts: rpid0.lan
  roles:
    - role: kubeconfig_fetch
```

### k3s install role essentials (`roles/k3s_server/tasks/init.yml`)

```yaml
- name: Generate cluster token (once on init host)
  ansible.builtin.set_fact:
    k3s_token: "{{ lookup('password', '/dev/null length=64 chars=ascii_letters,digits') }}"

- name: Persist token in vault file (or pass via group_vars)
  delegate_to: localhost
  ansible.builtin.copy:
    dest: "{{ playbook_dir }}/.k3s_token"
    content: "{{ k3s_token }}"
    mode: "0600"

- name: Install k3s server (cluster-init with embedded etcd)
  ansible.builtin.shell: |
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION={{ k3s_version }} \
      K3S_TOKEN={{ k3s_token }} \
      INSTALL_K3S_EXEC="server --cluster-init --disable=servicelb --disable=traefik \
                         --tls-san={{ inventory_hostname }} \
                         --node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule \
                         --kubelet-arg=eviction-hard=memory.available<150Mi" \
      sh -
```

Key flags chosen:
- `--cluster-init` enables embedded etcd
- `--disable=servicelb` (Klipper) — MetalLB will replace it
- `--disable=traefik` — we install ingress-nginx instead (more standard, ARM64 strong)
- Server taint keeps user pods off control-plane unless they tolerate it
- Eviction tuned for 4GB Pis

### `cluster/kustomization.yaml` (cluster bootstrap, applied AFTER cluster is up)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - 00-namespaces
  - 10-metallb
  - 30-k8s-gateway
  - 40-ingress-nginx
# 20-longhorn is installed by amun-longhorn (it needs node prereqs first)
```

### MetalLB pool YAML

```yaml
# cluster/10-metallb/pool-10-1-1.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: pool-10-1-1, namespace: metallb-system }
spec:
  addresses: [ "10.1.1.200-10.1.1.220" ]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: adv-10-1-1, namespace: metallb-system }
spec:
  ipAddressPools: [ pool-10-1-1 ]
  nodeSelectors:
    - matchLabels: { topology.kubernetes.io/zone: net-10-1-1 }
```

(Symmetric file for `pool-10-0-0` covering 10.0.0.200-220 and `net-10-0-0`.)

### k8s_gateway YAML (cluster/30-k8s-gateway/helmrelease.yaml)

```yaml
# Installed via Ansible kubernetes.core.helm; values:
domain: k8s.lan
service:
  type: LoadBalancer
  annotations:
    metallb.io/address-pool: pool-10-0-0   # pin to one subnet so pfSense Domain Override has a stable IP
    metallb.io/loadBalancerIPs: "10.0.0.210"
watchedResources: [ "Ingress", "Service" ]
fallthrough:
  enabled: false
ttl: 30
```

**This step is automated** — `./domain.py` (called by `./deploy`) performs the equivalent of: pfSense → Services → DNS Resolver → Domain Overrides → add `Domain: k8s.lan`, `IP: 10.0.0.210`, then **Apply Changes**. You can also run `./domain.py` manually any time the LB IP changes.

### USER-FACING `deployment/deployment.yml`

This is the file you edit to add services. It's a Kustomize root pointing at app sub-kustomizations:

```yaml
# deployment/deployment.yml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  # add a line per app — local path or remote git URL works
  - github.com/gonzaloalvarez/cn-helloworld//k8s?ref=main
  # - github.com/gonzaloalvarez/cn-grafana//k8s?ref=main
```

To deploy: `kubectl apply -k deployment/`. To remove: `kubectl delete -k deployment/`. Adding a new service = one new line.

### `deploy` wrapper script (entry point)

```bash
#!/bin/bash
# amun-kubernetes/deploy — bring up cluster end-to-end
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ansible-galaxy install -r requirements.yml
ansible-playbook -i inventory/rpids.yml main.yml "$@"

export KUBECONFIG="$HOME/.kube/config-rpid"
kubectl apply -k cluster/
kubectl rollout status -n metallb-system deploy/metallb-controller --timeout=180s
kubectl rollout status -n kube-system  deploy/k8s-gateway --timeout=180s

# pfSense Domain Override (idempotent; prompts for creds first run, then caches)
./domain.py

echo "✓ cluster up. now bring up user apps:"
echo "  kubectl apply -k deployment/"
```

### `domain.py` — pfSense Domain Override automation

A small Python script that talks to the pfSense web UI (no extra packages required on pfSense) to ensure `k8s.lan` resolves to the k8s_gateway LoadBalancer IP. **Spec:**

- Detects pfSense as the system default gateway: `route -n get default` (macOS) or `ip route show default` (Linux). No hardcoded IP.
- First run prompts for username + password; caches them as JSON in `.pf-creds` next to the script with `chmod 600`. Subsequent runs read from cache.
- Detects the desired target IP from `kubectl -n kube-system get svc k8s-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` (or accepts `--ip`).
- Logs into pfSense (handles `__csrf_magic`), reads `/services_unbound.php` to list current Domain Overrides, and:
  - if `k8s.lan` exists with the correct IP → no-op, prints `✓ k8s.lan already → 10.0.0.210`
  - if exists with wrong IP → POSTs to `/services_unbound_domainoverride_edit.php?id=<idx>` to update
  - if missing → POSTs the same edit endpoint (no `id`) to create
  - then POSTs to `/services_unbound.php` with `apply=Apply Changes` so the change takes effect
- Flags: `--ip <addr>` (override auto-detect), `--domain <name>` (default `k8s.lan`), `--refresh-creds` (delete `.pf-creds` and re-prompt).
- Exits non-zero with a clear message on login failure, parse failure, or unreachable gateway.

**Dependencies:** Python 3.11+, `requests` (only). Add to `requirements.txt` at repo root: `requests>=2.32`. The script disables TLS verification because pfSense uses a self-signed cert by default — comment in code explains this is the intended local-network use case.

**Standalone use:** `./domain.py` runs end-to-end on its own. The `deploy` wrapper calls it; users can also run it any time the LB IP changes.

**`.gitignore` entry:** `.pf-creds` and `.k3s_token` must be in `.gitignore`.

---

## Repo 2: `amun-longhorn`

**Purpose**: install Longhorn prereqs on storage nodes + run Helm install + create the default StorageClass with 3 replicas. Follows the standard `amun-X` Ansible shape.

```
amun-longhorn/
├── README.md
├── ansible.cfg
├── main.yml                  # - hosts: k3s_agents:k3s_servers / roles: [longhorn]
├── localhost                 # for amun CLI compat (no-op)
├── inventory/
│   └── rpids.yml             # symlink or copy from amun-kubernetes (or pull via requirements)
├── group_vars/
│   └── all.yml
├── requirements.yml          # community.general, kubernetes.core, ansible.posix
├── roles/longhorn/
│   ├── tasks/
│   │   ├── main.yml          # imports prereqs.yml then helm.yml
│   │   ├── prereqs.yml       # apt: open-iscsi, nfs-common, util-linux; modprobe iscsi_tcp;
│   │   │                     # mkdir /var/lib/longhorn; conditional on longhorn_storage=true
│   │   └── helm.yml          # delegate_to first k3s server: helm install longhorn
│   ├── handlers/main.yml
│   ├── defaults/main.yml     # longhorn_version, replicas: 3, storage_path: /var/lib/longhorn
│   └── meta/main.yml
├── test                      # mirrors amun-tailscale/test pattern
└── deploy                    # ansible-playbook -i inventory/rpids.yml main.yml
```

### `roles/longhorn/tasks/prereqs.yml`

```yaml
- name: Install Longhorn host requirements
  ansible.builtin.apt:
    name: [ open-iscsi, nfs-common, util-linux, jq ]
    state: present
    update_cache: true
  when: longhorn_storage | default(true)

- name: Enable iscsid
  ansible.builtin.systemd:
    name: iscsid
    enabled: true
    state: started
  when: longhorn_storage | default(true)

- name: Ensure longhorn data dir exists
  ansible.builtin.file:
    path: "{{ longhorn_storage_path }}"
    state: directory
    mode: "0755"
  when: longhorn_storage | default(true)
```

### `roles/longhorn/tasks/helm.yml`

```yaml
- name: Install Longhorn via Helm (run once on first server)
  delegate_to: rpid0.lan
  run_once: true
  block:
    - kubernetes.core.helm_repository:
        name: longhorn
        repo_url: https://charts.longhorn.io
    - kubernetes.core.helm:
        name: longhorn
        chart_ref: longhorn/longhorn
        chart_version: "{{ longhorn_version }}"
        release_namespace: longhorn-system
        create_namespace: true
        wait: true
        values:
          defaultSettings:
            defaultDataPath: "{{ longhorn_storage_path }}"
            defaultReplicaCount: 3
            createDefaultDiskLabeledNodes: true
            replicaSoftAntiAffinity: false   # spread across nodes
            replicaZoneSoftAntiAffinity: false
          persistence:
            defaultClass: true
            defaultClassReplicaCount: 3
            reclaimPolicy: Retain
          longhornUI:
            replicas: 1

- name: Label storage-eligible nodes
  delegate_to: rpid0.lan
  run_once: true
  kubernetes.core.k8s:
    state: patched
    kind: Node
    name: "{{ item }}"
    definition:
      metadata:
        labels:
          node.longhorn.io/create-default-disk: "true"
  loop: "{{ groups['k3s_servers'] + (groups['k3s_agents'] | select('match', '.*') | list) }}"
  when: hostvars[item].longhorn_storage | default(true)
```

---

## Repo 3: `cn-helloworld`

**Purpose**: smallest real app that proves end-to-end works — has a PVC (Longhorn), a Service, an Ingress (k8s_gateway picks it up automatically), so `curl http://hello.k8s.lan` returns "hello from <pod>".

```
cn-helloworld/
├── README.md
├── k8s/                            # kustomize base — referenced from deployment/deployment.yml
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── pvc.yaml
└── deployment.yml                  # convenience: copy/symlink of k8s/kustomization.yaml at root
```

### `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: helloworld, labels: { app: helloworld } }
spec:
  replicas: 2
  selector: { matchLabels: { app: helloworld } }
  template:
    metadata: { labels: { app: helloworld } }
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:0.9.2     # multi-arch incl arm64
          ports: [ { containerPort: 80 } ]
          env:
            - { name: PORT, value: "80" }
          volumeMounts:
            - { name: data, mountPath: /data }
          resources:
            requests: { cpu: 50m,  memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: helloworld-data }
```

### `k8s/pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: helloworld-data }
spec:
  accessModes: [ ReadWriteOnce ]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
```

### `k8s/ingress.yaml` (DNS-friendly: k8s_gateway sees this and serves `hello.k8s.lan`)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: helloworld
  annotations:
    coredns.io/hostname: hello.k8s.lan        # k8s_gateway hint (also reads spec.rules)
spec:
  ingressClassName: nginx
  rules:
    - host: hello.k8s.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: helloworld
                port: { number: 80 }
```

### `k8s/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [ deployment.yaml, service.yaml, ingress.yaml, pvc.yaml ]
commonLabels: { app: helloworld }
```

---

## READMEs — content & management commands per repo

Every repo gets a `README.md` written for *future-you-on-a-Tuesday-morning*: title, one-paragraph what-this-is, a "Quick start" block, a "**Health check**" block with copy-pasteable commands that show whether the system is OK, and a "**Common tasks**" block (drain a node, replace a disk, recover a failed Pi, add an app).

### `amun-kubernetes/README.md` — outline

```markdown
# amun-kubernetes

k3s on 11 Raspberry Pis (rpid0..rpid10), with embedded etcd HA on rpid0/1/2,
MetalLB load balancer (two L2 pools, one per subnet), ingress-nginx, and
k8s_gateway exposing services as `<name>.k8s.lan` via pfSense Domain Override.

## Quick start

    ./deploy            # provisions all nodes + cluster services + pfSense override
    export KUBECONFIG=~/.kube/config-rpid
    kubectl get nodes

## Health check (one-liners)

    # nodes
    kubectl get nodes -o wide
    kubectl top nodes                                    # needs metrics-server (installed)
    kubectl describe nodes | grep -A4 'Conditions:' | grep -E '(Ready|Pressure)'

    # control plane / etcd
    kubectl get pods -n kube-system
    ssh rpid0.lan sudo k3s etcd-snapshot ls              # last snapshots
    kubectl get --raw='/readyz?verbose' | tail -20

    # workloads + events
    kubectl get pods -A | grep -vE 'Running|Completed'   # anything not happy
    kubectl get events -A --sort-by=.lastTimestamp | tail -20

    # network: MetalLB + ingress
    kubectl -n metallb-system get ipaddresspools,l2advertisements
    kubectl get svc -A | grep LoadBalancer
    kubectl -n ingress-nginx get pods,svc

    # DNS
    kubectl -n kube-system logs deploy/k8s-gateway --tail=20
    dig @$(kubectl -n kube-system get svc k8s-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}') hello.k8s.lan +short

## Add a service

    # 1. Create cn-<name> repo with k8s/kustomization.yaml
    # 2. Append one line to deployment/deployment.yml:
    echo '  - github.com/gonzaloalvarez/cn-<name>//k8s?ref=main' >> deployment/deployment.yml
    # 3. Apply
    kubectl apply -k deployment/

## Common tasks

    # Drain a node for maintenance
    kubectl cordon rpid7.lan
    kubectl drain rpid7.lan --ignore-daemonsets --delete-emptydir-data
    # ...do work...
    kubectl uncordon rpid7.lan

    # Reboot a node safely
    kubectl drain rpid7.lan --ignore-daemonsets --delete-emptydir-data
    ssh rpid7.lan sudo reboot
    # wait for Ready, then:
    kubectl uncordon rpid7.lan

    # Upgrade k3s — edit group_vars/all.yml: k3s_version: vX.Y.Z+k3s1
    ./deploy --tags k3s_upgrade

    # Re-fetch kubeconfig after re-IP
    ./deploy --tags kubeconfig

    # Forget cached pfSense creds
    ./domain.py --refresh-creds

    # Reset a node (destructive!)
    ssh rpidX.lan sudo /usr/local/bin/k3s-uninstall.sh   # for servers
    ssh rpidX.lan sudo /usr/local/bin/k3s-agent-uninstall.sh   # for agents
```

### `amun-longhorn/README.md` — outline

```markdown
# amun-longhorn

Longhorn distributed block storage for amun-kubernetes. 3-way replica by default
(survives 2 simultaneous node failures). 7 storage nodes (rpid0..rpid6, the 1TB SDs);
rpid7..rpid10 are compute-only.

## Quick start

    ./deploy            # installs prereqs (open-iscsi, nfs-common) + Longhorn helm chart

## Health check

    # core CRDs
    kubectl -n longhorn-system get nodes.longhorn.io -o wide          # node State, AllowScheduling
    kubectl -n longhorn-system get volumes -o wide                    # State, Robustness, replicas
    kubectl -n longhorn-system get replicas -o wide                   # which volume on which node
    kubectl -n longhorn-system get engines                            # active engines per volume
    kubectl -n longhorn-system get backingimages                      # if you use them

    # quick "is anything degraded?"
    kubectl -n longhorn-system get volumes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.state}{"\t"}{.status.robustness}{"\n"}{end}'

    # disk usage per node
    kubectl -n longhorn-system get nodes.longhorn.io \
      -o custom-columns='NAME:.metadata.name,SCHEDULABLE:.spec.allowScheduling,READY:.status.conditions[?(@.type=="Ready")].status,DISKS:.status.diskStatus'

    # the UI (visual + actions)
    kubectl -n longhorn-system port-forward svc/longhorn-frontend 8000:80
    open http://localhost:8000

## Common tasks

    # Replace a failed Pi: install OS, run amun-kubernetes/deploy with new node added,
    # then ./deploy here — Longhorn auto-rebuilds replicas on the new node.

    # Add a new disk to a storage node (USB SSD)
    ssh rpid3.lan sudo mkdir -p /mnt/longhorn-ssd
    # mount it persistently in /etc/fstab, then in Longhorn UI:
    #   Node > rpid3 > Edit Node and Disks > add /mnt/longhorn-ssd

    # Take a manual snapshot of a volume
    kubectl -n longhorn-system create -f - <<'YAML'
    apiVersion: longhorn.io/v1beta2
    kind: Snapshot
    metadata: { name: my-snap, namespace: longhorn-system }
    spec: { volume: <pvc-uuid-as-volume> }
    YAML

    # Backup target (S3/NFS) — set in UI: Setting > General > Backup Target
```

### `cn-helloworld/README.md` — outline

```markdown
# cn-helloworld

Smallest cluster smoketest: an echo server with a 1Gi Longhorn PVC and an Ingress.
Reachable as http://hello.k8s.lan after deploy.

## Deploy

    kubectl apply -k k8s/        # standalone
    # or list it in amun-kubernetes/deployment/deployment.yml and run that.

## Health check

    kubectl get pods -l app=helloworld -o wide          # 2 replicas, on different nodes
    kubectl get pvc helloworld-data                     # Bound, longhorn StorageClass
    kubectl get ingress helloworld
    curl -sS http://hello.k8s.lan/ | jq .host           # echoes the request

    # storage round-trip
    kubectl exec deploy/helloworld -- sh -c 'date >> /data/log; cat /data/log'

## Remove

    kubectl delete -k k8s/
```

---

## Existing utilities & patterns to reuse

- **amun-tailscale layout** (`/Users/galvarez/dev/amun-tailscale/`) — exact `ansible.cfg`, `main.yml`, `localhost`, `test` script, README structure. Both new amun repos copy this verbatim.
- **`amun-tailscale/test`** (`/Users/galvarez/dev/amun-tailscale/test:1`) — the test harness pattern (clones amun, calls `amun/test -p <plugin>`).
- **`amun/main.yml`** (`/Users/galvarez/dev/amun/main.yml:1`) — multi-role play with `when:` guards is the model for our k3s_prereqs / k3s_server / k3s_agent split.
- **`cn-vaultwarden` `setup.sh`** — env-prompting style that `cn-helloworld` README borrows for "how to set the LB IP" pre-flight.

---

## Order of operations (end-to-end)

1. **Create three GitHub repos** under `gonzaloalvarez` (public):
   ```
   gh repo create gonzaloalvarez/amun-kubernetes --public --description "k3s on the rpid* fleet"
   gh repo create gonzaloalvarez/amun-longhorn   --public --description "Longhorn storage for amun-kubernetes"
   gh repo create gonzaloalvarez/cn-helloworld   --public --description "Hello-world test app for amun-kubernetes"
   ```
2. **Scaffold each repo locally** in `/Users/galvarez/dev/`, commit, push.
3. **Run `amun-kubernetes/deploy`** from your laptop — installs k3s, applies cluster bootstrap, writes `~/.kube/config-rpid`, **and** runs `domain.py` to set the pfSense override (prompts for pfSense creds the first time, caches them in `.pf-creds`).
4. **Run `amun-longhorn/deploy`** — installs storage prereqs and Longhorn, creates `longhorn` StorageClass.
5. **Push `cn-helloworld`**, then `cd amun-kubernetes && kubectl apply -k deployment/`.

---

## Verification (proves the user's two requirements: 2-failure tolerance + DNS workflow)

```bash
# 1) Cluster healthy, all 11 nodes Ready
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running    # should be empty

# 2) Longhorn shows 3 replicas spread across 3 storage nodes
kubectl -n longhorn-system get volumes,replicas
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8000:80
# UI: http://localhost:8000 → Volume → 3 replicas, on 3 different nodes

# 3) DNS works through pfSense
dig @<pfsense_ip> hello.k8s.lan +short        # → 10.0.0.200ish (an ingress LB IP)
curl http://hello.k8s.lan/                    # → echo server reply

# 4) Two-failure resilience drill (the headline requirement):
#    Pick any 2 storage nodes, power them off (or kubectl drain + cordon).
ssh rpid3.lan sudo systemctl stop k3s-agent
ssh rpid4.lan sudo systemctl stop k3s-agent
sleep 60
kubectl exec -it deploy/helloworld -- sh -c 'echo "still alive: $(date)" >> /data/log'
kubectl exec -it deploy/helloworld -- cat /data/log     # write succeeded
# Restore:
ssh rpid3.lan sudo systemctl start k3s-agent
ssh rpid4.lan sudo systemctl start k3s-agent
# Longhorn rebuilds replicas automatically; check progress in UI.

# 5) Add a new service: edit amun-kubernetes/deployment/deployment.yml,
#    add `- github.com/gonzaloalvarez/cn-newapp//k8s?ref=main`, then:
kubectl apply -k deployment/
```

---

## Critical files & paths to remember

- `inventory/rpids.yml` — the source of truth for node roles and subnet zones
- `cluster/kustomization.yaml` — order of cluster-bootstrap manifests
- `cluster/30-k8s-gateway/helmrelease.yaml` — the LB IP `10.0.0.210` must match the pfSense Domain Override
- `deployment/deployment.yml` — your hand-edited list of services (the user-facing file)
- `domain.py` + `.pf-creds` — pfSense DNS automation; first run prompts for creds, caches them locally (chmod 600, gitignored)
- `roles/longhorn/defaults/main.yml` — `longhorn_version`, `replicas: 3`, data path
- `~/.kube/config-rpid` — kubeconfig fetched after install; `export KUBECONFIG=~/.kube/config-rpid`

---

## Known caveats / decisions made

1. **rpid11 (Pi 3B, 1GB)** — excluded initially. Can add later as a low-priority worker with `kubectl taint nodes rpid11.lan low-mem=true:PreferNoSchedule` once you've validated the cluster.
2. **SD-card storage for Longhorn** — SD cards have weak random write endurance. Acceptable for a homelab, but expect periodic SD wear. Future: replace 1TB SD on rpid0-6 with USB-attached SSDs; Longhorn's data path is configurable per node (`/var/lib/longhorn`).
3. **Two MetalLB pools** — works today. If you collapse to one VLAN later, drop one pool and the L2Advertisement nodeSelector.
4. **k8s_gateway pinned to `10.0.0.210`** — chose 10.0.0.x because more nodes (8) live there than 10.1.1.x (5). Pin lives in `cluster/30-k8s-gateway/helmrelease.yaml`. Change if you re-IP.
5. **Helm vs Kustomize** — Longhorn ships Helm-only; we use it via `kubernetes.core.helm`. MetalLB and k8s_gateway are also Helm under the hood but we wrap with kustomize for declarative `cluster/` bootstrap.
6. **No GitOps controller (yet)** — kept it `kubectl apply -k`-driven. Argo CD on Pis works fine but adds a manager pod (~150MB) and complexity. Easy to add later by deploying it to `cluster/50-argocd/` and pointing it at `deployment/`.

7. **`domain.py` is form-scraping pfSense, not using a public API** — pfSense's official scriptable surface is the legacy XML-RPC, which is read-only for many things and inconsistent. Form-scraping the web UI works on every pfSense version, but if the UI markup changes drastically across pfSense releases, the regex in `domain.py` may need a tweak. The script is intentionally short (~120 lines) so this is easy.
