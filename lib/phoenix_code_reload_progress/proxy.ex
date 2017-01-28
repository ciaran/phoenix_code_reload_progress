# A tiny proxy that stores all output sent to the group leader
# while forwarding all requests to it.
defmodule PhoenixCodeReloadProgress.CodeReloader.Proxy do
  @moduledoc false
  use GenServer
  require Logger

  def start(callback \\ nil) do
    stderr = Process.whereis(:standard_error)
    GenServer.start(__MODULE__, {"", callback, stderr})
  end

  def stop(proxy) do
    GenServer.call(proxy, :stop)
  end

  ## Callbacks

  def handle_call(:stop, _from, {output, _callback, _stderr}) do
    {:stop, :normal, output, output}
  end

  def handle_info(msg, state) do
    case msg do
      {:io_request, from, reply, {:put_chars, chars}} ->
        put_chars(from, reply, chars, state)

      {:io_request, from, reply, {:put_chars, m, f, as}} ->
        put_chars(from, reply, apply(m, f, as), state)

      {:io_request, from, reply, {:put_chars, _encoding, chars}} ->
        put_chars(from, reply, chars, state)

      {:io_request, from, reply, {:put_chars, _encoding, m, f, as}} ->
        put_chars(from, reply, apply(m, f, as), state)

      {:io_request, _from, _reply, _request} = msg ->
        send(Process.group_leader, msg)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp put_chars(from, reply, chars, {output, callback, stderr}) do
    # Logger.info "put_chars(#{inspect chars})"
    callback.(chars)
    send(Process.group_leader, {:io_request, from, reply, {:put_chars, chars}})
    # send(stderr, {:io_request, from, reply, {:put_chars, chars}})
    {:noreply, {output <> IO.chardata_to_string(chars), callback, stderr}}
  end
end
