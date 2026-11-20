.PHONY: dev test format analyze generate docker

# Start MongoDB for local development and tests.
dev:
	docker compose -f docker-compose.dev.yml up -d mongo

test:
	cd unpub && dart test

format:
	cd unpub && dart format .

analyze:
	cd unpub && dart analyze

# Regenerate *.g.dart after changing the JSON models.
generate:
	cd unpub && dart run build_runner build --delete-conflicting-outputs

docker:
	docker build -t unpub .
