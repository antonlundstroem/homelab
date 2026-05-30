# OIDC / centralized identity for the homelab

Plan for adding a self-hosted OIDC IdP so workloads, humans, and external clients
share one identity story. Not yet implemented — capture of the design discussion.

## Why

Today:
- Workloads use static credentials (e.g. `rustfs-creds` Sealed Secret copied per
  namespace).
- There is no central identity for humans (laptop, future CI outside the cluster)
  or for cross-cluster / non-k8s clients.
- Each new app that needs login (ArgoCD UI, Grafana, MLflow UI, RustFS console)
  reinvents auth.

Goal: an Azure-like setup where pods get short-lived credentials via OIDC token
exchange, and humans log in once via a central IdP.

## STS, in one paragraph

STS = Security Token Service. A service you call with proof of identity (an OIDC
JWT, another credential, a SAML assertion) that returns a short-lived
`(access_key, secret_key, session_token)` triple scoped to a policy. AWS coined
it; MinIO/RustFS implement an AWS-compatible STS endpoint. Same shape as
long-lived S3 keys, but expires in ~1h and is bound to a specific workload.

Azure analogue: Workload Identity Federation. Pod has a federated identity, AAD's
STS exchanges a projected SA token for a storage/graph token, the Azure SDK does
it transparently via env vars. We rebuild that flow in-cluster, with k3s as the
IdP for workloads and a separate IdP (Authentik) for humans.

## Architecture: two issuers

```
┌──────────────────┐                ┌──────────────────┐
│ k3s apiserver    │  workload      │ Authentik        │  human + cross-
│ (issuer #1)      │  identity      │ (issuer #2)      │  cluster identity
│ → SA tokens      │                │ → user JWTs      │
└────────┬─────────┘                └────────┬─────────┘
         │                                   │
         └────────────┬──────────────────────┘
                      ▼
              ┌──────────────┐
              │ RustFS STS   │ trusts both issuers,
              │              │ maps each → policies
              └──────────────┘
```

- **In-cluster workloads** keep using SA tokens → RustFS STS. No extra hop.
- **Humans + external clients** flow through Authentik → RustFS STS (or directly
  to whatever app does OIDC SSO).

Pushing everything through Authentik (workloads federate their SA token to
Authentik, then use the resulting token) is possible but adds a hop and makes
Authentik a hard dependency for every pod call. Two issuers is what enterprises
actually run.

## IdP choice

| Tool | Shape | Best for |
|---|---|---|
| **Authentik** | Full IdP, batteries-included UI, OIDC/SAML/LDAP/MFA | Homelab sweet spot — recommended |
| **Keycloak** | Enterprise IdP, heavy JVM, realm/client model = closest to Entra/AAD | "Nobody got fired" choice; what enterprises actually run |
| **Zitadel** | Modern Go IdP, multi-tenant, Auth0-shaped UX | If you like newer/leaner; smaller ecosystem |
| **Dex** | Pure OIDC frontend, **no user DB** — federates to GitHub/LDAP/etc. | When identity lives elsewhere and you only need OIDC translation |
| **Ory Hydra + Kratos + Oathkeeper** | Composable OAuth/OIDC building blocks | DIY assembly; high power, high effort |

Recommendation: **Authentik.**

- One Postgres (cnpg already in cluster) + one Redis. Fits existing patterns.
- Web UI for users/groups/applications/providers — no YAML for everyday changes.
- Per-application OIDC clients are a 30-second click.
- Active homelab community, good docs.
- Has a NixOS module if ever run outside the cluster.

Pick **Keycloak** instead if mirroring AAD docs in your head matters — its
federated-credentials concept maps almost 1:1 to Azure Workload Identity. Cost
is ~1GB resident JVM.

## Pieces of the workload-side flow (RustFS as the example)

```
┌─────────────────────┐
│ k3s apiserver       │  OIDC issuer (already is one)
│  /.well-known/...   │  signs SA JWTs, publishes JWKS
└──────┬──────────────┘
       │ JWKS fetch
       ▼
┌─────────────────────┐
│ RustFS STS          │  trusts k3s issuer, maps JWT claims
│ AssumeRoleWith-     │  → policy, returns temp S3 creds
│ WebIdentity         │
└──────▲──────────────┘
       │ exchange
┌──────┴──────────────┐
│ Training pod        │  boto3/aws-cli sees AWS_WEB_IDENTITY_*
│ SA: training-runner │  env vars, does the exchange itself
└──────▲──────────────┘
       │ injects projected token + env vars
┌──────┴──────────────┐
│ pod-identity        │  mutating webhook keyed on SA annotation
│ webhook             │  (eks-pod-identity-webhook works fine)
└─────────────────────┘
```

## Setup, in order

1. **Verify k3s OIDC issuer.** Should already work:
   ```sh
   kubectl get --raw /.well-known/openid-configuration | jq
   kubectl get --raw /openid/v1/jwks | jq
   ```
   If a stable external issuer URL is wanted (e.g. for laptop logins later), set
   `--kube-apiserver-arg=service-account-issuer=https://...` via
   `services.k3s.extraFlags` in `nixos/nodes/node01/configuration.nix`. For
   pod-only flows the in-cluster URL is fine.

2. **Verify RustFS speaks OIDC STS.** Load-bearing assumption — MinIO has it,
   RustFS is newer. Check the rustfs chart values for `oidc:` / `identityProvider:`
   / `sts:` keys before designing around it. If RustFS doesn't have OIDC STS yet,
   the cleanest swap is MinIO (drop-in S3 compat, rock-solid OIDC). Worth checking
   now, not after wiring everything else.

3. **Configure RustFS** with:
   - Issuer URL: `https://kubernetes.default.svc` (or external one)
   - JWKS URL: same issuer's `/openid/v1/jwks`
   - Expected audience: e.g. `sts.rustfs`
   - Claim → policy mapping: typically maps `sub`
     (= `system:serviceaccount:<ns>:<sa>`) to a named policy.

4. **Write the RustFS policies.** Same JSON shape as IAM:
   ```json
   { "Statement": [{
       "Effect": "Allow",
       "Action": ["s3:GetObject", "s3:ListBucket"],
       "Resource": ["arn:aws:s3:::mlflow", "arn:aws:s3:::mlflow/datasets/*"]
   }]}
   ```
   Bind to the SA via the claim mapping.

5. **Deploy `aws/amazon-eks-pod-identity-webhook`** (or equivalent CNCF
   `pod-identity-webhook` projects). Mutating admission webhook that, when a pod's
   SA is annotated, injects:
   - `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/sts.rustfs/token`
   - `AWS_ROLE_ARN=arn:aws:iam::000000000000:role/training-reader`
   - A projected SA token volume with the right audience

   Despite the "EKS" name, it works against any OIDC-enabled S3 — it just sets
   env vars the AWS SDK reacts to.

6. **Annotate the training SA:**
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: training-runner
     namespace: arc-runners
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/training-reader
       eks.amazonaws.com/audience: sts.rustfs
   ```
   The "account ID" is meaningless to RustFS but the SDK requires the ARN format.

7. **Point boto3 at RustFS's STS.** Two env vars, no code change:
   ```sh
   AWS_ENDPOINT_URL_STS=https://rustfs-svc.rustfs.svc.cluster.local:9000
   AWS_ENDPOINT_URL_S3=https://rustfs-svc.rustfs.svc.cluster.local:9000
   ```

8. **Open the NetworkPolicy** to rustfs (tighten the existing
   `gitops/manifests/arc/networkpolicy.yaml` and add a rustfs egress rule scoped
   to the rustfs Service on port 9000).

After that the training pod is essentially Azure-shaped: no static secrets in
the pod spec, no Sealed Secret per workload, identity is the SA, policy is a
string mapping.

## Authentik fit in the existing patterns

- **Deploy via ArgoCD**: `gitops/manifests/authentik/` + `gitops/argocd/authentik.yaml`.
  Upstream Helm chart.
- **Postgres**: another cnpg `Cluster` (already used for `mlflow-db`).
- **Ingress**: Tailscale class, same pattern as ArgoCD/MLflow →
  `authentik.<tailnet>.ts.net`.
- **Bootstrap admin password**: sops-nix sealed secret, same pattern as
  `rustfs-creds`.
- **Backup**: cnpg already handles Postgres backups; Authentik state is mostly
  in Postgres + a small media volume.

## Gotchas

- **No central identity directory equivalent.** Azure has Entra; here, k8s SAs
  *are* the workload identity. Simple, but doesn't extend to laptops/CI outside
  the cluster — that's exactly what Authentik is added for.
- **One audience per projected token volume.** A pod that needs to talk to two
  OIDC-protected services with different `aud` requirements needs two volumes.
- **Per-pod scoping = per-pod SA.** Policies key off the SA. If runner-A and
  runner-B need different data access, they need different SAs.
- **JWKS caching.** RustFS will cache the JWKS. If the apiserver SA signing key
  is rotated (rare, happens on cluster rebuild), STS exchanges fail until the
  cache TTL elapses.
- **`rustfs-creds` Sealed Secret** for workloads becomes obsolete, but keep one
  set of bootstrap admin keys for human/CI ops outside the OIDC flow.
- **Chicken-and-egg.** If Authentik is down, you can't log in to fix Authentik.
  Mitigations:
  - Keep a break-glass static admin password in 1Password / sops for ArgoCD
    specifically.
  - Keep the bootstrap RustFS root credentials usable from the laptop — that
    path bypasses Authentik entirely.
