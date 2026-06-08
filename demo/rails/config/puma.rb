# frozen_string_literal: true

# =============================================================================
# Puma CLUSTER config — THE production deployment shape (teaching material).
# =============================================================================
#
# `workers 2` + `preload_app!` is the standard Rails production cluster: the app
# (including config/initializers/convert_sdk.rb, which builds the singleton
# CONVERT_SDK client) is loaded ONCE in the master, then the master FORKS worker
# processes that inherit that already-built client.
#
# This is the EXACT shape that silently loses events in fork-unsafe SDKs: a client
# built before fork carries background-thread / buffer state that does not survive
# `fork(2)`, so forked workers deliver nothing. The Convert SDK's automatic
# `Process._fork` hook re-arms each worker on first use — which is why there is
# ZERO fork-handling code below (no `on_worker_boot { CONVERT_SDK.postfork }`).
# The fork-safety smoke (script/fork_smoke.rb) proves events arrive from BOTH
# forked workers with this file exactly as written.

# Two workers — enough to prove fork delivery from MORE THAN ONE forked process.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 2))

# Preload the app in the master before forking (the whole point — see above).
preload_app!

port Integer(ENV.fetch("PORT", 3000))
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 3000)}"
environment ENV.fetch("RAILS_ENV", "production")

# A single thread per worker keeps the smoke's PID attribution unambiguous (each
# request is served by exactly one worker process). Production apps would raise
# this; it does not affect fork safety.
threads Integer(ENV.fetch("RAILS_MIN_THREADS", 1)), Integer(ENV.fetch("RAILS_MAX_THREADS", 1))

# DELIBERATELY ABSENT: `on_worker_boot { CONVERT_SDK.postfork }`.
# The SDK's automatic fork detection makes it unnecessary. Adding it would
# undermine the flagship zero-config-fork-safety claim this demo exists to prove.
