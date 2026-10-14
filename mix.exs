defmodule HomeElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :home_elixir,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # Release for running as a service (NixOS, systemd, ...). Must live in
      # project() (not application()): Mix 1.20's release task reads
      # :releases from the project config.
      releases: [
        home_elixir: [
          mode: :prod,
          steps: [:assemble, &HomeElixir.MixProject.copy_mnesia_ebin/1]
        ]
      ]
    ]
  end

  # Compile shared test helpers in the test env.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :mnesia is NOT in extra_applications: FlowState.start/0 must run before
      # Mnesia starts (a running RAM-schema Mnesia blocks create_schema on a
      # fresh install). But its ebin IS shipped in the release (not started),
      # because FlowState.ensure_mnesia_code/0 locates it under the OTP root,
      # which is the release dir at runtime (see copy_mnesia_ebin/1).
      extra_applications: [:logger],
      mod: {HomeElixir.Application, []}
    ]
  end

  # Copy Mnesia's ebin into the release as lib/mnesia-rel/ebin, matching the
  # `lib/mnesia-*/ebin` glob in HomeElixir.FlowState.ensure_mnesia_code/0.
  # Mix 1.20 dropped the release `include` option; a post-:assemble step is
  # the supported way to add files.
  def copy_mnesia_ebin(release) do
    src =
      Path.wildcard(Path.join(to_string(:code.root_dir()), "lib/mnesia-*/ebin"))
      |> List.first!()

    dest = Path.join(release.path, "lib/mnesia-rel/ebin")
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!(src, dest)
    release
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:plug_cowboy, "~> 2.7"},
      {:crontab, "~> 1.1"},
      {:ecto, "~> 3.13"}
    ]
  end
end
