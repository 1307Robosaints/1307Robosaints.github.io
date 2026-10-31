/* Contact form logic. Topics/emails are configured in /js/contact-config.js */
$(function () {
  var cfg = window.CONTACT_CONFIG;
  var $form = $("#contactForm");
  if (!cfg || !$form.length) return;

  /* ---- Build the checkboxes from the config ---- */
  var $topics = $("#topicList");
  cfg.topics.forEach(function (t, i) {
    var id = "topic" + i;
    var $wrap = $('<div class="custom-control custom-checkbox mb-1"></div>');
    $wrap.append($('<input type="checkbox" class="custom-control-input topic-box">').attr({ id: id, value: i }));
    $wrap.append($('<label class="custom-control-label"></label>').attr("for", id).text(t.label));
    $topics.append($wrap);
  });

  if (window.emailjs) {
    emailjs.init({ publicKey: cfg.emailjs.publicKey });
  }

  // Only allow phone-style characters while typing
  $("#phone").on("input", function () {
    this.value = this.value.replace(/[^\d\s().+\-]/g, "");
  });

  // Escape user input so it can't inject HTML into the emails
  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  // Turns "a@x.org, b@x.org" (or an array) into ["a@x.org", "b@x.org"]
  function splitEmails(v) {
    return [].concat(v).join(",").split(",")
      .map(function (s) { return s.trim().toLowerCase(); })
      .filter(Boolean);
  }

  /* Phone check. Blank is allowed (the field is optional).
     Otherwise it must be a 10-digit US number, or 11 digits starting with 1.
     Area code and exchange must start with 2-9, as US numbers do.
     Returns { ok, value } where value is the formatted number. */
  function checkPhone(raw) {
    var v = raw.trim();
    if (!v) return { ok: true, value: "(not provided)" };
    if (!/^\+?[\d\s().\-]+$/.test(v)) return { ok: false };

    var digits = v.replace(/\D/g, "");
    if (digits.length === 11 && digits.charAt(0) === "1") digits = digits.slice(1);
    if (digits.length !== 10) return { ok: false };
    if (!/[2-9]/.test(digits.charAt(0)) || !/[2-9]/.test(digits.charAt(3))) return { ok: false };

    return {
      ok: true,
      value: "(" + digits.slice(0, 3) + ") " + digits.slice(3, 6) + "-" + digits.slice(6)
    };
  }

  function showAlert(type, text) {
    var $a = $('<div class="alert alert-dismissible"></div>').addClass("alert-" + type);
    $a.append($('<button type="button" class="close" data-dismiss="alert" aria-label="Close">&times;</button>'));
    $a.append($("<strong></strong>").text(text));
    $("#success").empty().append($a);
  }

  $form.on("submit", function (e) {
    e.preventDefault();
    $("#success").empty();

    // Honeypot: bots fill this hidden field, people don't
    if ($("#website").val()) return;

    var chosen = $(".topic-box:checked").map(function () {
      return cfg.topics[parseInt(this.value, 10)];
    }).get();

    if (!chosen.length) {
      showAlert("warning", "Please check at least one topic so we know who to send this to.");
      return;
    }
    if (!this.checkValidity()) {
      $form.addClass("was-validated");
      return;
    }

    var phone = checkPhone($("#phone").val());
    if (!phone.ok) {
      showAlert("warning", "Please enter a valid 10-digit phone number, or leave the phone field blank.");
      $("#phone").focus();
      return;
    }

    var name  = $("#name").val().trim();
    var email = $("#email").val().trim();
    var submitter = email.toLowerCase();
    var allTopics = chosen.map(function (t) { return t.label; }).join(", ");

    // One list per unique staff address, covering every topic routed to it
    var byEmail = {};
    chosen.forEach(function (t) {
      splitEmails(t.email).forEach(function (addr) {
        var list = (byEmail[addr] = byEmail[addr] || []);
        if (list.indexOf(t.label) === -1) list.push(t.label);
      });
    });

    // Fields shared by every email. Display values are escaped; reply_to is the raw address.
    var base = {
      from_name:  esc(name),
      from_email: esc(email),
      reply_to:   email,
      phone:      esc(phone.value),
      topics:     esc(allTopics),
      message:    esc($("#message").val().trim()).replace(/\n/g, "<br>")
    };

    var $btn = $("#sendMessageButton").prop("disabled", true);

    var sends = Object.keys(byEmail).map(function (addr) {
      var params = $.extend({}, base, {
        to_email: addr,
        topics:   esc(byEmail[addr].join(", ")),
        subject:  "Website contact: " + byEmail[addr].join(", ")
      });
      return emailjs.send(cfg.emailjs.serviceId, cfg.emailjs.templateId, params);
    });

    // Copy to the submitter only after every staff send succeeds,
    // and skip it if they're already getting the staff email
    var alreadyReceiving = !!byEmail[submitter];

    function sendCopy() {
      if (alreadyReceiving) return Promise.resolve(null);
      return emailjs.send(cfg.emailjs.serviceId, cfg.emailjs.copyTemplateId, $.extend({}, base, {
        to_email: email,
        subject:  "Copy of your message to STA Robotics Team 1307"
      })).then(function () { return true; }, function (err) {
        console.error("Copy email failed:", err);
        return false;
      });
    }

    Promise.all(sends).then(sendCopy).then(function (copied) {
      var text = "Your message has been sent. Thank you!";
      if (copied === true) text += " A copy was sent to " + email + ".";
      else if (copied === false) text += " We couldn't email you a copy, but your message was delivered.";
      showAlert("success", text);
      $form[0].reset();
      $form.removeClass("was-validated");
    }).catch(function (err) {
      console.error("Staff email failed:", err);
      showAlert("danger", "Sorry, something went wrong sending your message. Please try again or email us directly.");
    }).then(function () {
      setTimeout(function () { $btn.prop("disabled", false); }, 1000);
    });
  });
});