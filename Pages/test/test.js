(async function() {
  const status = document.getElementById("status");
  const result = document.getElementById("result");

  try {
    const response = await window.webkit.messageHandlers.axium.postMessage({
      action: "echo",
      data: "hello from test page"
    });
    status.textContent = "Message handler working!";
    result.textContent = JSON.stringify(response, null, 2);
  } catch (e) {
    status.textContent = "Error: " + e.message;
    result.textContent = e.stack || String(e);
  }
})();
