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

    // Group topics by recipient so each address gets one email
    var byEmail = {};
    chosen.forEach(function (t) {
      [].concat(t.email).forEach(function (addr) {
        (byEmail[addr] = byEmail[addr] || []).push(t.label);
      });
    });

    var base = {
      from_name:  $("#name").val().trim(),
      from_email: $("#email").val().trim(),
      reply_to:   $("#email").val().trim(),
      phone:      $("#phone").val().trim() || "(not provided)",
      message:    $("#message").val().trim()
    };

    var $btn = $("#sendMessageButton").prop("disabled", true);

    var sends = Object.keys(byEmail).map(function (addr) {
      var params = $.extend({}, base, {
        to_email: addr,
        topics:   byEmail[addr].join(", "),
        subject:  "Website contact: " + byEmail[addr].join(", ")
      });
      return emailjs.send(cfg.emailjs.serviceId, cfg.emailjs.templateId, params);
    });

    Promise.all(sends).then(function () {
      showAlert("success", "Your message has been sent. Thank you!");
      $form[0].reset();
      $form.removeClass("was-validated");
    }).catch(function () {
      showAlert("danger", "Sorry, something went wrong sending your message. Please try again or email us directly.");
    }).then(function () {
      setTimeout(function () { $btn.prop("disabled", false); }, 1000);
    });
  });
});
