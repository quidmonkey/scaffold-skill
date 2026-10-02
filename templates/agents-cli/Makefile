# Repo governance targets, added by the scaffold skill. Agent development,
# eval and deploy commands come from agents-cli (`agents-cli --help`).

.PHONY: help setup run-check review ship ship-plan ship-stage ship-status ship-watch ship-stop auto-pr

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

setup: ## One-time post-clone setup (uv sync, pre-commit, asks how far make ship goes)
	uv sync
	uv run pre-commit install
	bash scripts/set-ship-stage.sh --prompt

run-check: ## Confirm the agent still imports cleanly (also runs on git push)
	uv run python -c "import {{code-dir}}.agent"

review: ## Run the two-pass agentic code review (also runs on git push)
	bash scripts/code-review.sh

ship: ## Review, push and ship the branch into develop from a worktree (BRANCH= STAGE= SET= NOTES= DETACH=1 YES=1)
	@bash scripts/ship.sh $(ship_args) $(call ship_flag,DETACH,--detach) $(call ship_flag,YES,--yes) \
		$(call ship_arg,ID,--id "$$ID") $(call ship_arg,SHA,--expect-sha "$$SHA") $(call ship_arg,CONFIG,--expect-config "$$CONFIG")

ship-plan: ## Show the config make ship would use and check it; creates nothing (BRANCH= STAGE= SET= NOTES=)
	@bash scripts/ship.sh --plan $(ship_args)

ship-stage: ## Set how far make ship goes: STAGE=push|open_pr|merge|verify_deploy
	@bash scripts/set-ship-stage.sh "$(STAGE)"

ship-status: ## Show running and recent ships (ID= for one)
	@bash scripts/ship.sh --status $(ID)

ship-watch: ## Print a ship's events as they happen until it finishes (ID=, default latest)
	@bash scripts/ship.sh --watch $(ID)

ship-stop: ## Stop a running ship (ID= when more than one is running)
	@bash scripts/ship.sh --stop $(ID)

auto-pr: ## Alias for make ship-stage STAGE=merge
	@bash scripts/set-ship-stage.sh merge

# make ship arguments are taken from the command line only, so a stray
# environment variable (YES, ID, SHA...) can't change a ship. The shell reads
# $SET and $STAGE itself, so values with spaces survive:
#   make ship SET='deploy_name=Sales Agent (dev);review_model=sonnet'
ship_arg = $(if $(filter command line,$(origin $(1))),$(2))
ship_flag = $(if $(filter command line,$(origin $(1))),$(if $(filter 1 true yes,$($(1))),$(2)))
ship_args = $(call ship_arg,BRANCH,--target "$$BRANCH") $(call ship_arg,NOTES,--notes-file "$$NOTES") \
	$(call ship_arg,STAGE,--stage "$$STAGE") $(call ship_arg,SET,--sets "$$SET")
