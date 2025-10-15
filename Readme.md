# Generate Kubeconfig

> Dont let stupid user mess your cluster

# Prerequisites

```bash
cp /path/to/ca.crt tmp/
cp /path/to/ca.key tmp/
cp /path/to/admin.kubeconfig tmp/
```

# Build & RUN

```bash
docker-compose build
docker-compose run k8s-provisioner alice alice@example.com alice-ns team-b team-b
```

