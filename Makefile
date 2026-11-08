# noodlebot: the n00dl3b0t automation for tuckermclean's repos.
test:
	sh scheduler/ready.test.sh
	sh scheduler/release-markers.test.sh
	sh scheduler/report.test.sh
	bash scheduler/loop.test.sh

.PHONY: test
