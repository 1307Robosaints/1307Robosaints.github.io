// The site's own dialogs, in place of the browser's confirm(), prompt() and alert(). Each returns a
// promise, so callers await it:
//
//   if (!(await RSDialog.confirm("Ban x@y.org?", { title: "Ban account", ok: "Ban", danger: true }))) return;
//   var note = await RSDialog.prompt("Optional note", { title: "Deny request", value: "", placeholder: "…" });
//     (null if cancelled; "" if left empty)
//   await RSDialog.alert("Couldn't save that.", { title: "Not saved" });
//
// confirm options: title, ok (button text), cancel, danger (red OK button).
// prompt options: the same, plus value, placeholder, maxLength, required (OK stays off until filled),
//   match (OK stays off until the text equals it, for "type the name to delete").
// Message text is set as plain text, with line breaks kept. Escape cancels; Enter confirms.
window.RSDialog = (function () {
  var open = null;   // one dialog at a time: later calls wait their turn

  function build(kind, message, o) {
    o = o || {};
    return new Promise(function (resolve) {
      var back = document.createElement("div");
      back.className = "rs-dialog-back";
      var box = document.createElement("div");
      box.className = "rs-dialog" + (o.danger ? " danger" : "");
      box.setAttribute("role", kind === "alert" ? "alertdialog" : "dialog");
      box.setAttribute("aria-modal", "true");
      var id = "rsDlg" + Date.now();
      box.setAttribute("aria-labelledby", id + "t");
      box.setAttribute("aria-describedby", id + "m");

      var title = document.createElement("h2");
      title.id = id + "t";
      title.className = "rs-dialog-title";
      title.textContent = o.title || (kind === "alert" ? "Notice" : kind === "prompt" ? "Enter a value" : "Are you sure?");
      var msg = document.createElement("p");
      msg.id = id + "m";
      msg.className = "rs-dialog-msg";
      msg.textContent = message || "";
      box.appendChild(title);
      box.appendChild(msg);

      var input = null;
      if (kind === "prompt") {
        input = document.createElement("input");
        input.type = "text";
        input.className = "form-control form-control-sm rs-dialog-input";
        input.value = o.value || "";
        if (o.placeholder) input.placeholder = o.placeholder;
        if (o.maxLength) input.maxLength = o.maxLength;
        input.setAttribute("aria-label", o.title || "Value");
        box.appendChild(input);
      }

      var row = document.createElement("div");
      row.className = "rs-dialog-buttons";
      var cancel = null;
      if (kind !== "alert") {
        cancel = document.createElement("button");
        cancel.type = "button";
        cancel.className = "btn btn-outline-secondary btn-sm";
        cancel.textContent = o.cancel || "Cancel";
        row.appendChild(cancel);
      }
      var ok = document.createElement("button");
      ok.type = "button";
      ok.className = "btn btn-sm " + (o.danger ? "btn-danger" : "btn-primary");
      ok.textContent = o.ok || "OK";
      row.appendChild(ok);
      box.appendChild(row);
      back.appendChild(box);

      function valid() {
        if (!input) return true;
        var v = input.value.trim();
        if (o.match != null) return v === String(o.match);
        return !o.required || v !== "";
      }
      function refresh() { ok.disabled = !valid(); }
      if (input) { input.addEventListener("input", refresh); refresh(); }

      var before = document.activeElement;
      function close(result) {
        document.removeEventListener("keydown", onKey, true);
        back.remove();
        open = null;
        if (before && before.focus) try { before.focus({ preventScroll: true }); } catch (e) {}
        resolve(result);
      }
      function onKey(e) {
        if (e.key === "Escape") { e.preventDefault(); close(kind === "confirm" ? false : kind === "prompt" ? null : undefined); }
        else if (e.key === "Enter" && (input ? document.activeElement === input : true) && valid()) {
          e.preventDefault();
          close(kind === "confirm" ? true : kind === "prompt" ? input.value.trim() : undefined);
        } else if (e.key === "Tab") {
          // Keep focus inside the dialog
          var f = Array.prototype.filter.call(box.querySelectorAll("input,button"), function (x) { return !x.disabled; });
          if (!f.length) return;
          var i = f.indexOf(document.activeElement);
          if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
          else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
        }
      }
      ok.addEventListener("click", function () {
        if (!valid()) return;
        close(kind === "confirm" ? true : kind === "prompt" ? input.value.trim() : undefined);
      });
      if (cancel) cancel.addEventListener("click", function () { close(kind === "confirm" ? false : null); });
      back.addEventListener("mousedown", function (e) {
        if (e.target === back && kind !== "alert") close(kind === "confirm" ? false : null);
      });
      document.addEventListener("keydown", onKey, true);
      document.body.appendChild(back);
      open = back;
      // A destructive confirm starts on Cancel, so a stray Enter doesn't do it
      setTimeout(function () { (input || (o.danger && cancel) || ok).focus(); if (input) input.select(); }, 20);
    });
  }

  // Calls made while a dialog is open wait for it to close
  var queue = Promise.resolve();
  function queued(kind) {
    return function (message, o) {
      var run = queue.then(function () { return build(kind, message, o); });
      queue = run.catch(function () {});
      return run;
    };
  }
  return { confirm: queued("confirm"), prompt: queued("prompt"), alert: queued("alert") };
})();
