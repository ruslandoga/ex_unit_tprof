# Idk

Prototype Mix task for profiling BEAM code paths with Erlang/OTP `:tprof`
and trace-based flamegraph artifacts.

The first workflow is ExUnit-oriented because test runs are a practical place to
dogfood profiling, but the tracing and flamegraph pieces are not ExUnit-specific.

## Usage

Run the selected tests through `mix idk test`:

```sh
mix idk test test/path_test.exs:42 --type call_memory
```

Supported profile types:

```text
call_count
call_time
call_memory
```

The task consumes its own options and forwards other arguments to `mix test`.
For example, `--seed`, `--trace`, file paths, and `file:line` selectors are
passed through.

```sh
mix idk test test/my_test.exs:12 --seed 123 --type call_time
```

Outputs default to:

```text
_build/test/idk/report.txt
_build/test/idk/profile.etf
```

Override them with:

```sh
mix idk test --report tmp/idk.txt --artifact tmp/idk.etf --type call_memory
```

`profile.etf` is `:erlang.term_to_binary/1` output for the raw `:tprof`
profile data. It is deliberately low-level so later flamegraph or flamechart
experiments can inspect the data without re-running the test suite.

## Flamegraph Artifacts

`:tprof` exposes aggregate function measurements. That is enough for hot
function tables, but not enough to reconstruct full call stacks for a real
flamegraph.

For stack-shaped output, this prototype also has an experimental sampling mode:

```sh
mix idk test test/path_test.exs:42 --flamegraph
```

This periodically samples process stack traces. An isolated OTP 27 trace session
tracks processes spawned by the selected `mix test` invocation so their stacks
are sampled too. By default Idk selects modules from the current Mix
application; a sample is kept when its stack passes through one of those
modules. You can narrow or expand that explicitly:

```sh
mix idk test test/path_test.exs:42 --flamegraph --trace-module MyApp.Context
```

You can also gate trace capture with telemetry events. This is useful when a
test exercises a broad flow, but you only want the flamechart for a specific
request, query, job, or client operation:

```sh
mix idk test test/path_test.exs:42 \
  --flamegraph \
  --trace-module MyApp.Context \
  --trace-start-event my_app.profile.start \
  --trace-stop-event my_app.profile.stop
```

The telemetry handler starts sampling the process that emits the start event
and stops sampling when the stop event is emitted. The trace session discovers
children spawned after the start event and samples them too. This
keeps the feature out of ExUnit while making it easy to add local instrumentation
around the code path you want to dogfood.

It writes:

```text
_build/test/idk/flame/stacks.folded
_build/test/idk/flame/speedscope.json
_build/test/idk/flame/flamegraph.svg
```

The folded stack file follows the common `a;b;c count` shape used by many
flamegraph tools. `speedscope.json` is intended for <https://www.speedscope.app>
and can be viewed as a flame chart or sandwich view. Each traced BEAM process is
written as a separate selectable Speedscope profile so concurrent stacks remain
valid. The SVG is a lightweight preview, not a replacement for a full
interactive flamegraph viewer.

For viewer integration, the safest default is to write a local Speedscope file
and print the path. Speedscope processes files selected from disk entirely in
the browser rather than uploading them, but profiles still contain private
module names and call paths and should be handled like client data. A future
`profile_and_view` helper could open Speedscope locally in the browser.

The sampling mode is intentionally separate from the `:tprof` mode so each
artifact has one clear measurement model.

## Demo Project

`examples/demo_app` is a standalone consumer with nested work spread over
multiple `Task` processes. It exercises both immediate and telemetry-gated
capture:

```sh
cd examples/demo_app
mix deps.get
mix idk test test/demo_app_test.exs:4 --flamegraph
mix idk test test/demo_app_test.exs:8 \
  --flamegraph \
  --trace-start-event demo_app.workload.start \
  --trace-stop-event demo_app.workload.stop
```

Idk discovers modules in the current Mix application by default. Use repeated
`--trace-module` options when the interesting code belongs to dependencies or
when a narrower capture would be easier to inspect.

## Current Design

The MVP uses ad-hoc `:tprof.profile/2` around:

```elixir
Mix.Task.run("test", forwarded_test_args)
```

Reports use `:tprof.inspect(profile_data, :total, {:measurement, :descending})`
to show a combined whole-run function table.

The flamegraph path is informed by prior Erlang/Elixir tools:

* `eflame` writes folded stack data from Erlang tracing.
* `eflambè` focuses on fast capture workflows and viewer-friendly formats.
* `Flame On` shows the value of an easy trigger-and-view UI, while its
  production warning is a useful reminder to avoid code swapping in this
  prototype.

## Limitations

This is whole-run profiling. Measurements include ExUnit itself, setup blocks,
factories, fixtures, application startup, formatters, and any other work done
during the selected `mix test` invocation.

Profiling adds overhead and can perturb timings, scheduling, allocation, and
process behavior. Treat the report as directional evidence, not exact
benchmarking data.

Flamegraph mode is statistical: short-lived functions may not appear in every
run, and weights are sampling intervals rather than exact function durations.
The default interval is 1 ms and can be changed with `--sample-interval MS`.
Smaller intervals increase overhead and artifact size. Telemetry gating reduces
both by limiting the capture window.

`:tprof` is experimental in Erlang/OTP 27. Output shape, semantics, and
performance characteristics may change across OTP releases.

For `call_time` and `call_memory`, `:tprof` traces the profiled process and
spawned children by default. Work done by already-running long-lived processes
may be underrepresented. `call_count` is global and has different process
scoping behavior.

## Questions This Prototype Should Answer

* Does wrapping `mix test` externally work well enough for normal file and line
  workflows?
* Can combined reports identify useful hot functions in real projects despite
  ExUnit/setup/factory noise?
* Is the raw `:tprof` data sufficient for flamegraph-style output?
  Current answer: useful for hot function tables, but not enough for true call
  stacks; a trace or sampling workflow is needed for flamegraph/flamechart
  artifacts.
* Which UX belongs upstream in ExUnit, and which parts are better as a
  third-party Mix task or formatter helper?

## Upstream Proposal Direction

If real-project runs show useful signal, the smallest ExUnit integration should
likely be opt-in and additive:

* a formatter/helper that can receive or annotate whole-run profiling data, or
* an explicit profiling mode that wraps selected test execution without changing
  the default runner behavior.

The prototype should avoid requiring mandatory runner changes unless external
wrapping proves too noisy or too limited.
