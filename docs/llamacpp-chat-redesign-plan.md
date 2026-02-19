# llama.cpp Chat Backend Redesign Plan

## Purpose
Replace the current vLLM-backed chat stack with a llama.cpp-backed stack while keeping the existing frontend (`LibreChat`) and router (`LiteLLM`) contract stable.

This document is written as an implementation runbook for someone unfamiliar with this repository.

## Current State (Before Change)
- Frontend: `LibreChat` in `cluster/apps/ai/librechat/`
- Gateway/router: `LiteLLM` (`llm-gateway`) in `cluster/apps/ai/vllm-general/`
- Backend workers: vLLM deployments (`vllm-general`, `vllm-code`, `vllm-reasoning`)
- Frontend calls: `http://llm-gateway.ai.svc.cluster.local:4000/v1`

## Target State (After Change)
- Keep `LibreChat` endpoint and `LiteLLM` gateway.
- Replace vLLM workers with 3 llama.cpp-backed services:
1. `llama-static-a` (pinned model, dedicated GPU node)
2. `llama-static-b` (pinned model, dedicated GPU node)
3. `llama-swap` (dynamic multi-model pool, dedicated GPU node)
- Expose transparent model names to users (example: `GLM-4.7-Flash`), not role aliases (`general-chat`, etc.).
- Two model names map to static instances; all other model names map to `llama-swap`.

## Non-Negotiable Constraints
- Cluster has 3 GPU nodes; each llama backend instance is pinned to one node.
- Each backend pod consumes one full GPU (`amd.com/gpu: "1"`).
- User-facing model names must remain human-readable and directly selectable.

## High-Level Architecture

### Request Path
1. User selects model in LibreChat.
2. LibreChat sends OpenAI-compatible request to LiteLLM (`/v1/chat/completions`).
3. LiteLLM routes by `model` name:
- static model name A -> `llama-static-a` service
- static model name B -> `llama-static-b` service
- all other declared models -> `llama-swap` service
4. Backend returns response through LiteLLM to LibreChat.

### Why This Design
- Keeps frontend/gateway mostly unchanged.
- Enables stable pinned workloads + flexible dynamic pool.
- Uses GGUF formats that are widely available and operationally simpler on this hardware path.

## Repository Changes

## New Directory
Create:
- `cluster/apps/ai/llama-backend/`

Recommended files:
- `kustomization.yaml`
- `externalsecret.yaml` (if reusing HF tokens from Vault secret sync)
- `llama-static-a-configmap.yaml`
- `llama-static-a-deployment.yaml`
- `llama-static-a-service.yaml`
- `llama-static-b-configmap.yaml`
- `llama-static-b-deployment.yaml`
- `llama-static-b-service.yaml`
- `llama-swap-configmap.yaml`
- `llama-swap-deployment.yaml`
- `llama-swap-service.yaml`
- `pvc-llama-static-a-cache.yaml`
- `pvc-llama-static-b-cache.yaml`
- `pvc-llama-swap-cache.yaml`

## Existing Files to Modify
- `cluster/apps/ai/vllm-general/litellm-configmap.yaml`
- `cluster/apps/ai/librechat/librechat-yaml-configmap.yaml`
- `cluster/apps/ai/librechat/configmap.yaml` (if model metadata handling needs tweaks)
- Top-level kustomization path(s) that include AI apps

## Node Placement and Scheduling

## Node Labels (required)
Label one GPU node per role:
- `ai.llm.role=static-a`
- `ai.llm.role=static-b`
- `ai.llm.role=swap`

Each deployment must use required node affinity for its assigned label.

## Resource Shape (per deployment)
- `requests/limits`:
- `amd.com/gpu: "1"`
- CPU and RAM sized for chosen model quant
- Add `terminationGracePeriodSeconds` >= 60
- Add readiness/liveness/startup probes tuned for model load times

## Model Provisioning Strategy

## Static deployments
Use init container to download selected GGUF and create deterministic symlink:
- `/models/weights/model.gguf`

Inputs (configmap/env):
- repo id
- quant filter string (example: `Q4_K_M`)
- optional filename override

## llama-swap deployment
- Maintain model catalog in configmap (logical name -> GGUF path/source).
- Use persistent cache for downloaded model files.
- Configure swap behavior (LRU/TTL/concurrency) conservatively at first.

## API Compatibility
- All three backends must expose OpenAI-compatible chat route expected by LiteLLM.
- Service DNS names should be stable:
- `llama-static-a.ai.svc.cluster.local`
- `llama-static-b.ai.svc.cluster.local`
- `llama-swap.ai.svc.cluster.local`

## Model Naming Policy
- Names shown to users are the same names LiteLLM routes on.
- Example shape:
- Static: `GLM-4.7-Flash`, `Qwen3-Coder-30B-A3B`
- Swap-backed: `DeepSeek-R1-Distill`, `Llama-3.1-70B-Instruct`, etc.
- Do not present role aliases in UI.

## LiteLLM Changes
Update `model_list` in `cluster/apps/ai/vllm-general/litellm-configmap.yaml`:
- Remove or deprecate vLLM backend entries.
- Add one entry per user-facing model name:
- `api_base` -> static-a/static-b/swap service
- `model` string -> same user-visible name
- Keep master key and auth behavior unchanged.

## LibreChat Changes
Update `cluster/apps/ai/librechat/librechat-yaml-configmap.yaml`:
- Keep `baseURL` pointing at LiteLLM gateway.
- Set `models.default` and model lists to transparent names.
- Keep `fetch: false` unless dynamic model enumeration is intentionally enabled.

## Migration Plan (Execution Order)
1. Deploy llama backend stack in parallel (no traffic cutover).
2. Validate each backend service directly from cluster:
- `/v1/models`
- `/v1/chat/completions` with short prompt
3. Add temporary LiteLLM test model mappings (suffix `-test`) to new backends.
4. Validate end-to-end through LiteLLM with `-test` models.
5. Update LiteLLM production model mappings to llama backends.
6. Update LibreChat model list to transparent final names.
7. Monitor latency/error rates and GPU memory for 24h.
8. Remove vLLM deployments only after acceptance window passes.

## Validation Checklist

## Backend checks
- Pods scheduled to intended nodes (`ai.llm.role=*`)
- GPU allocated exactly one per pod
- Models load without repeated restart loops
- `/health` and `/v1/models` succeed

## Router checks
- LiteLLM `/v1/models` returns transparent names
- One completion per mapped model returns 200

## Frontend checks
- Model picker shows transparent names
- Conversation works on both static models and at least one swap-backed model

## Rollback Plan
- Keep old vLLM manifests and LiteLLM route config in git until cutover is proven.
- Rollback procedure:
1. Restore previous `litellm-configmap.yaml` mappings to vLLM services.
2. `kubectl apply -k ...` and rollout `llm-gateway`.
3. Optionally revert LibreChat model list config.
- No DNS/endpoint rollback needed because gateway URL remains unchanged.

## Operational Notes
- Pin container images by digest where possible after first stable run.
- Do not run nightly tags in steady state.
- Keep separate PVCs per backend to avoid cache contention and simplify cleanup.
- Record chosen model repos/quants in configmaps, not only in deployment args.
- Add a smoke-test job for future changes:
- test `/v1/models`
- test one completion on each exposed model name

## Required Inputs Before Implementation
1. Two pinned static model choices:
- `MODEL_STATIC_A_NAME`, `MODEL_STATIC_A_REPO`, `MODEL_STATIC_A_QUANT`
- `MODEL_STATIC_B_NAME`, `MODEL_STATIC_B_REPO`, `MODEL_STATIC_B_QUANT`
2. Initial swap-backed model list (name/repo/quant triples)
3. Node mapping:
- which host is `static-a`, `static-b`, `swap`
4. Default runtime knobs:
- context size (`n_ctx`)
- max tokens
- batch size
- thread count
- GPU offload layers

## Definition of Done
- LibreChat serves transparent model names through existing gateway endpoint.
- Two static models and one swap pool are live on separate GPU nodes.
- End-to-end chat succeeds for all exposed model names.
- Rollback path is tested once and documented in commit notes.
