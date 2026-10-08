// Confirmation dialogs: a button[data-confirm] opens its <dialog> once the
// form is valid; the dialog's own submit button sends the form. Without
// JavaScript the <noscript> submit buttons do the same job.
document.addEventListener("click", (event) => {
  const opener = event.target.closest("[data-confirm]");
  if (opener) {
    const form = opener.closest("form");
    const dialog = document.getElementById(opener.dataset.confirm);
    if (!form || !dialog || !form.reportValidity()) return;
    form.querySelectorAll("[data-echo]").forEach((input) => {
      dialog.querySelectorAll(`[data-echo-target="${input.dataset.echo}"]`).forEach((out) => {
        out.textContent = input.value.trim();
      });
    });
    dialog.showModal();
    return;
  }
  const closer = event.target.closest("[data-close]");
  if (closer) closer.closest("dialog")?.close();
});

// A submitted form cannot be sent twice by a double click; the
// Idempotency-Key in the form makes a repeat harmless anyway.
document.addEventListener("submit", (event) => {
  const form = event.target;
  if (form.dataset.sent) {
    event.preventDefault();
    return;
  }
  if (form.method.toLowerCase() === "post") form.dataset.sent = "1";
});
