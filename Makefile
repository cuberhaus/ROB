.PHONY: help dev build docker-up docker-down docker-rebuild data

help:
	@echo "Available commands:"
	@echo "  help           – Show this help message"
	@echo "  dev            – Start dev server on port 8092"
	@echo "  build          – Production build to web/dist/"
	@echo "  data           – Convert .mat files to JSON"
	@echo "  docker-up      – Build & start container"
	@echo "  docker-down    – Stop container"
	@echo "  docker-rebuild – Full rebuild (no-cache)"

dev:
	cd web && npx vite --port 8092

build:
	cd web && npx vite build

data:
	python3 scripts/mat2json.py

docker-up:
	docker compose up -d --build

docker-down:
	docker compose down

docker-rebuild:
	docker compose down && docker compose build --no-cache && docker compose up -d

##@ Understand (knowledge graph)

.PHONY: understand-dashboard
understand-dashboard: ## Launch the Understand Anything knowledge-graph dashboard (graph dir = repo root)
	@node -e "require(require('os').homedir()+'/.understand-anything/repo/understand-anything-plugin/packages/dashboard/launch.cjs')"
