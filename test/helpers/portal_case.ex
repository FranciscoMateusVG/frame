defmodule Frame.Test.PortalCase do
  @moduledoc """
  Case template for tests that drive the portal: `Phoenix.ConnTest` and
  `Phoenix.LiveViewTest` against `Frame.Web.Endpoint`, plus the
  `Frame.Test.Portal` harness (one isolated world per test). Async by
  default: `use Frame.Test.PortalCase`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest, except: [conn: 0]
      import Phoenix.LiveViewTest

      alias Frame.Test.Ids
      alias Frame.Test.Portal

      @endpoint Frame.Web.Endpoint
    end
  end
end
