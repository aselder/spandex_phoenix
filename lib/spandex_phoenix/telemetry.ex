defmodule SpandexPhoenix.Telemetry do
  @moduledoc """
  Defines the `:telemetry` handlers to attach tracing to Phoenix Telemetry.
  """

  @doc """
  Installs `:telemetry` event handlers for Phoenix Telemetry events.

  ### Options

  * `:tracer` (`Atom`)

      The tracing module to be used for traces in your Endpoint.

      Default: `Application.get_env(:spandex_phoenix, :tracer)`

  * `:filter_traces` (`fun((Plug.Conn.t()) -> boolean)`)

      A function that takes a conn and returns true if a trace should be created
      for that conn, and false if it should be ignored.

      Default: `fn _ -> true end` (include all)

  * `:span_name` (`String.t()`)

      The name for the span this module creates.

      Default: `"request"`

  * `:customize_metadata` (`fun((Plug.Conn.t()) -> Keyword.t())`)

      A function that takes a conn and returns a keyword list of metadata.

      Default: `&SpandexPhoenix.default_metadata/1`
  """
  def install(opts \\ []) do
    unless function_exported?(:telemetry, :attach_many, 4) do
      raise "Cannot install telemetry events without `:telemetry` dependency." <>
              "Did you mean to use the Phoenix Instrumenters integration instead?"
    end

    tracer =
      Keyword.get_lazy(opts, :tracer, fn ->
        Application.get_env(:spandex_phoenix, :tracer)
      end)

    unless tracer do
      raise ArgumentError, ":tracer option must be provided or configured in :spandex_phoenix"
    end

    filter_traces = Keyword.get(opts, :filter_traces, fn _ -> true end)
    customize_metadata = Keyword.get(opts, :customize_metadata, &SpandexPhoenix.default_metadata/1)
    span_name = Keyword.get(opts, :span_name, "request")

    opts = %{tracer: tracer, filter_traces: filter_traces, customize_metadata: customize_metadata, span_name: span_name}

    events = [
      [:phoenix, :router_dispatch, :start],
      [:phoenix, :router_dispatch, :stop],
      [:phoenix, :router_dispatch, :exception]
    ]

    :telemetry.attach_many("spandex-phoenix-telemetry", events, &__MODULE__.handle_event/4, opts)
  end

  @doc false
  def handle_event([:phoenix, :router_dispatch, :start], _, meta, config) do
    %{
      tracer: tracer,
      filter_traces: filter_traces,
      span_name: span_name,
      customize_metadata: customize_metadata
    } = config

    conn = meta.conn
    # It's possible the router handed this request to a non-controller plug;
    # we only handle controller actions though, which is what the `is_atom` clauses are testing for
    if is_atom(meta[:plug]) and is_atom(meta[:plug_opts]) and filter_traces.(conn) do
      tracer.start_span(span_name, resource: "#{meta.plug}.#{meta.plug_opts}")

      conn
      |> customize_metadata.()
      |> tracer.update_top_span()
    end
  end

  def handle_event([:phoenix, :router_dispatch, :stop], _, _, %{tracer: tracer}) do
    if tracer.current_trace_id() do
      tracer.finish_span()
    end
  end

  def handle_event([:phoenix, :router_dispatch, :exception], _, meta, %{tracer: tracer}) do
    # phx 1.5.4-dev has a breaking change that switches `:error` to `:reason`
    # maybe they'll see "reason" and keep using the old key too, but for now here's this
    error = meta[:reason] || meta[:error]
    if tracer.current_trace_id() do
      tracer.span_error(error, meta.stacktrace)
      tracer.update_span(error: [error?: true])
      tracer.finish_trace()
    end
  end
end
