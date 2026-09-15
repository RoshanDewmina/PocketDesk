function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));
}

/**
 * Minimal authorize page: shows the confirmation code, polls for the Mac's
 * decision, and redirects on approval. Never renders a token. CSP forbids
 * inline scripts other than this page's own external file to keep the page
 * itself free of 'unsafe-inline'.
 */
export function renderAuthorizePage(params: { requestId: string; clientName: string; redirectHost: string; code: string }): string {
  const { requestId, clientName, redirectHost, code } = params;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PocketDesk authorization</title>
<style>
  body { font: 16px/1.4 -apple-system, system-ui, sans-serif; background: #0b0b0f; color: #f2f2f5; margin: 0; padding: 32px 16px; }
  main { max-width: 420px; margin: 0 auto; text-align: center; }
  .code { font-size: 40px; letter-spacing: 0.2em; font-weight: 700; margin: 24px 0; }
  .status { color: #9a9aa5; margin-top: 16px; }
  .client { font-weight: 600; }
</style>
</head>
<body>
<main>
  <h1>Approve on your Mac</h1>
  <p><span class="client">${escapeHtml(clientName)}</span> wants access via <strong>${escapeHtml(redirectHost)}</strong>.</p>
  <p>Confirm the code matches what your Mac shows:</p>
  <div class="code">${escapeHtml(code)}</div>
  <p class="status" id="status">Waiting for approval on your Mac&hellip;</p>
</main>
<script src="/mcp-ui/authorize.js" data-request-id="${escapeHtml(requestId)}"></script>
</body>
</html>`;
}

export function renderAuthorizeScript(): string {
  return `(function () {
  var script = document.currentScript;
  var requestId = script.getAttribute('data-request-id');
  var status = document.getElementById('status');
  function poll() {
    fetch('/oauth/authorize/poll?request_id=' + encodeURIComponent(requestId), { credentials: 'omit' })
      .then(function (response) { return response.json(); })
      .then(function (data) {
        if (data.status === 'denied') status.textContent = 'Denied on the Mac.';
        else if (data.status === 'offline') status.textContent = 'The Mac is offline.';
        else if (data.status === 'timeout') status.textContent = 'Timed out waiting for approval.';
        if (data.redirect) { window.location.replace(data.redirect); return; }
        if (data.status === 'pending') setTimeout(poll, 1500);
      })
      .catch(function () { setTimeout(poll, 2500); });
  }
  poll();
})();`;
}
