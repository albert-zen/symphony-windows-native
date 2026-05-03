defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src={StaticAssets.path("/vendor/phoenix_html/phoenix_html.js")}></script>
        <script defer src={StaticAssets.path("/vendor/phoenix/phoenix.js")}></script>
        <script defer src={StaticAssets.path("/vendor/phoenix_live_view/phoenix_live_view.js")}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var hooks = {
              LocalTime: {
                mounted: function () {
                  this.renderLocalTime();
                },
                updated: function () {
                  this.renderLocalTime();
                },
                renderLocalTime: function () {
                  var iso = this.el.getAttribute("datetime");
                  if (!iso) return;

                  var date = new Date(iso);
                  if (Number.isNaN(date.getTime())) return;

                  this.el.textContent = date.toLocaleString(undefined, {
                    year: "numeric",
                    month: "short",
                    day: "numeric",
                    hour: "numeric",
                    minute: "2-digit",
                    second: "2-digit"
                  });
                }
              },
              AutoScroll: {
                mounted: function () {
                  this.scrollToBottom();
                },
                updated: function () {
                  this.scrollToBottom();
                },
                scrollToBottom: function () {
                  this.el.scrollTop = this.el.scrollHeight;
                }
              },
              StickyScroll: {
                mounted: function () {
                  this.atBottom = true;
                  this.el.addEventListener("scroll", () => {
                    var threshold = 64;
                    this.atBottom = (this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight) < threshold;
                  });
                  this.el.scrollTop = this.el.scrollHeight;
                },
                updated: function () {
                  if (this.atBottom !== false) {
                    this.el.scrollTop = this.el.scrollHeight;
                  }
                }
              },
              PreserveDetails: {
                beforeUpdate: function () {
                  this.wasOpen = this.el.open;
                },
                updated: function () {
                  this.el.open = this.wasOpen === true;
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={StaticAssets.path("/dashboard.css")} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
