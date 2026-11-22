.PHONY: up down build test lint clean backup restore

# ─── Docker Commands ────────────────────────────────────────────────
up:
	docker-compose up -d
	@echo "ATHENA running at http://localhost:8000"
	@echo "API Docs at http://localhost:8000/api/docs"

down:
	docker-compose down

build:
	docker-compose build --no-cache

restart:
	docker-compose down && docker-compose up -d

# ─── Testing ────────────────────────────────────────────────────────
test:
	pytest tests/ -v --cov=athena_api --cov=tasks --cov-report=term-missing

test-docker:
	docker-compose exec api pytest tests/ -v

# ─── Code Quality ───────────────────────────────────────────────────
lint:
	flake8 athena_api.py tasks.py --max-line-length=120
	black --check athena_api.py tasks.py

format:
	black athena_api.py tasks.py

# ─── Database ───────────────────────────────────────────────────────
backup:
	docker-compose exec postgres pg_dump -U athena athena > backups/athena_$(shell date +%Y%m%d_%H%M%S).sql
	@echo "Backup complete"

restore:
	@read -p "Enter backup file path: " backup_file; \
	docker-compose exec -T postgres psql -U athena athena < $$backup_file
	@echo "Restore complete"

# ─── Utilities ──────────────────────────────────────────────────────
logs:
	docker-compose logs -f

shell-api:
	docker-compose exec api bash

shell-db:
	docker-compose exec postgres psql -U athena athena

clean:
	docker-compose down -v
	rm -rf backups/*
	@echo "All containers and volumes removed"