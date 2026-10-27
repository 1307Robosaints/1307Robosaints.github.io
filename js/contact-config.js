/* =====================================================================
   CONTACT FORM CONFIG  —  this is the only file you need to edit
   ===================================================================== */

window.CONTACT_CONFIG = {

  /* ---------- 1. EmailJS settings (one-time setup, see instructions) ---------- */
  emailjs: {
    publicKey:  "Z9Esvx7YWvJ9GE_bg",
    serviceId:  "service_sjmfz5n",
    templateId: "template_tmpii4j"
  },

  /* ---------- 2. CHECKBOXES + WHO GETS THE EMAIL ----------
     To add a new checkbox, copy one line and change it:

       label : text people see next to the checkbox
       email : who receives the message when it's checked
               (use ["a@x.org", "b@x.org"] to send to several people)

     If someone checks several boxes, each address gets ONE email
     that lists every topic they picked.
  ------------------------------------------------------------------ */
  topics: [
    // >>>>>>>>>>>>>>>>>>>>>>  EDIT BELOW THIS LINE  <<<<<<<<<<<<<<<<<<<<<<
    { label: "Sponsorships",          email: "robotics@stalux.org" },
    { label: "Joining the team",      email: "robotics@stalux.org" },
    { label: "Mentoring / volunteering", email: "robotics@stalux.org" },
    { label: "Outreach & demos",      email: "robotics@stalux.org" },
    { label: "Something else",        email: "robotics@stalux.org" }
    // >>>>>>>>>>>>>>>>>>>>>>  EDIT ABOVE THIS LINE  <<<<<<<<<<<<<<<<<<<<<<
  ]
};
