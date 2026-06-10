# frozen_string_literal: true

# Story 4.4 — disable Client's live at_exit handler registration for the whole
# unit-test process. Building a Client through the real factory in a spec would
# otherwise register a PID-guarded at_exit handler that fires #flush during
# RSpec suite teardown (the guard PASSES — the RSpec process IS the registering
# process), attempting a WebMock-blocked network POST at exit.
#
# The handler BODY is unit-tested directly via Client#run_at_exit_flush (no
# global side effect), and the live-registration path is proven end-to-end in a
# SUBPROCESS in spec/integration/fork_safety_spec.rb — so disabling the live
# registration here costs no coverage of the real behaviour.
#
# This is a TEST-HARNESS concern only and is deliberately kept OUT of
# spec_helper.rb (the single-source coverage-gate file must not be touched).
ConvertSdk.at_exit_registration_enabled = false
