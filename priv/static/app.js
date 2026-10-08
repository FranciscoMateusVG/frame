// Connects the LiveView socket of a signed-in page. The masked CSRF token
// of the page's server session is in <meta name="csrf-token">; the socket
// is refused without it (and from any other Origin).
(() => {
  const meta = document.querySelector("meta[name='csrf-token']");
  if (!meta || !window.LiveView || !window.Phoenix) return;

  const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: { _csrf_token: meta.getAttribute("content") },
  });
  liveSocket.connect();
})();
