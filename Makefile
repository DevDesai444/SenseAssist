SHELL := /bin/bash

.DEFAULT_GOAL := help

DB_PATH ?= $(HOME)/.senseassist/senseassist.sqlite
SQLITE3 ?= sqlite3

.PHONY: help status git-summary test helper-health llm-install llm-smoke sync-all-demo sync-all-live db-summary

help:
	@echo "SenseAssist commands"
	@echo "  make status         Run full local verification suite"
	@echo "  make test           Run Swift tests"
	@echo "  make helper-health  Run helper health check"
	@echo "  make llm-install    Install Phi-3.5-mini-instruct-onnx on-device model + env file"
	@echo "  make llm-smoke      Run on-device ONNX LLM smoke check"
	@echo "  make sync-all-demo  Run multi-account sync demo"
	@echo "  make sync-all-live  Run live multi-account sync (requires OAuth tokens + local ONNX Runtime GenAI model)"
	@echo "  make db-summary     Print key DB summary tables"

status: git-summary test helper-health sync-all-demo db-summary
	@echo ""
	@echo "Status checks complete."

git-summary:
	@echo "== Git summary =="
	@git status --short --branch
	@git log --oneline -n 8
	@echo ""

test:
	@echo "== swift test =="
	swift test
	@echo ""

helper-health:
	@echo "== helper health check =="
	swift run senseassist-helper --health-check
	@echo ""

llm-install:
	@echo "== install Phi-3.5-mini-instruct-onnx =="
	bash Scripts/install_phi35_instruct_onnx.sh
	@echo ""

llm-smoke:
	@echo "== on-device LLM smoke check =="
	bash Scripts/smoke_test_phi35_instruct_onnx.sh
	@echo ""

sync-all-demo:
	@echo "== multi-account sync demo =="
	SENSEASSIST_ENABLE_DEMO_COMMANDS=1 swift run senseassist-helper --sync-all-demo
	@echo ""

sync-all-live:
	@echo "== multi-account sync live =="
	swift run senseassist-helper --sync-live-once
	@echo ""

db-summary:
	@echo "== database summary =="
	@if [[ ! -f "$(DB_PATH)" ]]; then \
		echo "Database not found at $(DB_PATH)"; \
		exit 0; \
	fi
	@if ! command -v "$(SQLITE3)" >/dev/null 2>&1; then \
		echo "sqlite3 not found in PATH"; \
		exit 0; \
	fi
	@$(SQLITE3) "$(DB_PATH)" "SELECT provider, email, is_enabled FROM accounts ORDER BY provider, email;"
	@echo ""
	@$(SQLITE3) "$(DB_PATH)" "SELECT provider, account_id, cursor_primary FROM provider_cursors ORDER BY provider, account_id;"
	@echo ""
	@$(SQLITE3) "$(DB_PATH)" "SELECT source, account_id, COUNT(*) FROM updates GROUP BY source, account_id ORDER BY source, account_id;"
	@echo ""
	@$(SQLITE3) "$(DB_PATH)" "SELECT COUNT(*) AS tasks FROM tasks;"
	@echo ""
