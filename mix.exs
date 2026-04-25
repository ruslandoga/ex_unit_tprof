defmodule Idk.MixProject do
  use Mix.Project

  def project do
    [
      app: :idk,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [idk: :test, "idk.test": :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"}
    ]
  end
end
