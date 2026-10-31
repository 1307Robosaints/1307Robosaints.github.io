/* =====================================================================
   CONTACT FORM CONFIG  -  this is the only file you need to edit
   ===================================================================== */

window.CONTACT_CONFIG = {

  /* ---------- 1. EmailJS settings ---------- */
  emailjs: {
    publicKey:  "Z9Esvx7YWvJ9GE_bg",
    serviceId:  "service_sjmfz5n",
    templateId:     "template_tmpii4j",   // Staff Side Email Template
    copyTemplateId: "template_kn9cdzg"    // Submitter Side Email Template
  },

  /* ---------- 2. ALWAYS GETS EVERY MESSAGE ----------
     These people get an email for EVERY submission, whatever boxes
     are checked. Each person gets exactly one email.
  ------------------------------------------------------------------ */
  always: ["robotics@stalux.org", "cdemos@stalux.org"],

  /* ---------- 3. EXTRA PEOPLE PER CHECKBOX ----------
     label : text people see next to the checkbox
     email : EXTRA people who also get the message when it is checked
             (a list like ["a@x.org", "b@x.org"], or [] for nobody extra)

     The "always" people above are added automatically, so don't repeat them.
     If someone checks several boxes, each person still gets only ONE email
     that lists the topics relevant to them.
  ------------------------------------------------------------------ */
  topics: [
    // >>>>>>>>>>>>>>>>>>>>>>  EDIT BELOW THIS LINE  <<<<<<<<<<<<<<<<<<<<<<
    { label: "Sponsorships",             email: ["ssenter28@stalux.org"] },
    { label: "Joining the team",         email: [] },
    { label: "Mentoring / volunteering", email: [] },
    { label: "Outreach & demos",         email: ["ssenter28@stalux.org"] },
    { label: "Something else",           email: ["ssenter28@stalux.org"] }
    // >>>>>>>>>>>>>>>>>>>>>>  EDIT ABOVE THIS LINE  <<<<<<<<<<<<<<<<<<<<<<
  ]
};
