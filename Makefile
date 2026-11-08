# noodlebot: the n00dl3b0t automation for tuckermclean's repos.
test:
	sh scheduler/ready.test.sh
	sh scheduler/release-markers.test.sh
	sh scheduler/report.test.sh
	sh scheduler/issues.test.sh
	sh plugin/skills/node/check-regime.test.sh
	sh scheduler/deploy.test.sh
	bash scheduler/loop.test.sh

.PHONY: test
