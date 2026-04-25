# ExUnitTProf

Prototype Mix task for profiling ExUnit runs with Erlang/OTP `:tprof`.

This is intentionally outside Elixir core. The first milestone is to learn
whether a third-party wrapper around `mix test` is useful enough before
proposing any upstream ExUnit surface.

## Usage

Run the selected tests through `mix test.tprof`:

```sh
mix test.tprof test/path_test.exs:42 --type call_memory
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
mix test.tprof test/my_test.exs:12 --seed 123 --type call_time
```

Outputs default to:

```text
_build/test/tprof/report.txt
_build/test/tprof/profile.etf
```

Override them with:

```sh
mix test.tprof --report tmp/tprof.txt --artifact tmp/tprof.etf --type call_memory
```

`profile.etf` is `:erlang.term_to_binary/1` output for the raw `:tprof`
profile data. It is deliberately low-level so later flamegraph or flamechart
experiments can inspect the data without re-running the test suite.

## Flamegraph Artifacts

`:tprof` exposes aggregate function measurements. That is enough for hot
function tables, but not enough to reconstruct full call stacks for a real
flamegraph.

For stack-shaped output, this prototype also has an experimental trace mode:

```sh
mix test.tprof test/path_test.exs:42 --flamegraph
```

This uses `:erlang.trace/3` with `:call`, `:return_to`, timestamps, and
`set_on_spawn` around the selected `mix test` invocation. By default it traces
loaded modules under the current project's application module prefix. You can
narrow or expand that explicitly:

```sh
mix test.tprof test/path_test.exs:42 --flamegraph --trace-module MyApp.Context
```

You can also gate trace capture with telemetry events. This is useful when a
test exercises a broad flow, but you only want the flamechart for a specific
request, query, job, or client operation:

```sh
mix test.tprof test/path_test.exs:42 \
  --flamegraph \
  --trace-module MyApp.Context \
  --trace-start-event my_app.profile.start \
  --trace-stop-event my_app.profile.stop
```

The telemetry handler starts tracing in the process that emits the start event
and stops tracing in the process that emits the stop event. With
`set_on_spawn`, children spawned after the start event are traced too. This
keeps the feature out of ExUnit while making it easy to add local instrumentation
around the code path you want to dogfood.

It writes:

```text
_build/test/tprof/flame/stacks.folded
_build/test/tprof/flame/speedscope.json
_build/test/tprof/flame/flamegraph.svg
```

The folded stack file follows the common `a;b;c count` shape used by many
flamegraph tools. `speedscope.json` is intended for <https://www.speedscope.app>
and can be viewed as a flame chart or sandwich view. The SVG is a lightweight
preview, not a replacement for a full interactive flamegraph viewer.

For viewer integration, the safest default is to write a local Speedscope file
and print the path. Uploading client traces to a hosted service should be an
explicit opt-in because function names, module names, metadata, and call paths
can expose private application details. A future `profile_and_view` helper could
open Speedscope locally in the browser and ask before any upload-style workflow.

The trace mode is intentionally separate from the `:tprof` mode because both
install VM trace patterns. Running them together would make the initial results
harder to reason about.

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

Trace flamegraph mode is even noisier than the `:tprof` table path. It traces
function calls, can produce large artifacts, and currently samples stack shape
from traced call events rather than using a low-overhead statistical sampler.
Telemetry-gated tracing reduces the capture window but does not remove tracing
overhead while the gate is open.

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
