# Sourced by the fake claude of the S06 runs (loop-s06-main.sh, loop-s06-review.test.sh): rej <resetsAt> prints the rejected
# five-hour rate_limit_event line; the session id is sid-$key, $key being the fake claude's own.
rej() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}},"session_id":"sid-%s"}\n' "$1" "$1" "$key"; }
