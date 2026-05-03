defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/config", ConfigLive)
    live("/workers/:issue_identifier", WorkerDetailLive)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/runtime", ObservabilityApiController, :runtime)
    match(:*, "/api/v1/runtime", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/runtime/reload", ObservabilityApiController, :reload_runtime)
    match(:*, "/api/v1/runtime/reload", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workers/:issue_identifier/status", ObservabilityApiController, :worker_status)
    match(:*, "/api/v1/workers/:issue_identifier/status", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workers/:issue_identifier/conversation", ObservabilityApiController, :worker_conversation)
    match(:*, "/api/v1/workers/:issue_identifier/conversation", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workers/:issue_identifier/timeline", ObservabilityApiController, :worker_timeline)
    match(:*, "/api/v1/workers/:issue_identifier/timeline", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workers/:issue_identifier/diff", ObservabilityApiController, :worker_diff)
    match(:*, "/api/v1/workers/:issue_identifier/diff", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workers/:issue_identifier/debug/events", ObservabilityApiController, :worker_debug_events)
    match(:*, "/api/v1/workers/:issue_identifier/debug/events", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
