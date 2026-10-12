COMPOSE ?= docker compose
IMAGE   ?= ghcr.io/shadyhippo/codecontainer:latest

.PHONY: help init preflight secrets build up down restart logs shell preview notes \
        egress-apply egress-remove egress-status scratch-sweep size pull push clean

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

# compose.yaml is gitignored; create it from the committed example ONLY if it is
# missing. It deliberately has no prerequisites, so pulling a newer example can
# never overwrite your edited config.
compose.yaml:
	@test -f compose.yaml || { \
		cp compose.example.yaml compose.yaml; \
		echo "created compose.yaml from the example"; \
		echo "  -> EDIT ME: /mnt/user/Projects, PUBLIC_HOST, GH_TOKEN"; \
	}

secrets: ## create the (read-only mounted) secrets dir
	@mkdir -p secrets && chmod 700 secrets
	@echo "secrets/ ready -> mounted read-only at /secrets"

init: compose.yaml secrets ## create compose.yaml + secrets dir

build: compose.yaml ## build the image
	$(COMPOSE) build

up: compose.yaml secrets ## start the container
	$(COMPOSE) up -d --build
	@echo "now run:  make egress-apply   (to block SSH egress from the container)"

down: ## stop the container
	$(COMPOSE) down

restart: ## restart the container
	$(COMPOSE) restart

logs: ## follow logs
	$(COMPOSE) logs -f --tail=100

shell: ## open a shell in the running container
	$(COMPOSE) exec code bash

preview: ## list dev servers currently exposed
	$(COMPOSE) exec code preview

notes: ## print the house rules for agents
	$(COMPOSE) exec code agent-notes

preflight: ## check host paths, ports and bind IP before deploying
	./scripts/preflight.sh

egress-apply: ## block container -> LAN/host on tcp/22,2222 (run as root)
	./scripts/no-ssh-egress.sh apply

egress-remove: ## undo the SSH egress block
	./scripts/no-ssh-egress.sh remove

egress-status: ## show whether SSH egress is blocked
	./scripts/no-ssh-egress.sh status

scratch-sweep: ## clear the scratch dir (only when the container is stopped)
	SCRATCH_DIR=$(SCRATCH_DIR) ./scripts/scratch-sweep.sh

size: ## report image size
	@docker image inspect $(IMAGE) --format '{{.Size}} bytes total'

pull: ## pull the prebuilt image
	docker pull $(IMAGE)

push: ## push the image
	docker push $(IMAGE)

clean: ## remove local image
	docker rmi $(IMAGE) || true
