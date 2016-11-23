defmodule PhoenixCodeReloadProgress do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    endpoint = Emoticast.Endpoint

    args = [nil, endpoint, [:gettext, :phoenix, :elixir],
            [name: Module.concat(endpoint, CodeReloadProgress)]]

    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: PhoenixCodeReloadProgress.Worker.start_link(arg1, arg2, arg3)
      worker(PhoenixCodeReloadProgress.CodeReloader.Server, args),
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixCodeReloadProgress.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
