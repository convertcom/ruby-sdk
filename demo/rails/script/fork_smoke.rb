#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# Puma-cluster fork-safety smoke test — THE release-blocking fork proof (NFR11).
# =============================================================================
#
# This script IS the test (there is no RSpec here — the demo is an app, not lib).
# It proves the SDK's flagship claim end-to-end under a REAL Puma cluster:
#
#   Events tracked from BOTH forked Puma workers arrive at the track endpoint,
#   with ZERO fork-handling code anywhere in the demo app.
#
# ── How it works (deterministic + offline) ───────────────────────────────────
#  1. Start a local STUB server (pure-stdlib TCPServer — no WEBrick/Rack dep, so
#     the smoke runs anywhere the SDK does) that:
#       * GET  /config/{key}        -> serves the canned config (test-config.json)
#       * POST .../track/{key}      -> records the tracked payload's visitor ids
#  2. Boot the demo under Puma cluster (workers 2 + preload_app!), with the SDK's
#     config_endpoint + track_endpoint pointed at the stub (Story 2.4 options),
#     timers OFF (each /demo request flushes synchronously — deterministic).
#  3. Discover worker PIDs via GET /pid; drive GET /demo requests with a visitor
#     id of the form `smoke-test-{pid}-{n}` (the PID of the Ruby process that
#     served /pid). Keep going until at least 2 DISTINCT PIDs have served.
#  4. ASSERT: the stub recorded tracked events whose visitor ids embed >= 2
#     DISTINCT PIDs. That proves BOTH forked workers delivered — with no fork code.
#
# Every wait (worker boot, request, event arrival) is bounded by a timeout; on
# any failure the script prints CI-friendly diagnostics and exits NONZERO.
#
# The fork MECHANISM (stub + SDK + Process.fork + visitor-ID-embeds-PID + the
# >=2-distinct-PID assertion) is independently exercisable without Puma — see the
# README. Under CI this script boots the REAL Puma cluster so the proof holds for
# the actual production deployment shape.
#
# Run locally:  cd demo/rails && bundle exec ruby script/fork_smoke.rb
# Run in CI:    .github/workflows/demo-smoke.yml (a required check).

require "net/http"
require "json"
require "uri"
require "socket"
require "timeout"

# --- Tunables (env-overridable so CI can widen timeouts on slow runners) -----
BOOT_TIMEOUT       = Float(ENV.fetch("SMOKE_BOOT_TIMEOUT", "60"))   # Puma boot
DRIVE_TIMEOUT      = Float(ENV.fetch("SMOKE_DRIVE_TIMEOUT", "60"))  # hitting both workers
REQUEST_TIMEOUT    = Float(ENV.fetch("SMOKE_REQUEST_TIMEOUT", "10")) # per HTTP call
EVENT_TIMEOUT      = Float(ENV.fetch("SMOKE_EVENT_TIMEOUT", "10"))  # event arrival at stub
DISTINCT_PID_GOAL  = Integer(ENV.fetch("SMOKE_DISTINCT_PIDS", "2")) # workers to prove
MAX_DRIVE_REQUESTS = Integer(ENV.fetch("SMOKE_MAX_REQUESTS", "200")) # hard cap
CANNED_CONFIG_PATH = ENV.fetch(
  "SMOKE_CONFIG_PATH",
  File.expand_path("../../../spec/fixtures/test-config.json", __dir__)
)

def log(msg) = warn("[fork-smoke] #{msg}")

# Pick a free TCP port by binding to :0 and reading the assigned port.
def free_port
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  server.close
  port
end

# Block until the block returns truthy or the deadline passes (bounded wait — no
# sleep-and-hope). Returns the last value (truthy on success, falsey on timeout).
def wait_until(timeout:, interval: 0.1)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  result = yield
  until result || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep(interval)
    result = yield
  end
  result
end

# =============================================================================
# The stub server: pure-stdlib TCPServer. Serves the canned config on GET
# /config/* and records the tracked visitor ids on POST .../track/*. Thread-safe.
# =============================================================================
class StubServer
  attr_reader :port

  def initialize(config_body)
    @config_body = config_body
    @mutex = Mutex.new
    @tracked_visitor_ids = [] #: Array[String]
    @running = false
    @server = nil
    @thread = nil
    @port = nil
  end

  # The visitor ids seen across ALL recorded track POSTs (thread-safe snapshot).
  def tracked_visitor_ids
    @mutex.synchronize { @tracked_visitor_ids.dup }
  end

  def start
    @port = free_port
    @server = TCPServer.new("127.0.0.1", @port)
    @running = true
    @thread = Thread.new { accept_loop }
    self
  end

  def shutdown
    @running = false
    @server&.close
    @thread&.join(5)
  rescue IOError
    nil
  end

  private

  def accept_loop
    while @running
      conn =
        begin
          @server.accept
        rescue IOError, Errno::EBADF
          break
        end
      Thread.new(conn) { |c| handle(c) }
    end
  end

  # Minimal HTTP/1.1 request handler: read the request line + headers, read the
  # body by Content-Length, route on method+path, reply, close.
  def handle(conn)
    method, path = parse_request_line(conn)
    headers = parse_headers(conn)
    body = read_body(conn, headers)
    respond(conn, route(method, path, body))
  rescue StandardError => e
    log("WARN: stub handler error: #{e.class}: #{e.message}")
  ensure
    begin
      conn.close
    rescue IOError
      nil
    end
  end

  def parse_request_line(conn)
    line = conn.gets.to_s
    method, path, = line.split(" ")
    [method, path]
  end

  def parse_headers(conn)
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase.strip] = value.to_s.strip if value
    end
    headers
  end

  def read_body(conn, headers)
    len = headers["content-length"]
    len ? conn.read(len.to_i).to_s : ""
  end

  # Returns the response body string. Records visitor ids on a track POST.
  def route(method, path, body)
    if method == "POST" && path.include?("/track/")
      record_track(body)
      JSON.generate({ success: true })
    elsif method == "GET" && path.include?("/config/")
      @config_body
    else
      "{}"
    end
  end

  def record_track(body)
    parsed = JSON.parse(body)
    ids = Array(parsed["visitors"]).map { |v| v["visitorId"] }.compact
    @mutex.synchronize { @tracked_visitor_ids.concat(ids) }
  rescue JSON::ParserError => e
    log("WARN: unparseable track body: #{e.message}")
  end

  def respond(conn, body)
    conn.print(
      "HTTP/1.1 200 OK\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n\r\n#{body}"
    )
  end
end

# =============================================================================
# Driving the demo under Puma cluster.
# =============================================================================

# GET a path on the demo, returning the parsed JSON body (or nil on failure).
# Sends `Accept: application/json` so /demo (which content-negotiates HTML by
# default for humans) returns its JSON shape to the smoke — the smoke is a
# machine client, not a browser.
def get_json(base, path)
  uri = URI.join(base, path)
  res = Timeout.timeout(REQUEST_TIMEOUT) do
    Net::HTTP.get_response(uri, { "Accept" => "application/json" })
  end
  return nil unless res.is_a?(Net::HTTPSuccess)

  JSON.parse(res.body)
rescue StandardError => e
  log("WARN: GET #{path} failed: #{e.class}: #{e.message}")
  nil
end

# Boot Puma cluster as a child PROCESS GROUP with the stub-pointed env. The group
# lets us TERM/KILL the whole cluster (master + workers) on teardown.
def boot_puma(demo_dir:, port:, stub_base:)
  env = {
    "PORT" => port.to_s,
    "RAILS_ENV" => "production",
    "WEB_CONCURRENCY" => DISTINCT_PID_GOAL.to_s,
    "CONVERT_DEMO_TIMERS_OFF" => "1",
    "CONVERT_DEMO_DISABLE_HOST_CHECK" => "1",
    "CONVERT_SDK_KEY" => "smoke-sdk-key",
    # Point config + track at the stub (Story 2.4 endpoint options). The track
    # endpoint carries the [project_id] template the SDK substitutes.
    "CONVERT_CONFIG_ENDPOINT" => stub_base.chomp("/"),
    "CONVERT_TRACK_ENDPOINT" => "#{stub_base.chomp('/')}/[project_id]/v1"
  }
  spawn(env, "bundle", "exec", "puma", "-C", "config/puma.rb",
        chdir: demo_dir, pgroup: true)
end

# Kill the whole Puma process group (master + forked workers).
def kill_puma(pid)
  Process.kill("TERM", -Process.getpgid(pid))
  wait_until(timeout: 10) { !process_alive?(pid) }
  Process.kill("KILL", -Process.getpgid(pid)) if process_alive?(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil # already gone
ensure
  begin
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

# Drive /pid + /demo requests until >= DISTINCT_PID_GOAL distinct worker PIDs have
# served. Each request embeds the serving PID in the visitor id. Returns the
# array of serving PIDs observed.
def drive_until_two_workers(demo_base)
  seen_pids = []
  counter = 0
  wait_until(timeout: DRIVE_TIMEOUT, interval: 0.0) do
    next true if seen_pids.uniq.size >= DISTINCT_PID_GOAL
    next true if counter >= MAX_DRIVE_REQUESTS

    counter += 1
    pid_resp = get_json(demo_base, "/pid")
    if pid_resp
      pid = pid_resp["pid"]
      seen_pids << pid
      get_json(demo_base, "/demo?visitor_id=smoke-test-#{pid}-#{counter}")
    end
    seen_pids.uniq.size >= DISTINCT_PID_GOAL || counter >= MAX_DRIVE_REQUESTS
  end
  [seen_pids, counter]
end

# The distinct PIDs embedded in the stub's recorded tracked visitor ids.
def delivered_pids(stub)
  stub.tracked_visitor_ids
      .filter_map { |vid| vid[/\Asmoke-test-(\d+)-/, 1] }
      .uniq
end

# =============================================================================
# Main.
# =============================================================================
def main
  demo_dir = File.expand_path("..", __dir__)
  config_body = File.read(CANNED_CONFIG_PATH)
  log("canned config: #{CANNED_CONFIG_PATH}")

  stub = StubServer.new(config_body).start
  stub_base = "http://127.0.0.1:#{stub.port}/"
  log("stub server on #{stub_base}")

  demo_port = free_port
  demo_base = "http://127.0.0.1:#{demo_port}/"
  puma_pid = boot_puma(demo_dir: demo_dir, port: demo_port, stub_base: stub_base)
  log("booting Puma cluster (pid #{puma_pid}, #{DISTINCT_PID_GOAL} workers) on #{demo_base}")

  begin
    booted = wait_until(timeout: BOOT_TIMEOUT, interval: 0.25) { get_json(demo_base, "/pid") }
    unless booted
      log("FAIL: Puma did not become ready within #{BOOT_TIMEOUT}s")
      return 1
    end
    log("Puma ready; first served pid=#{booted['pid']}")

    seen_pids, count = drive_until_two_workers(demo_base)
    distinct_serving = seen_pids.uniq
    log("served by #{distinct_serving.size} distinct worker PID(s): #{distinct_serving.inspect} (#{count} requests)")
    if distinct_serving.size < DISTINCT_PID_GOAL
      log("FAIL: fewer than #{DISTINCT_PID_GOAL} distinct worker PIDs served in #{count} requests")
      return 1
    end

    wait_until(timeout: EVENT_TIMEOUT, interval: 0.1) { delivered_pids(stub).size >= DISTINCT_PID_GOAL }
    pids = delivered_pids(stub)
    log("stub recorded tracked events from #{pids.size} distinct PID(s): #{pids.inspect}")
    log("total tracked visitor ids recorded: #{stub.tracked_visitor_ids.size}")

    if pids.size >= DISTINCT_PID_GOAL
      log("PASS: events delivered from >= #{DISTINCT_PID_GOAL} forked Puma workers with ZERO fork-handling code.")
      0
    else
      log("FAIL: stub saw tracked events from only #{pids.size} distinct PID(s); expected >= #{DISTINCT_PID_GOAL}.")
      log("recorded visitor ids sample: #{stub.tracked_visitor_ids.first(10).inspect}")
      1
    end
  ensure
    log("tearing down Puma cluster (pid #{puma_pid})")
    kill_puma(puma_pid)
    stub.shutdown
  end
end

exit(main)
