## llama-backend

This kustomization deploys:

- `llama-static-a`: pinned llama.cpp model on node label `ai.llm.role=static-a`
- `llama-static-b`: pinned llama.cpp model on node label `ai.llm.role=static-b`
- `llama-swap`: dynamic model runner on node label `ai.llm.role=swap`
- `llm-gateway` (LiteLLM): shared OpenAI-compatible routing endpoint for LibreChat

Model defaults are defined in:

- `llama-static-a-configmap.yaml`
- `llama-static-b-configmap.yaml`
- `llama-swap-configmap.yaml`
- `litellm-configmap.yaml` (single example model mapping by default)

Shared secret dependency:

- `vllm-shared-secret` must exist and include `HUGGING_FACE_HUB_TOKEN`.
  This kustomization manages it via `externalsecret.yaml`.

Model storage:

- All workers share one RWX claim `llama-models-cache` for modular model pinning/switching.
- Ensure your cluster has an RWX StorageClass named `ceph-filesystem`, or update
  `pvc-llama-models-cache.yaml` accordingly.
