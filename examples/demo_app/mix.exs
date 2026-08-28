defmodule DemoApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [{:idk, path: "../.."}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
