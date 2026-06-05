set shell := ["bash", "-cu"]

# liste les recettes
default:
    @just --list

# format : prettier (yaml/md/json) + terraform fmt
fmt:
    npx --yes prettier --write "**/*.{yaml,yml,md,json}"
    terraform -chdir=terraform fmt

# format check (ce que vérifierait la CI)
fmt-check:
    npx --yes prettier --check "**/*.{yaml,yml,md,json}"
    terraform -chdir=terraform fmt -check

# validation des manifests k8s + terraform (nécessite kubeconform, terraform)
validate:
    terraform -chdir=terraform validate || true
    find k8s -name '*.yaml' -print0 | xargs -0 -I{} sh -c 'kubeconform -strict -summary "{}" || true'

# lint terraform (nécessite tflint)
tf-lint:
    cd terraform && tflint || true
