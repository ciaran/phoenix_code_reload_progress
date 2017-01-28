# Setup

Open `endpoint.ex`, comment out the contents of the `if code_reloading? do` block, and insert:

  `plug PhoenixCodeReloadProgress.CodeReloader`

Note that you currently need to comment out the two live_reloader lines as well,
as Phoenix websockets have a hardcoded call to the builtin code reloader.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `phoenix_code_reload_progress` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:phoenix_code_reload_progress, "~> 0.1.0"}]
    end
    ```

  2. Ensure `phoenix_code_reload_progress` is started before your application:

    ```elixir
    def application do
      [applications: [:phoenix_code_reload_progress]]
    end
    ```

