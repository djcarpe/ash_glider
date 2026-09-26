// Plain script, no bundler: Phoenix and LiveView are loaded as globals from
// their packages (see the Plug.Static entries in the endpoint).
(function () {
  const Hooks = {
    Graph: window.GraphHook,
    SubmitOnCtrlEnter: {
      mounted() {
        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            this.el.form.requestSubmit();
          }
        });
      }
    }
  };

  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
