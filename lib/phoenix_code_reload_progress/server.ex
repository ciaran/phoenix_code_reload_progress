defmodule PhoenixCodeReloadProgress.CodeReloader.ConnRegistry do
  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(nil) do
    table = :ets.new(__MODULE__, [])
    {:ok, table}
  end

  # Client

  def insert(endpoint, conn) do
    IO.puts "Calling insert #{endpoint} #{inspect conn.owner}"
    GenServer.call(__MODULE__, {:insert, endpoint, conn})
  end

  def remove(endpoint, owner) do
    GenServer.call(__MODULE__, {:remove, endpoint, owner})
  end

  def update_all(endpoint, fun) do
    GenServer.call(__MODULE__, {:update_all, endpoint, fun})
  end

  # Server

  def handle_call({:insert, _endpoint, conn}, _from, table) do
    :ets.insert(table, {:conn, conn})
    {:reply, :ok, table}
  end

  def handle_call({:update_all, _endpoint, fun}, _from, table) do
    [{:conn, conn}] = :ets.lookup(table, :conn)
    conn = fun.(conn)
    :ets.insert(table, {:conn, conn})
    {:reply, :ok, table}
  end

  def handle_call({:remove, _endpoint, _owner}, _from, table) do
    [{:conn, conn}] = :ets.lookup(table, :conn)
    :ets.delete(table, :conn)
    {:reply, {:ok, conn}, table}
  end
end

defmodule PhoenixCodeReloadProgress.CodeReloader.Server do
  @moduledoc false
  use GenServer

  require Logger
  alias PhoenixCodeReloadProgress.CodeReloader.{Proxy, ConnRegistry}

  def start_link() do
    GenServer.start_link(__MODULE__, false, name: __MODULE__)
  end

  def check_symlinks do
    GenServer.call(__MODULE__, :check_symlinks, :infinity)
  end

  def reload!(conn, callback) do
    endpoint = conn.private.phoenix_endpoint

    ConnRegistry.insert(endpoint, conn)

    res = GenServer.call(__MODULE__, {:reload!, {endpoint, callback}}, :infinity)

    {:ok, conn} = ConnRegistry.remove(endpoint, conn.owner)

    {res, conn}
  end

  ## Callbacks

  def init(false) do
    {:ok, false}
  end

  def handle_call(:check_symlinks, _from, checked?) do
    if not checked? and Code.ensure_loaded?(Mix.Project) do
      build_path = Mix.Project.build_path()
      symlink = Path.join(Path.dirname(build_path), "__phoenix__")

      case File.ln_s(build_path, symlink) do
        :ok ->
          File.rm(symlink)
        {:error, :eexist} ->
          File.rm(symlink)
        {:error, _} ->
          Logger.warn "Phoenix is unable to create symlinks. Phoenix' code reloader will run " <>
                      "considerably faster if symlinks are allowed." <> os_symlink(:os.type)
      end
    end

    {:reply, :ok, true}
  end

  def handle_call({:reload!, {endpoint, callback}}, from, state) do
    compilers = endpoint.config(:reloadable_compilers)
    backup = load_backup(endpoint)
    froms  = all_waiting([from], endpoint)

    {res, out} =
      proxy_io(fn ->
        try do
          mix_compile(Code.ensure_loaded(Mix.Task), compilers)
        catch
          :exit, {:shutdown, 1} ->
            :error
          kind, reason ->
            IO.puts Exception.format(kind, reason, System.stacktrace)
            :error
        end
      end, fn chars ->
        ConnRegistry.update_all(endpoint, fn conn ->
          callback.({:output, conn, chars})
        end)
      end)

    ConnRegistry.update_all(endpoint, fn conn ->
      callback.({:done, conn})
    end)

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

  defp os_symlink({:win32, _}),
    do: " On Windows, such can be done by starting the shell with \"Run as Administrator\"."
  defp os_symlink(_),
    do: ""

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

  defp all_waiting(acc, endpoint) do
    receive do
      {:"$gen_call", from, {:reload!, {^endpoint, _}}} -> all_waiting([from | acc], endpoint)
    after
      0 -> acc
    end
  end

  defp mix_compile({:module, Mix.Task}, compilers) do
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
  defp mix_compile({:error, _reason}, _) do
    raise "the Code Reloader is enabled but Mix is not available. If you want to " <>
          "use the Code Reloader in production or inside an escript, you must add " <>
          ":mix to your applications list. Otherwise, you must disable code reloading " <>
          "in such environments"
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
    all = Mix.Project.config[:compilers] || Mix.compilers

    # We call build_structure mostly for Windows so new
    # assets in priv are copied to the build directory.
    Mix.Project.build_structure

    compilers =
      for compiler <- compilers, compiler in all do
        Mix.Task.reenable("compile.#{compiler}")
        compiler
      end

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
