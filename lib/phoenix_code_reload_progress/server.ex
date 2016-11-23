# The GenServer used by the CodeReloader.
defmodule PhoenixCodeReloadProgress.CodeReloader.Server do
  @moduledoc false
  use GenServer

  require Logger
  alias PhoenixCodeReloadProgress.CodeReloader.Proxy

  def start_link(app, mod, compilers, opts \\ []) do
    Logger.info "Starting cr server #{inspect {app, mod, compilers}} -> #{inspect opts}"
    :ets.new(:conn_registry, [:named_table, :public])
    GenServer.start_link(__MODULE__, {app, mod, compilers}, opts)
    |> IO.inspect
  end

  def reload!(conn, callback) do
    Logger.info "Compiling to callback"

    # endpoint = conn.private.phoenix_endpoint

    endpoint = PhoenixCodeReloadProgress.Supervisor
    children = Supervisor.which_children(endpoint)

    :ets.insert(:conn_registry, {:conn, conn})

    res =
      case List.keyfind(children, __MODULE__, 0) do
        {__MODULE__, pid, _, _} ->
          GenServer.call(pid, {:reload!, {conn, callback}}, :infinity)
        _ ->
          raise "Code reloader was invoked for #{inspect endpoint} but no code reloader " <>
                "server was started. Be sure to move `plug Phoenix.CodeReloader` inside " <>
                "a `if code_reloading? do` block in your endpoint"
      end

    [{:conn, conn}] = :ets.lookup(:conn_registry, :conn)
    :ets.delete(:conn_registry, :conn)

    {res, conn}
  end

  ## Callbacks

  def init({app, mod, compilers}) do
    Logger.info "init(#{inspect {app, mod, compilers}})"
    all = Mix.Project.config[:compilers] || Mix.compilers
    compilers = all -- (all -- compilers)
    {:ok, {app, mod, compilers}}
  end

  def handle_call({:reload!, {conn, callback}}, from, {app, mod, compilers} = state) do
    backup = load_backup(mod)
    froms  = all_waiting([from])
    IO.inspect froms: froms
    # IO.inspect conn: conn

    {res, out} =
      proxy_io(fn ->
        try do
          mix_compile(Code.ensure_loaded(Mix.Task), app, compilers)
        catch
          :exit, {:shutdown, 1} ->
            :error
          kind, reason ->
            IO.puts Exception.format(kind, reason, System.stacktrace)
            :error
        end
      end, fn chars ->
        [{:conn, conn}] = :ets.lookup(:conn_registry, :conn)
        conn = callback.({:output, conn, chars})
        :ets.insert(:conn_registry, {:conn, conn})
      end)

    [{:conn, conn}] = :ets.lookup(:conn_registry, :conn)
    # callback.({:output, conn, chars})

    conn = callback.({:done, conn})
    :ets.insert(:conn_registry, {:conn, conn})

    reply =
      case res do
        :ok ->
          :ok
        :error ->
          write_backup(backup)
          {:error, out}
      end

    Enum.each(froms, &GenServer.reply(&1, reply))
    {:noreply, state}
  end

  defp load_backup(mod) do
    mod
    |> :code.which()
    |> read_backup()
  end
  defp read_backup(path) when is_list(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, path, binary}
      _ -> :error
    end
  end
  defp read_backup(_path), do: :error

  defp write_backup({:ok, path, file}), do: File.write!(path, file)
  defp write_backup(:error), do: :ok

  defp all_waiting(acc) do
    receive do
      {:"$gen_call", from, :reload!} -> all_waiting([from | acc])
    after
      0 -> acc
    end
  end

  defp mix_compile({:error, _reason}, _, _) do
    raise "the Code Reloader is enabled but Mix is not available. If you want to " <>
          "use the Code Reloader in production or inside an escript, you must add " <>
          ":mix to your applications list. Otherwise, you must disable code reloading " <>
          "in such environments"
  end

  defp mix_compile({:module, Mix.Task}, _app, compilers) do
    if Mix.Project.umbrella? do
      Enum.each Mix.Dep.Umbrella.loaded, fn dep ->
        Mix.Dep.in_dependency(dep, fn _ ->
          mix_compile_unless_stale_config(compilers)
        end)
      end
    else
      mix_compile_unless_stale_config(compilers)
      :ok
    end
  end

  defp mix_compile_unless_stale_config(compilers) do
    manifests = Mix.Tasks.Compile.Elixir.manifests
    configs   = Mix.Project.config_files

    case Mix.Utils.extract_stale(configs, manifests) do
      [] ->
        mix_compile(compilers)
      files ->
        raise """
        could not compile application: #{Mix.Project.config[:app]}.

        You must restart your server after changing the following config or lib files:

          * #{Enum.map_join(files, "\n  * ", &Path.relative_to_cwd/1)}
        """
     end
   end

  defp mix_compile(compilers) do
    Enum.each compilers, &Mix.Task.reenable("compile.#{&1}")

    # We call build_structure mostly for Windows so new
    # assets in priv are copied to the build directory.
    Mix.Project.build_structure
    res = Enum.map(compilers, &Mix.Task.run("compile.#{&1}", []))

    if :ok in res && consolidate_protocols?() do
      Mix.Task.reenable("compile.protocols")
      Mix.Task.run("compile.protocols", [])
    end

    res
  end

  defp consolidate_protocols? do
    Mix.Project.config[:consolidate_protocols]
  end

  defp proxy_io(fun, callback) do
    original_gl = Process.group_leader
    {:ok, proxy_gl} = Proxy.start(callback)
    Process.group_leader(self(), proxy_gl)
    stderr =
      case Process.whereis(:standard_error) do
        nil ->
          nil
        pid ->
          # IO.puts "Registering #{inspect pid} as stderr"
          Process.unregister(:standard_error)
          Process.register(proxy_gl, :standard_error)
          pid
      end

    try do
      {fun.(), Proxy.stop(proxy_gl)}
    after
      if stderr do
        # IO.puts "Unregistering #{inspect stderr} as stderr"
        if Process.whereis(:standard_error) do
          Process.unregister(:standard_error)
        end
        Process.register(stderr, :standard_error)
      end

      Process.group_leader(self(), original_gl)
      Process.exit(proxy_gl, :kill)
    end
  end
end
