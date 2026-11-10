# noodlebot: the n00dl3b0t automation for tuckermclean's repos.
test:
	sh scheduler/ready.test.sh
	sh scheduler/version.test.sh
	sh scheduler/release-markers.test.sh
	sh scheduler/report.test.sh
	sh scheduler/issues.test.sh
	sh scheduler/labels.test.sh
	sh scheduler/usage.test.sh
	sh plugin/skills/node/check-regime.test.sh
	sh scheduler/deploy.test.sh
	sh plugin/hooks/guard.test.sh
	bash scheduler/loop.test.sh
	sh scheduler/loops.test.sh
	sh scheduler/move-runtime.test.sh
	sh plugin/skills/adopt/adopt.test.sh
	sh plugin/skills/triage/nodes.test.sh

.PHONY: test
