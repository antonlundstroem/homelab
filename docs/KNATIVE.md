# Knative Serving for the homelab

Plan for adding Knative Serving so intermittently-used workloads (kserve
inference, future webhook handlers, internal tools) can scale to zero. Not yet
implemented — capture of the design discussion.

## Why

Today every workload in the cluster is a plain `Deployment` with at least one
replica running 24/7. On a single-node k3s VM every idle pod costs RAM that
could go to something else. Knative Serving adds:

- **Scale-to-zero** — pods exit ~60s after the last request; first request
  after idle triggers a cold start (typically 1–5s, longer for big images or
  ML models).
- **Request-based autoscaling** — scales on concurrent in-flight requests, not
  CPU%. Sane default for HTTP workloads.
- **Revisions + traffic splitting** — every deploy is an immutable Revision;
  splits like `90/10 v1/v2` are one field. Built-in canary, no extra controller.

Immediate driver: **kserve** wants Knative for `InferenceService`. Long term,
anything called by a human a few times a day (Grafana, future model demos,
webhook receivers, internal tools) is a fit.

## When it's worth using

The axis isn't "website vs microservice" — it's "how idle is the thing and can
the caller tolerate a cold start?"

| | Mostly idle | Steady traffic |
|---|---|---|
| Cold start tolerable (1–5s) | Good fit | Just overhead |
| Cold start unacceptable | Knative + `minScale: 1` (defeats the point) | Plain Deployment |

Sweet spot for this homelab:

- Internal tools you touch for 10 min/week (dashboards, admin UIs).
- ML inference endpoints with expensive idle cost (GPU, large model in RAM).
- Webhook handlers / event-triggered jobs.

Bad fit: anything on the hot path of an always-on service, or a single 50 MB
sidecar where the Knative system overhead (~6 pods) costs more than the thing
you're trying to save.

## Architecture

Knative Serving runs ~6 system pods in `knative-serving`:

- **controller** — reconciles the `Service` / `Configuration` / `Revision` /
  `Route` CRDs into `Deployment` + `Service` + HPA + routing rules.
- **webhook** — validating/mutating admission for the CRDs.
- **autoscaler** — watches request metrics, decides how many pods each
  Revision needs (including zero).
- **activator** — buffers requests for revisions that are scaled to zero,
  triggers the autoscaler to spin them up, then forwards the request.
- **net-kourier-controller** + **3scale-kourier-gateway** — translates
  Knative routes into Kourier (Envoy) config, plus the Envoy data plane.

```
client ──► kourier ──► [pod count > 0] ─────► revision pod
                   └─► [scaled to zero] ───► activator ──► autoscaler
                                                      └─► revision pod
                                                          (then proxied)
```

Once a revision is "stable" (~30s past its last scale event) requests bypass
the activator and go straight to pods. The activator is only in the path
during cold start and rapid scale-up.

## Networking layer choice

Knative needs a networking layer to handle ingress and intra-cluster routing.
Three supported options:

| Tool | Notes |
|---|---|
| **Kourier** | Tiny Envoy-based ingress, ships with Knative, two pods. Best for single-node homelab. **Recommended.** |
| **Istio** | Full service mesh; massive overkill unless mTLS/policy across the cluster is also wanted. |
| **Contour** | Envoy-based, comparable to Kourier; pick if it'd be the cluster's main ingress anyway. |

Co-exists with `ingress-nginx` (today's main ingress) by giving Kourier its own
Service and not registering as an `IngressClass`. Knative routes go through
Kourier; everything else stays on ingress-nginx. Two ingress controllers on
the same node is fine on k3s with the default ServiceLB — just keep the
nodePorts straight.

## kserve-specific question: do we even need Knative?

kserve has two deployment modes, set per `InferenceService` or as the chart
default:

1. **Serverless** (default) — `InferenceService` → Knative `Service` →
   scale-to-zero, traffic splitting, all the goodies. Requires Knative.
2. **RawDeployment** — `InferenceService` → plain `Deployment` + HPA, no
   Knative anywhere. Lose scale-to-zero and revision-based traffic splitting.

If the only reason for Knative is kserve and scale-to-zero on models isn't
actually wanted (small CPU classifier always warm), flip kserve to
RawDeployment via the `serving.kserve.io/deploymentMode: RawDeployment`
annotation (or the chart default) and skip Knative entirely. Decision rule:
GPU / large model / cold-start-tolerant → Serverless. Small CPU model that
must respond in <100ms → Raw.

## Setup, in order

Pre-req: pick a `targetRevision` from the Knative Operator releases at
https://github.com/knative/operator/releases.

1. **Deploy the Knative Operator** as an ArgoCD Application:
   `gitops/manifests/knative/` + `gitops/argocd/knative.yaml`. The Operator
   chart is the easy path — it owns the lifecycle of Serving (and Eventing,
   if ever wanted), so upgrades are a single CR field bump rather than
   re-applying multiple charts.

2. **Apply a `KnativeServing` CR** in `knative-serving` that turns on Kourier:
   ```yaml
   apiVersion: operator.knative.dev/v1beta1
   kind: KnativeServing
   metadata:
     name: knative-serving
     namespace: knative-serving
   spec:
     ingress:
       kourier:
         enabled: true
     config:
       network:
         ingress-class: kourier.ingress.networking.knative.dev
   ```
   The Operator reconciles this into Serving + Kourier pods.

3. **Verify with hello-world:**
   ```sh
   kubectl apply -f - <<EOF
   apiVersion: serving.knative.dev/v1
   kind: Service
   metadata:
     name: hello
     namespace: default
   spec:
     template:
       spec:
         containers:
           - image: gcr.io/knative-samples/helloworld-go
             env:
               - name: TARGET
                 value: "homelab"
   EOF
   kubectl get ksvc hello   # should print a URL
   curl <url>               # 1-5s cold start, then fast; wait 60s, repeat
   ```

4. **Expose Kourier.** Either route through the existing Tailscale ingress
   class (same pattern as ArgoCD/MLflow → `*.<tailnet>.ts.net`), or give
   Kourier its own Tailscale Ingress so Knative-managed services live under
   a `*.knative.<tailnet>.ts.net` suffix. Knative supports a "magic DNS"
   suffix via the `config-domain` ConfigMap.

5. **Flip kserve to Serverless mode** (or leave it as the default if the chart
   already ships that way) and deploy an `InferenceService`. Confirm pods exit
   ~60s after the last prediction.

## Knative fit in the existing patterns

- **Deploy via ArgoCD**: `gitops/manifests/knative/` + `gitops/argocd/knative.yaml`.
  Knative Operator chart.
- **CRDs**: managed by the Operator, no separate CRD chart needed.
- **Ingress**: Kourier internal; expose via Tailscale ingress, same pattern as
  ArgoCD/MLflow.
- **Secrets**: none required for Serving itself.
- **Sync order**: kserve depends on Knative CRDs + controller being healthy.
  Use ArgoCD sync-waves (annotation `argocd.argoproj.io/sync-wave: "-1"` on
  the Knative Application, default `"0"` on kserve) so Knative reconciles
  first.

## Tuning knobs (per-workload, not cluster-wide)

Annotations on a Knative `Service`:

- `autoscaling.knative.dev/min-scale: "1"` — pin at least one pod (kills
  scale-to-zero for this service). Use for latency-sensitive things.
- `autoscaling.knative.dev/max-scale: "10"` — cap. Default unbounded.
- `autoscaling.knative.dev/scale-to-zero-grace-period: "5m"` — how long idle
  pods stick around. Default ~60s. Bump for things with slow cold starts.
- `autoscaling.knative.dev/target: "100"` — concurrent requests per pod
  before scaling out. Lower = more pods, less queuing.

## Gotchas

- **Cold start is real.** First request after idle waits for container start +
  app readiness (image is already cached on the node after first pull). Plan
  for 1–5s on small images, 30s+ on multi-GB ML images. Either accept it,
  pin `min-scale: 1`, or use a warmer.
- **Activator hop only matters during cold start / rapid scale.** Stable
  revisions get direct routing, so the activator isn't on the hot path for
  busy services. Worth knowing when debugging latency.
- **Don't enable Eventing unless something actually needs it.** Adds another
  4–5 pods (broker, dispatcher, sources controller) that mostly sit idle.
  Serving alone is the 80% use case.
- **Two ingresses (Kourier + ingress-nginx) means two Services to keep
  straight.** Document which hostnames go where. Tailscale ingress class
  abstracts most of this away.
- **kserve's `deploymentMode` is set at chart-install time *and* overridable
  per InferenceService.** If the chart default is `Serverless` but Knative
  isn't installed yet, every InferenceService will sit pending. Either set
  the chart default to `RawDeployment` until Knative is ready, or sync
  Knative first via sync-waves.
- **Operator vs standalone install.** The Operator manages component
  versions and config; standalone charts (`serving-crds`, `serving-core`,
  `net-kourier`) give finer control but more moving parts. Start with the
  Operator; drop down only if a specific override isn't exposed.
- **Knative `Service` ≠ core `Service`.** Confusingly named CRD. Address it
  as `ksvc` (`kubectl get ksvc`) to avoid mixing them up.
