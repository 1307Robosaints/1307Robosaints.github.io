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

  // Escape user input so it can't inject HTML into the emails
  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
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

    var name  = $("#name").val().trim();
    var email = $("#email").val().trim();
    var allTopics = chosen.map(function (t) { return t.label; }).join(", ");

    // Group recipients so each address gets one email
    var byEmail = {};
    chosen.forEach(function (t) {
      [].concat(t.email).forEach(function (addr) {
        (byEmail[addr] = byEmail[addr] || []).push(t.label);
      });
    });

    // Fields shared by every email. Display values are escaped; reply_to is the raw address.
    var base = {
      from_name:  esc(name),
      from_email: esc(email),
      reply_to:   email,
      phone:      esc($("#phone").val().trim() || "(not provided)"),
      topics:     esc(allTopics),
      message:    esc($("#message").val().trim()).replace(/\n/g, "<br>")
    };

    var $btn = $("#sendMessageButton").prop("disabled", true);

    var sends = Object.keys(byEmail).map(function (addr) {
      var params = $.extend({}, base, {
        to_email: addr,
        subject:  "Website contact: " + byEmail[addr].join(", ")
      });
      return emailjs.send(cfg.emailjs.serviceId, cfg.emailjs.templateId, params);
    });

    // Copy to the person who submitted the form. A failure here doesn't fail the whole submit.
    var copySend = emailjs.send(cfg.emailjs.serviceId, cfg.emailjs.copyTemplateId, $.extend({}, base, {
      to_email: email,
      subject:  "Copy of your message to STA Robotics Team 1307"
    })).then(function () { return true; }, function () { return false; });
    sends.push(copySend);

    Promise.all(sends).then(function (results) {
      var copied = results[results.length - 1];
      var text = "Your message has been sent. Thank you!";
      if (copied) text += " A copy was sent to " + email + ".";
      showAlert("success", text);
      $form[0].reset();
      $form.removeClass("was-validated");
    }).catch(function () {
      showAlert("danger", "Sorry, something went wrong sending your message. Please try again or email us directly.");
    }).then(function () {
      setTimeout(function () { $btn.prop("disabled", false); }, 1000);
    });
  });
});