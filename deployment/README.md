# deployment/

This is the **single file you edit to manage user-deployed services** on the
cluster: `deployment.yml`. It's a Kustomize root that lists each app's
manifests (local path, or remote git URL).

## Usage

```sh
# Apply everything listed in deployment.yml
kubectl --kubeconfig=$KUBECONFIG apply -k .

# Remove everything
kubectl delete -k .

# Show what would change
kustomize build . | kubectl diff -f -    # if you have kustomize CLI
```

## Adding a new service

1. Create a `cn-<name>` repo with a `k8s/` folder containing a
   `kustomization.yaml` (see `cn-helloworld` for an example).
2. Add one line to `deployment.yml`:
   ```yaml
   resources:
     - github.com/GonzaloAlvarez/cn-helloworld//k8s?ref=main
     - github.com/GonzaloAlvarez/cn-newapp//k8s?ref=main
   ```
3. `kubectl apply -k .`

## Why a single file?

The aim is the simplest possible "edit YAML, get cluster state" workflow.
No GitOps controller, no Argo CD app-of-apps, no multi-step deploy. Just:

> `vim deployment.yml && kubectl apply -k .`

Easy to reason about. Easy to recover from. Argo CD can be added later by
deploying it to `cluster/50-argocd/` and pointing it at this same file.
