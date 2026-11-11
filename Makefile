# noodlebot: the n00dl3b0t automation for tuckermclean's repos.
TESTS = \
	scheduler/ready.test.sh \
	scheduler/version.test.sh \
	scheduler/release-markers.test.sh \
	scheduler/report.test.sh \
	scheduler/issues.test.sh \
	scheduler/labels.test.sh \
	scheduler/usage.test.sh \
	scheduler/turn.test.sh \
	scheduler/turn-gap.test.sh \
	scheduler/turn-race.test.sh \
	scheduler/turn-record.test.sh \
	scheduler/turn-lock.test.sh \
	plugin/skills/node/check-regime.test.sh \
	scheduler/deploy.test.sh \
	plugin/hooks/guard.test.sh \
	plugin/hooks/guard-git.test.sh \
	plugin/hooks/guard-shell.test.sh \
	scheduler/loop.test.sh \
	scheduler/loops.test.sh \
	scheduler/loops-root.test.sh \
	scheduler/loops-status.test.sh \
	scheduler/loops-api.test.sh \
	scheduler/api.test.sh \
	scheduler/api-sessions.test.sh \
	scheduler/api-events.test.sh \
	scheduler/api-fifo.test.sh \
	scheduler/api-root2.test.sh \
	scheduler/move-runtime.test.sh \
	plugin/skills/adopt/adopt.test.sh \
	plugin/skills/triage/nodes.test.sh \
	scheduler/site.test.sh \
	scheduler/runtests.test.sh

test:
	sh scheduler/runtests.sh $(TESTS)

.PHONY: test
